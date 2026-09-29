fn input_is_allowed(authenticated: bool, remote_keyboard_enabled: bool) -> bool {
    authenticated && remote_keyboard_enabled
}

fn clipboard_receive_allowed(
    active: bool,
    authenticated: bool,
    local_receive_enabled: bool,
    remote_clipboard_enabled: bool,
) -> bool {
    active && authenticated && local_receive_enabled && remote_clipboard_enabled
}

fn optional_string_bytes(value: &Option<String>) -> (*const u8, usize) {
    value.as_ref().map_or((ptr::null(), 0), |text| {
        (text.as_bytes().as_ptr(), text.len())
    })
}

fn decoded_clipboard_utf8(clipboard: &Clipboard, max_bytes: usize) -> Option<String> {
    if !clipboard.special_name.is_empty()
        || clipboard.width != 0
        || clipboard.height != 0
        || clipboard.content.is_empty()
        || clipboard.content.len() > max_bytes
    {
        return None;
    }
    let bytes = if clipboard.compress {
        hbb_common::compress::decompress_with_limit(&clipboard.content, max_bytes).ok()?
    } else {
        clipboard.content.to_vec()
    };
    let text = String::from_utf8(bytes).ok()?;
    (!text.is_empty() && text.len() <= max_bytes && !text.contains('\0')).then_some(text)
}

