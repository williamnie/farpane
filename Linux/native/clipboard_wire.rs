//! Bounded RustDesk Clipboard/MultiClipboards adapter. No platform clipboard,
//! GTK, configuration, or logging. Called by the per-role clipboard owner.
use base::message_proto::{Clipboard, ClipboardFormat, Message, MultiClipboards};
use bytes::Bytes;
use farpane_protocol::{
    clipboard::{self, Category, Direction, Format, Part, Policy, Token},
    clipboard_socket::Contents,
};
use std::io::{self, Read};

fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Unsupported or invalid clipboard data",
    )
}
fn from_format(format: ClipboardFormat) -> io::Result<Format> {
    match format {
        ClipboardFormat::Text => Ok(Format::Text),
        ClipboardFormat::Html => Ok(Format::Html),
        ClipboardFormat::Rtf => Ok(Format::Rtf),
        ClipboardFormat::ImagePng => Ok(Format::Png),
        ClipboardFormat::ImageRgba => Ok(Format::Rgba),
        ClipboardFormat::ImageSvg => Ok(Format::Svg),
        _ => Err(invalid()),
    }
}
pub(crate) fn to_format(format: Format) -> ClipboardFormat {
    match format {
        Format::Text => ClipboardFormat::Text,
        Format::Html => ClipboardFormat::Html,
        Format::Rtf => ClipboardFormat::Rtf,
        Format::Png => ClipboardFormat::ImagePng,
        Format::Rgba => ClipboardFormat::ImageRgba,
        Format::Svg => ClipboardFormat::ImageSvg,
    }
}
/// Pinned RustDesk can send both PNG and RGBA for one selection, and desktop
/// apps can offer image and text alternatives together. Select one permitted
/// category before copying/decompressing anything; our local envelope stays
/// canonical. Unknown/Special formats are rejected rather than treated as text.
pub fn select(
    mut values: Vec<Clipboard>,
    policy: Policy,
    direction: Direction,
) -> io::Result<Vec<Clipboard>> {
    if values.is_empty() || values.len() > 6 {
        return Err(invalid());
    }
    let mut formats = Vec::with_capacity(values.len());
    let mut total = 0usize;
    for value in &values {
        let format = from_format(value.format.enum_value().map_err(|_| invalid())?)?;
        if formats.contains(&format) || !value.special_name.is_empty() {
            return Err(invalid());
        }
        formats.push(format);
        total = total.checked_add(value.content.len()).ok_or_else(invalid)?;
        if total > clipboard::IMAGE_LIMIT {
            return Err(invalid());
        }
    }
    if policy.allows(Category::Image, direction) {
        for image in [Format::Png, Format::Rgba, Format::Svg] {
            if let Some(index) = formats.iter().position(|f| *f == image) {
                let result = vec![values.swap_remove(index)];
                preflight(&result, policy, direction)?;
                return Ok(result);
            }
        }
    }
    let rich = policy.allows(Category::RichText, direction)
        && formats
            .iter()
            .any(|f| matches!(f, Format::Html | Format::Rtf));
    let result: Vec<_> = values
        .into_iter()
        .zip(formats)
        .filter_map(|(value, format)| {
            (if rich {
                matches!(format, Format::Text | Format::Html | Format::Rtf)
            } else {
                format == Format::Text && policy.allows(Category::Text, direction)
            })
            .then_some(value)
        })
        .collect();
    if result.is_empty() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    preflight(&result, policy, direction)?;
    Ok(result)
}
/// Cheap admission on the network thread. Never decompress or copy payloads here.
pub fn preflight(
    values: &[Clipboard],
    policy: Policy,
    direction: Direction,
) -> io::Result<Category> {
    if values.is_empty() || values.len() > clipboard::MAX_PARTS {
        return Err(invalid());
    }
    let formats = values
        .iter()
        .map(|c| from_format(c.format.enum_value().map_err(|_| invalid())?))
        .collect::<io::Result<Vec<_>>>()?;
    let category = clipboard::category(&formats)?;
    if !policy.allows(category, direction) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    for (value, format) in values.iter().zip(formats) {
        let width = u32::try_from(value.width).map_err(|_| invalid())?;
        let height = u32::try_from(value.height).map_err(|_| invalid())?;
        if !value.special_name.is_empty()
            || value.content.is_empty()
            || value.content.len() > format.limit()
            || (format == Format::Png && value.compress)
            || (format != Format::Rgba && (width != 0 || height != 0))
        {
            return Err(invalid());
        }
        if format == Format::Rgba {
            clipboard::pixels(width, height)?;
        }
    }
    Ok(category)
}
/// Compressed envelopes have output and decoder-window bounds; PNG has no zstd layer.
pub fn decode(
    values: Vec<Clipboard>,
    policy: Policy,
    direction: Direction,
) -> io::Result<Vec<Part<Bytes>>> {
    preflight(&values, policy, direction)?;
    let formats = values
        .iter()
        .map(|c| from_format(c.format.enum_value().map_err(|_| invalid())?))
        .collect::<io::Result<Vec<_>>>()?;
    let mut result = Vec::with_capacity(values.len());
    for (value, format) in values.into_iter().zip(formats) {
        let width = u32::try_from(value.width).map_err(|_| invalid())?;
        let height = u32::try_from(value.height).map_err(|_| invalid())?;
        if !value.special_name.is_empty()
            || value.content.is_empty()
            || value.content.len() > format.limit()
            || (format != Format::Rgba && (width != 0 || height != 0))
        {
            return Err(invalid());
        }
        let limit = if format == Format::Rgba {
            clipboard::pixels(width, height)?
                .checked_mul(4)
                .ok_or_else(invalid)?
        } else {
            format.limit()
        };
        let bytes = if value.compress {
            if format == Format::Png {
                return Err(invalid());
            }
            let mut decoder =
                zstd::stream::read::Decoder::new(value.content.as_ref()).map_err(|_| invalid())?;
            // Pinned peers use ordinary zstd compression. A declared window
            // above 8 MiB is rejected even if the final payload is tiny.
            decoder.window_log_max(23).map_err(|_| invalid())?;
            let mut bytes = Vec::new();
            decoder
                .take((limit + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|_| invalid())?;
            if bytes.is_empty() || bytes.len() > limit {
                return Err(invalid());
            }
            Bytes::from(bytes)
        } else {
            value.content
        };
        result.push(Part {
            format,
            width,
            height,
            bytes,
        });
    }
    clipboard::describe(
        Token {
            serial: 1,
            revision: 1,
        },
        &result,
    )?;
    Ok(result)
}
/// Bytes owns a shared read-only mapping. Encoding the protocol later still
/// allocates its wire buffer, but this adapter does not clone every image first.
pub fn encode(
    contents: &Contents,
    revision: u64,
    policy: Policy,
    direction: Direction,
) -> io::Result<Message> {
    let offer = contents.offer();
    let (category, _) = offer.layout()?;
    if offer.token.revision != revision || !policy.allows(category, direction) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let mut values = Vec::with_capacity(offer.items.len());
    for (i, item) in offer.items.iter().enumerate() {
        values.push(Clipboard {
            format: to_format(item.format).into(),
            width: item.width as i32,
            height: item.height as i32,
            content: Bytes::from_owner(contents.part(i).ok_or_else(invalid)?),
            ..Default::default()
        });
    }
    let mut message = Message::new();
    if values.len() == 1 {
        message.set_clipboard(values.remove(0));
    } else {
        message.set_multi_clipboards(MultiClipboards {
            clipboards: values,
            ..Default::default()
        });
    }
    Ok(message)
}

/// Validated Host platform parts already own bounded byte buffers.
pub fn encode_parts(parts: Vec<Part<Bytes>>) -> Message {
    let mut values: Vec<_> = parts
        .into_iter()
        .map(|p| Clipboard {
            format: to_format(p.format).into(),
            width: p.width as i32,
            height: p.height as i32,
            content: p.bytes,
            ..Default::default()
        })
        .collect();
    let mut message = Message::new();
    if values.len() == 1 {
        message.set_clipboard(values.remove(0));
    } else {
        message.set_multi_clipboards(MultiClipboards {
            clipboards: values,
            ..Default::default()
        });
    }
    message
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::message;
    use farpane_protocol::{
        clipboard::Directions,
        clipboard_socket::{Channel, Delivery, Prepared, Status},
    };
    use hbb_common::protobuf::Message as _;
    fn all() -> Policy {
        let d = Directions {
            send: true,
            receive: true,
        };
        Policy {
            text: d,
            rich_text: d,
            image: d,
        }
    }
    fn text(format: ClipboardFormat, payload: &[u8], compress: bool) -> Clipboard {
        Clipboard {
            format: format.into(),
            compress,
            content: if compress {
                zstd::encode_all(payload, 3).unwrap().into()
            } else {
                payload.to_vec().into()
            },
            ..Default::default()
        }
    }
    #[test]
    fn real_rich_protobuf_roundtrip_preserves_bundle_and_mapping_ownership() {
        let wire = Message {
            union: Some(message::Union::MultiClipboards(MultiClipboards {
                clipboards: vec![
                    text(ClipboardFormat::Text, "你好".as_bytes(), false),
                    text(ClipboardFormat::Html, b"<p><b>Hi</b></p>", true),
                    text(ClipboardFormat::Rtf, b"{\\rtf1 Hi}", true),
                ],
                ..Default::default()
            })),
            ..Default::default()
        };
        let parsed = Message::parse_from_bytes(&wire.write_to_bytes().unwrap()).unwrap();
        let Some(message::Union::MultiClipboards(bundle)) = parsed.union else {
            panic!("not a rich bundle")
        };
        let policy = Policy {
            rich_text: Directions {
                send: true,
                receive: true,
            },
            ..Default::default()
        };
        let parts = decode(bundle.clipboards, policy, Direction::Receive).unwrap();
        let (mut a, mut b) = Channel::pair().unwrap();
        let token = a.next_token(9).unwrap();
        let prepared = Prepared::new(token, &parts).unwrap();
        a.send(&prepared, 9).unwrap();
        let Delivery::Offer(incoming) = b.receive().unwrap() else {
            panic!("missing offer")
        };
        let contents = incoming.map(9, policy, Direction::Receive).unwrap();
        assert!(encode(&contents, 10, policy, Direction::Send).is_err());
        let output = encode(&contents, 9, policy, Direction::Send).unwrap();
        b.receipt(token, Status::Received).unwrap();
        a.receive().unwrap();
        drop(contents);
        drop(prepared);
        drop(parts);
        let parsed = Message::parse_from_bytes(&output.write_to_bytes().unwrap()).unwrap();
        let Some(message::Union::MultiClipboards(bundle)) = parsed.union else {
            panic!("bundle lost")
        };
        assert_eq!(bundle.clipboards.len(), 3);
        assert_eq!(bundle.clipboards[0].content.as_ref(), "你好".as_bytes());
        assert_eq!(bundle.clipboards[1].content.as_ref(), b"<p><b>Hi</b></p>");
        assert_eq!(bundle.clipboards[2].content.as_ref(), b"{\\rtf1 Hi}");
    }
    #[test]
    fn disabled_stale_unsupported_and_decompression_bombs_are_rejected() {
        use std::io::Write;
        let malformed = Clipboard {
            compress: true,
            content: b"not-zstd".to_vec().into(),
            ..Default::default()
        };
        assert_eq!(
            decode(vec![malformed], Policy::default(), Direction::Receive)
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        let bomb = text(
            ClipboardFormat::Html,
            &vec![b'x'; clipboard::RICH_LIMIT + 1],
            true,
        );
        assert!(decode(vec![bomb], all(), Direction::Receive).is_err());
        let mut encoder = zstd::stream::write::Encoder::new(Vec::new(), 3).unwrap();
        encoder.window_log(24).unwrap();
        encoder.include_contentsize(false).unwrap();
        encoder
            .write_all(b"small payload with excessive decoder window")
            .unwrap();
        let window = Clipboard {
            format: ClipboardFormat::Html.into(),
            compress: true,
            content: encoder.finish().unwrap().into(),
            ..Default::default()
        };
        assert!(decode(vec![window], all(), Direction::Receive).is_err());
        assert!(decode(
            vec![text(ClipboardFormat::Text, b"a\0b", false)],
            all(),
            Direction::Receive
        )
        .is_err());
        let mut special = text(ClipboardFormat::Text, b"do-not-log", false);
        special.special_name = "arbitrary/mime".into();
        let error = decode(vec![special], all(), Direction::Receive).unwrap_err();
        assert!(!error.to_string().contains("do-not-log"));
        assert!(decode(
            vec![text(ClipboardFormat::Special, b"unknown", false)],
            all(),
            Direction::Receive
        )
        .is_err());
        assert!(decode(
            vec![
                text(ClipboardFormat::Text, b"a", false),
                text(ClipboardFormat::Text, b"b", false)
            ],
            all(),
            Direction::Receive
        )
        .is_err());
    }
    #[test]
    fn image_shapes_zstd_and_raw_bytes_have_explicit_bounds() {
        let raw = Bytes::from_static(b"no copy");
        let address = raw.as_ptr();
        let result = decode(
            vec![Clipboard {
                content: raw,
                ..Default::default()
            }],
            all(),
            Direction::Receive,
        )
        .unwrap();
        assert_eq!(result[0].bytes.as_ptr(), address);
        for (width, height, length, valid) in [
            (2, 1, 8, true),
            (2, 1, 7, false),
            (-1, 1, 4, false),
            (9000, 1, 4, false),
        ] {
            let mut image = text(ClipboardFormat::ImageRgba, &vec![0x3f; length], true);
            image.width = width;
            image.height = height;
            assert_eq!(
                decode(vec![image], all(), Direction::Receive).is_ok(),
                valid
            );
        }
        assert!(decode(
            vec![text(ClipboardFormat::ImagePng, b"already-compressed", true)],
            all(),
            Direction::Receive
        )
        .is_err());
        assert!(decode(
            vec![text(
                ClipboardFormat::ImageSvg,
                b"<!DOCTYPE svg><svg />",
                true
            )],
            all(),
            Direction::Receive
        )
        .is_err());
        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>";
        assert_eq!(
            decode(
                vec![text(ClipboardFormat::ImageSvg, svg, true)],
                all(),
                Direction::Receive
            )
            .unwrap()[0]
                .bytes
                .as_ref(),
            svg
        );
    }
    #[test]
    fn wire_alternatives_choose_one_permitted_category_without_decoding_others() {
        let png = text(
            ClipboardFormat::ImagePng,
            b"structural-check-is-later",
            false,
        );
        let rgba = Clipboard {
            width: 1,
            height: 1,
            ..text(ClipboardFormat::ImageRgba, &[1, 2, 3, 255], false)
        };
        let bundle = vec![text(ClipboardFormat::Text, b"fallback", false), rgba, png];
        let selected = select(bundle.clone(), all(), Direction::Receive).unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(
            selected[0].format.enum_value().unwrap(),
            ClipboardFormat::ImagePng
        );
        let plain = Policy {
            text: all().text,
            ..Default::default()
        };
        let selected = select(bundle, plain, Direction::Receive).unwrap();
        assert_eq!(selected[0].content.as_ref(), b"fallback");
        assert!(select(
            vec![text(ClipboardFormat::Special, b"file-url", false)],
            all(),
            Direction::Receive
        )
        .is_err());
    }
}