pub(crate) fn native_viewer_clipboard_text(clipboards: &[Clipboard]) -> Option<String> {
    let clipboard = match clipboards {
        [clipboard] => clipboard,
        _ => return None,
    };
    if clipboard.format.enum_value() != Ok(ClipboardFormat::Text) {
        return None;
    }
    decoded_clipboard_utf8(clipboard, MAX_CLIPBOARD_TEXT_UTF8_BYTES)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeViewerRichTextBundle {
    pub(crate) plain_text: Option<String>,
    pub(crate) rtf: Option<String>,
    pub(crate) html: Option<String>,
}

pub(crate) fn native_viewer_clipboard_rich_text(
    clipboards: &[Clipboard],
) -> Option<NativeViewerRichTextBundle> {
    if clipboards.is_empty() || clipboards.len() > 3 {
        return None;
    }
    let mut bundle = NativeViewerRichTextBundle::default();
    for clipboard in clipboards {
        match clipboard.format.enum_value().ok()? {
            ClipboardFormat::Text => {
                if bundle.plain_text.is_some() {
                    return None;
                }
                bundle.plain_text = Some(decoded_clipboard_utf8(
                    clipboard,
                    MAX_CLIPBOARD_TEXT_UTF8_BYTES,
                )?);
            }
            ClipboardFormat::Rtf => {
                if bundle.rtf.is_some() {
                    return None;
                }
                bundle.rtf = Some(decoded_clipboard_utf8(
                    clipboard,
                    MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
                )?);
            }
            ClipboardFormat::Html => {
                if bundle.html.is_some() {
                    return None;
                }
                bundle.html = Some(decoded_clipboard_utf8(
                    clipboard,
                    MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
                )?);
            }
            _ => return None,
        }
    }
    (bundle.rtf.is_some() || bundle.html.is_some()).then_some(bundle)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeViewerClipboardImageKind {
    Rgba { width: u32, height: u32 },
    Png,
    Svg,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeViewerClipboardImage {
    pub(crate) kind: NativeViewerClipboardImageKind,
    pub(crate) payload: Vec<u8>,
}

pub(crate) fn native_viewer_clipboard_image(
    clipboards: &[Clipboard],
) -> Option<NativeViewerClipboardImage> {
    let clipboard = match clipboards {
        [clipboard] if clipboard.special_name.is_empty() => clipboard,
        _ => return None,
    };
    match clipboard.format.enum_value().ok()? {
        ClipboardFormat::ImageRgba => {
            let width = u32::try_from(clipboard.width).ok()?;
            let height = u32::try_from(clipboard.height).ok()?;
            let pixel_count = native_viewer_image_pixel_count(width, height)?;
            let expected_bytes = pixel_count.checked_mul(4)?;
            let payload = native_viewer_image_payload_bytes(
                clipboard,
                MAX_CLIPBOARD_IMAGE_BYTES,
                MAX_CLIPBOARD_IMAGE_BYTES,
                true,
            )?;
            (payload.len() == expected_bytes).then_some(NativeViewerClipboardImage {
                kind: NativeViewerClipboardImageKind::Rgba { width, height },
                payload,
            })
        }
        ClipboardFormat::ImagePng => {
            if clipboard.compress || clipboard.width != 0 || clipboard.height != 0 {
                return None;
            }
            let payload = native_viewer_image_payload_bytes(
                clipboard,
                MAX_CLIPBOARD_IMAGE_BYTES,
                MAX_CLIPBOARD_IMAGE_BYTES,
                false,
            )?;
            native_viewer_png_dimensions(&payload)?;
            Some(NativeViewerClipboardImage {
                kind: NativeViewerClipboardImageKind::Png,
                payload,
            })
        }
        ClipboardFormat::ImageSvg => {
            if clipboard.width != 0 || clipboard.height != 0 {
                return None;
            }
            let payload = native_viewer_image_payload_bytes(
                clipboard,
                MAX_CLIPBOARD_SVG_UTF8_BYTES,
                MAX_CLIPBOARD_SVG_UTF8_BYTES,
                true,
            )?;
            native_viewer_svg_has_canonical_root(&payload)?;
            Some(NativeViewerClipboardImage {
                kind: NativeViewerClipboardImageKind::Svg,
                payload,
            })
        }
        _ => None,
    }
}

fn native_viewer_image_payload_bytes(
    clipboard: &Clipboard,
    wire_limit: usize,
    decoded_limit: usize,
    allow_compressed: bool,
) -> Option<Vec<u8>> {
    if clipboard.content.is_empty() || clipboard.content.len() > wire_limit {
        return None;
    }
    let payload = if clipboard.compress {
        if !allow_compressed {
            return None;
        }
        hbb_common::compress::decompress_with_limit(&clipboard.content, decoded_limit).ok()?
    } else {
        clipboard.content.to_vec()
    };
    (!payload.is_empty() && payload.len() <= decoded_limit).then_some(payload)
}

fn native_viewer_image_pixel_count(width: u32, height: u32) -> Option<usize> {
    if width == 0
        || height == 0
        || width > MAX_CLIPBOARD_IMAGE_DIMENSION as u32
        || height > MAX_CLIPBOARD_IMAGE_DIMENSION as u32
    {
        return None;
    }
    let pixels = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    (pixels <= MAX_CLIPBOARD_IMAGE_PIXELS).then_some(pixels)
}

fn native_viewer_png_dimensions(payload: &[u8]) -> Option<(u32, u32)> {
    const SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if payload.len() < 33 || payload.get(..8)? != SIGNATURE {
        return None;
    }

    let mut offset = 8usize;
    let mut dimensions = None;
    let mut has_image_data = false;
    loop {
        let header_end = offset.checked_add(8)?;
        if header_end > payload.len() {
            return None;
        }
        let length = u32::from_be_bytes(payload[offset..offset + 4].try_into().ok()?) as usize;
        let chunk_type = &payload[offset + 4..header_end];
        let chunk_end = header_end.checked_add(length)?.checked_add(4)?;
        if chunk_end > payload.len() {
            return None;
        }
        let data = &payload[header_end..header_end + length];
        match chunk_type {
            b"IHDR" if offset == 8 && length == 13 && dimensions.is_none() => {
                let width = u32::from_be_bytes(data[0..4].try_into().ok()?);
                let height = u32::from_be_bytes(data[4..8].try_into().ok()?);
                native_viewer_image_pixel_count(width, height)?;
                let bit_depth = data[8];
                let color_type = data[9];
                let valid_depth = match color_type {
                    0 => matches!(bit_depth, 1 | 2 | 4 | 8 | 16),
                    2 | 4 | 6 => matches!(bit_depth, 8 | 16),
                    3 => matches!(bit_depth, 1 | 2 | 4 | 8),
                    _ => false,
                };
                if !valid_depth || data[10] != 0 || data[11] != 0 || data[12] > 1 {
                    return None;
                }
                dimensions = Some((width, height));
            }
            b"IHDR" => return None,
            b"IDAT" if dimensions.is_some() && length > 0 => has_image_data = true,
            b"IEND" if length == 0 => {
                return (chunk_end == payload.len() && has_image_data).then_some(dimensions?)
            }
            _ if dimensions.is_none() => return None,
            _ => {}
        }
        offset = chunk_end;
    }
}

fn native_viewer_svg_has_canonical_root(payload: &[u8]) -> Option<()> {
    let svg = std::str::from_utf8(payload).ok()?;
    if svg.contains('\0') {
        return None;
    }
    let mut remainder = svg.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if remainder.starts_with("<?xml") {
        let end = remainder.get(..1024.min(remainder.len()))?.find("?>")?;
        remainder = remainder[end + 2..].trim_start();
    }
    if remainder
        .as_bytes()
        .windows(9)
        .any(|window| window.eq_ignore_ascii_case(b"<!doctype"))
    {
        return None;
    }
    let after_root = remainder.strip_prefix("<svg")?;
    (after_root
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_whitespace() || *byte == b'>')
        && after_root.contains('>'))
    .then_some(())
}

unsafe fn native_viewer_clipboard_image_message(
    payload: &RDNClipboardImagePayload,
) -> Option<Message> {
    if payload.abi_version != ABI_VERSION || payload.data.is_null() || payload.length == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload.data, payload.length) };
    let (format, width, height) = match payload.format {
        CLIPBOARD_IMAGE_FORMAT_RGBA => {
            let pixel_count = native_viewer_image_pixel_count(payload.width, payload.height)?;
            let expected_bytes = pixel_count.checked_mul(4)?;
            if bytes.len() > MAX_CLIPBOARD_IMAGE_BYTES || bytes.len() != expected_bytes {
                return None;
            }
            (
                ClipboardFormat::ImageRgba,
                i32::try_from(payload.width).ok()?,
                i32::try_from(payload.height).ok()?,
            )
        }
        CLIPBOARD_IMAGE_FORMAT_PNG => {
            if payload.width != 0 || payload.height != 0 || bytes.len() > MAX_CLIPBOARD_IMAGE_BYTES
            {
                return None;
            }
            native_viewer_png_dimensions(bytes)?;
            (ClipboardFormat::ImagePng, 0, 0)
        }
        CLIPBOARD_IMAGE_FORMAT_SVG => {
            if payload.width != 0
                || payload.height != 0
                || bytes.len() > MAX_CLIPBOARD_SVG_UTF8_BYTES
            {
                return None;
            }
            native_viewer_svg_has_canonical_root(bytes)?;
            (ClipboardFormat::ImageSvg, 0, 0)
        }
        _ => return None,
    };
    let mut message = Message::new();
    message.set_clipboard(Clipboard {
        content: bytes.to_vec().into(),
        format: format.into(),
        width,
        height,
        ..Default::default()
    });
    Some(message)
}

fn native_viewer_clipboard_message(bytes: &[u8]) -> Option<Message> {
    let text = validated_clipboard_text(bytes)?;
    let mut message = Message::new();
    message.set_clipboard(Clipboard {
        content: text.as_bytes().to_vec().into(),
        format: ClipboardFormat::Text.into(),
        ..Default::default()
    });
    Some(message)
}

fn validated_clipboard_text(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() || bytes.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES {
        return None;
    }
    std::str::from_utf8(bytes)
        .ok()
        .filter(|text| !text.contains('\0'))
}

unsafe fn optional_clipboard_utf8(
    utf8: *const u8,
    length: usize,
    max_bytes: usize,
) -> Option<Option<String>> {
    if utf8.is_null() {
        return (length == 0).then_some(None);
    }
    if length == 0 || length > max_bytes {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(utf8, length) };
    let text = String::from_utf8(bytes.to_vec()).ok()?;
    (!text.contains('\0')).then_some(Some(text))
}

unsafe fn native_viewer_clipboard_rich_text_message(
    payload: &RDNClipboardRichTextPayload,
) -> Option<Message> {
    if payload.abi_version != ABI_VERSION {
        return None;
    }
    let plain_text = unsafe {
        optional_clipboard_utf8(
            payload.plain_utf8,
            payload.plain_length,
            MAX_CLIPBOARD_TEXT_UTF8_BYTES,
        )?
    };
    let rtf = unsafe {
        optional_clipboard_utf8(
            payload.rtf_utf8,
            payload.rtf_length,
            MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
        )?
    };
    let html = unsafe {
        optional_clipboard_utf8(
            payload.html_utf8,
            payload.html_length,
            MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
        )?
    };
    if rtf.is_none() && html.is_none() {
        return None;
    }

    let mut clipboards = Vec::with_capacity(3);
    for (format, text) in [
        (ClipboardFormat::Text, plain_text),
        (ClipboardFormat::Rtf, rtf),
        (ClipboardFormat::Html, html),
    ] {
        if let Some(text) = text {
            clipboards.push(Clipboard {
                content: text.into_bytes().into(),
                format: format.into(),
                ..Default::default()
            });
        }
    }
    let mut message = Message::new();
    if clipboards.len() == 1 {
        message.set_clipboard(clipboards.remove(0));
    } else {
        message.set_multi_clipboards(MultiClipboards {
            clipboards,
            ..Default::default()
        });
    }
    Some(message)
}
