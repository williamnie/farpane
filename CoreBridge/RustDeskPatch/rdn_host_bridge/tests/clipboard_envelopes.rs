    #[test]
    fn native_clipboard_data_plane_accepts_only_bounded_utf8_plain_text() {
        let at_limit = vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES];
        assert!(native_host_small_text_clipboard(&clipboard_fixture(
            at_limit.clone(),
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1],
            false,
            ClipboardFormat::Text,
        )));

        let compressed_at_limit = hbb_common::compress::compress(&at_limit);
        assert!(native_host_small_text_clipboard(&clipboard_fixture(
            compressed_at_limit,
            true,
            ClipboardFormat::Text,
        )));
        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_TEXT_UTF8_BYTES + 1]);
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            compressed_over_limit,
            true,
            ClipboardFormat::Text,
        )));

        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            vec![0xff],
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            b"before\0after".to_vec(),
            false,
            ClipboardFormat::Text,
        )));
        assert!(!native_host_small_text_clipboard(&clipboard_fixture(
            b"<b>rich</b>".to_vec(),
            false,
            ClipboardFormat::Html,
        )));
    }

    #[test]
    fn native_clipboard_payload_taxonomy_separates_inline_text_from_rich_transfer() {
        assert_eq!(
            native_host_clipboard_payload_disposition(&clipboard_fixture(
                b"small text".to_vec(),
                false,
                ClipboardFormat::Text,
            )),
            NativeClipboardPayloadDisposition::InlineSmallText
        );

        for format in [ClipboardFormat::Rtf, ClipboardFormat::Html] {
            let rich = clipboard_fixture(b"rich payload".to_vec(), false, format);
            assert_eq!(
                native_host_clipboard_payload_disposition(&rich),
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            );
            let mut message = Message::new();
            message.set_clipboard(rich);
            assert!(matches!(
                native_host_prepare_outgoing_clipboard_message(
                    &message,
                    NativeClipboardTransferPolicy::new(
                        NativeClipboardPolicy::new(true, true),
                        NativeClipboardPolicy::default(),
                    ),
                    NativeClipboardPolicy::new(true, true),
                ),
                NativeHostOutgoingClipboardDecision::Reject
            ));
        }

        let mut rgba = clipboard_fixture(vec![0, 0, 0, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert_eq!(
            native_host_clipboard_payload_disposition(&rgba),
            NativeClipboardPayloadDisposition::IndependentTransferRequired
        );
        let mut rgba_message = Message::new();
        rgba_message.set_clipboard(rgba);
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &rgba_message,
                NativeClipboardTransferPolicy::new(
                    NativeClipboardPolicy::default(),
                    NativeClipboardPolicy::new(true, true),
                ),
                NativeClipboardPolicy::new(true, true),
            ),
            NativeHostOutgoingClipboardDecision::Reject
        ));

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[0, 0, 0, 255]).unwrap();
        for image in [
            clipboard_fixture(png, false, ClipboardFormat::ImagePng),
            clipboard_fixture(
                b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec(),
                false,
                ClipboardFormat::ImageSvg,
            ),
        ] {
            assert_eq!(
                native_host_clipboard_payload_disposition(&image),
                NativeClipboardPayloadDisposition::IndependentTransferRequired
            );
            let mut message = Message::new();
            message.set_clipboard(image);
            assert!(matches!(
                native_host_prepare_outgoing_clipboard_message(
                    &message,
                    NativeClipboardTransferPolicy::new(
                        NativeClipboardPolicy::default(),
                        NativeClipboardPolicy::new(true, true),
                    ),
                    NativeClipboardPolicy::new(true, true),
                ),
                NativeHostOutgoingClipboardDecision::Reject
            ));
        }

        let mut malformed_html =
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        malformed_html.width = 1;
        assert_eq!(
            native_host_clipboard_payload_disposition(&malformed_html),
            NativeClipboardPayloadDisposition::Reject
        );

        let mut special = clipboard_fixture(b"untrusted".to_vec(), false, ClipboardFormat::Special);
        special.special_name = "untrusted.remote.uti".to_owned();
        assert_eq!(
            native_host_clipboard_payload_disposition(&special),
            NativeClipboardPayloadDisposition::Reject
        );

        let mut unknown = clipboard_fixture(b"unknown".to_vec(), false, ClipboardFormat::Text);
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert_eq!(
            native_host_clipboard_payload_disposition(&unknown),
            NativeClipboardPayloadDisposition::Reject
        );
    }

    #[test]
    fn native_rich_text_transfer_envelope_is_owned_bounded_and_strict() {
        for (format, expected) in [
            (ClipboardFormat::Rtf, NativeRichTextFormat::Rtf),
            (ClipboardFormat::Html, NativeRichTextFormat::Html),
        ] {
            let mut source = clipboard_fixture(b"rich text".to_vec(), false, format);
            let envelope = NativeRichTextTransferEnvelope::from_clipboard(&source).unwrap();
            source.content.clear();
            assert_eq!(envelope.format, expected);
            assert_eq!(envelope.payload, "rich text");
        }

        let at_limit = vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES];
        let envelope = NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
            at_limit.clone(),
            false,
            ClipboardFormat::Rtf,
        ))
        .unwrap();
        assert_eq!(envelope.payload.len(), MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES);

        let compressed_at_limit = hbb_common::compress::compress(&at_limit);
        let envelope = NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
            compressed_at_limit,
            true,
            ClipboardFormat::Html,
        ))
        .unwrap();
        assert_eq!(envelope.payload.len(), MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES);

        let compressed_over_limit =
            hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES + 1]);
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                compressed_over_limit,
                true,
                ClipboardFormat::Rtf,
            ))
            .is_none()
        );
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES + 1],
                false,
                ClipboardFormat::Html,
            ))
            .is_none()
        );

        for content in [vec![0xff], b"before\0after".to_vec()] {
            assert!(
                NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                    content,
                    false,
                    ClipboardFormat::Html,
                ))
                .is_none()
            );
        }

        let mut wrong_metadata =
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        wrong_metadata.special_name = "public.html".to_owned();
        assert!(NativeRichTextTransferEnvelope::from_clipboard(&wrong_metadata).is_none());

        for (width, height) in [(1, 0), (0, 1)] {
            let mut wrong_dimensions =
                clipboard_fixture(b"{\\rtf1}".to_vec(), false, ClipboardFormat::Rtf);
            wrong_dimensions.width = width;
            wrong_dimensions.height = height;
            assert!(NativeRichTextTransferEnvelope::from_clipboard(&wrong_dimensions).is_none());
        }
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                Vec::new(),
                false,
                ClipboardFormat::Rtf,
            ))
            .is_none()
        );

        let mut unknown_format = clipboard_fixture(b"rich".to_vec(), false, ClipboardFormat::Rtf);
        unknown_format.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(NativeRichTextTransferEnvelope::from_clipboard(&unknown_format).is_none());
        assert!(
            NativeRichTextTransferEnvelope::from_clipboard(&clipboard_fixture(
                b"plain".to_vec(),
                false,
                ClipboardFormat::Text,
            ))
            .is_none()
        );
    }

    #[test]
    fn native_image_transfer_envelope_is_owned_bounded_and_format_strict() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        let envelope = NativeImageTransferEnvelope::from_clipboard(&rgba).unwrap();
        assert_eq!(
            envelope.format,
            NativeImageFormat::Rgba {
                width: 1,
                height: 1,
            }
        );
        assert_eq!(envelope.payload, vec![1, 2, 3, 255]);
        rgba.content.clear();
        assert_eq!(envelope.payload, vec![1, 2, 3, 255]);

        let compressed_rgba = hbb_common::compress::compress(&[4, 5, 6, 255]);
        let mut rgba = clipboard_fixture(compressed_rgba, true, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&rgba).is_some());

        let mut wrong_rgba_length =
            clipboard_fixture(vec![1, 2, 3], false, ClipboardFormat::ImageRgba);
        wrong_rgba_length.width = 1;
        wrong_rgba_length.height = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&wrong_rgba_length).is_none());

        let mut excessive_rgba = clipboard_fixture(vec![0; 4], false, ClipboardFormat::ImageRgba);
        excessive_rgba.width = MAX_CLIPBOARD_IMAGE_DIMENSION + 1;
        excessive_rgba.height = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&excessive_rgba).is_none());
        excessive_rgba.width = MAX_CLIPBOARD_IMAGE_DIMENSION;
        excessive_rgba.height = MAX_CLIPBOARD_IMAGE_DIMENSION;
        assert!(NativeImageTransferEnvelope::from_clipboard(&excessive_rgba).is_none());

        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[7, 8, 9, 255]).unwrap();
        let envelope = NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
            png.clone(),
            false,
            ClipboardFormat::ImagePng,
        ))
        .unwrap();
        assert_eq!(
            envelope.format,
            NativeImageFormat::Png {
                width: 1,
                height: 1,
            }
        );
        assert_eq!(envelope.payload, png);

        let mut png_with_wire_dimensions =
            clipboard_fixture(png.clone(), false, ClipboardFormat::ImagePng);
        png_with_wire_dimensions.width = 1;
        assert!(NativeImageTransferEnvelope::from_clipboard(&png_with_wire_dimensions).is_none());
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                png[..24].to_vec(),
                false,
                ClipboardFormat::ImagePng,
            ))
            .is_none()
        );

        let mut compressed_png = clipboard_fixture(
            hbb_common::compress::compress(&png),
            true,
            ClipboardFormat::ImagePng,
        );
        assert!(NativeImageTransferEnvelope::from_clipboard(&compressed_png).is_none());
        compressed_png.compress = false;
        assert!(NativeImageTransferEnvelope::from_clipboard(&compressed_png).is_none());

        let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec();
        let envelope = NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
            hbb_common::compress::compress(&svg),
            true,
            ClipboardFormat::ImageSvg,
        ))
        .unwrap();
        assert_eq!(envelope.format, NativeImageFormat::Svg);
        assert_eq!(envelope.payload, svg);
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                b"<?xml version=\"1.0\"?><svg></svg>".to_vec(),
                false,
                ClipboardFormat::ImageSvg,
            ))
            .is_some()
        );

        for invalid_svg in [
            vec![0xff],
            b"before\0after".to_vec(),
            b"<html></html>".to_vec(),
            b"<svg ".to_vec(),
            b"<!DOCTYPE svg><svg></svg>".to_vec(),
        ] {
            assert!(
                NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                    invalid_svg,
                    false,
                    ClipboardFormat::ImageSvg,
                ))
                .is_none()
            );
        }
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                vec![b'a'; MAX_CLIPBOARD_SVG_UTF8_BYTES + 1],
                false,
                ClipboardFormat::ImageSvg,
            ))
            .is_none()
        );
        assert!(
            NativeImageTransferEnvelope::from_clipboard(&clipboard_fixture(
                hbb_common::compress::compress(&vec![b'a'; MAX_CLIPBOARD_SVG_UTF8_BYTES + 1]),
                true,
                ClipboardFormat::ImageSvg,
            ))
            .is_none()
        );

        let mut wrong_metadata = clipboard_fixture(png, false, ClipboardFormat::ImagePng);
        wrong_metadata.special_name = "public.png".to_owned();
        assert!(NativeImageTransferEnvelope::from_clipboard(&wrong_metadata).is_none());
        let mut unknown = clipboard_fixture(vec![1], false, ClipboardFormat::ImagePng);
        unknown.format = hbb_common::protobuf::EnumOrUnknown::from_i32(999);
        assert!(NativeImageTransferEnvelope::from_clipboard(&unknown).is_none());
    }

    #[test]
    fn native_host_outgoing_image_prefers_one_format_without_relaxing_remote_write() {
        let mut rgba = clipboard_fixture(vec![1, 2, 3, 255], false, ClipboardFormat::ImageRgba);
        rgba.width = 1;
        rgba.height = 1;
        let mut png = Vec::new();
        repng::encode(&mut png, 1, 1, &[1, 2, 3, 255]).unwrap();
        let png = clipboard_fixture(png, false, ClipboardFormat::ImagePng);
        let svg = clipboard_fixture(
            b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec(),
            false,
            ClipboardFormat::ImageSvg,
        );
        let transfer_policy = NativeClipboardTransferPolicy::with_image_policy(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(true, true),
        );
        let active = NativeClipboardPolicy::new(true, true);

        let outgoing = native_host_prepare_clipboard_entries(
            transfer_policy,
            active,
            NativeClipboardDirection::RemoteRead,
            &[rgba.clone(), png.clone(), svg.clone()],
        )
        .unwrap();
        assert_eq!(outgoing.len(), 1);
        assert_eq!(
            outgoing[0].format.enum_value(),
            Ok(ClipboardFormat::ImageSvg)
        );

        let png_outgoing = native_host_prepare_clipboard_entries(
            transfer_policy,
            active,
            NativeClipboardDirection::RemoteRead,
            &[rgba.clone(), png.clone()],
        )
        .unwrap();
        assert_eq!(png_outgoing.len(), 1);
        assert_eq!(
            png_outgoing[0].format.enum_value(),
            Ok(ClipboardFormat::ImagePng)
        );

        assert!(native_host_prepare_clipboard_entries(
            transfer_policy,
            active,
            NativeClipboardDirection::RemoteWrite,
            &[rgba, png],
        )
        .is_none());
        assert!(native_host_prepare_clipboard_entries(
            transfer_policy,
            active,
            NativeClipboardDirection::RemoteRead,
            &[
                svg,
                clipboard_fixture(b"not-image".to_vec(), false, ClipboardFormat::Text),
            ],
        )
        .is_none());
    }

    #[test]
    fn native_rich_text_transfer_bundle_is_owned_atomic_and_canonical() {
        let compressed_html = hbb_common::compress::compress(b"<b>rich</b>");
        let mut source = vec![
            clipboard_fixture(compressed_html, true, ClipboardFormat::Html),
            clipboard_fixture(b"plain fallback".to_vec(), false, ClipboardFormat::Text),
            clipboard_fixture(b"{\\rtf1 rich}".to_vec(), false, ClipboardFormat::Rtf),
        ];
        let bundle = NativeRichTextTransferBundle::from_clipboards(&source).unwrap();
        source
            .iter_mut()
            .for_each(|clipboard| clipboard.content.clear());
        assert_eq!(bundle.plain_text.as_deref(), Some("plain fallback"));
        assert_eq!(bundle.rtf.as_deref(), Some("{\\rtf1 rich}"));
        assert_eq!(bundle.html.as_deref(), Some("<b>rich</b>"));

        let canonical = bundle.into_canonical_clipboards();
        assert_eq!(canonical.len(), 3);
        for (clipboard, format, payload) in [
            (
                &canonical[0],
                ClipboardFormat::Text,
                b"plain fallback".as_slice(),
            ),
            (
                &canonical[1],
                ClipboardFormat::Rtf,
                b"{\\rtf1 rich}".as_slice(),
            ),
            (
                &canonical[2],
                ClipboardFormat::Html,
                b"<b>rich</b>".as_slice(),
            ),
        ] {
            assert_eq!(clipboard.format.enum_value(), Ok(format));
            assert_eq!(clipboard.content.as_ref(), payload);
            assert!(!clipboard.compress);
            assert!(clipboard.special_name.is_empty());
            assert_eq!((clipboard.width, clipboard.height), (0, 0));
        }

        let plain = clipboard_fixture(b"plain".to_vec(), false, ClipboardFormat::Text);
        let html = clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html);
        assert!(
            NativeRichTextTransferBundle::from_clipboards(std::slice::from_ref(&plain)).is_none()
        );
        assert!(NativeRichTextTransferBundle::from_clipboards(&[html.clone(), html]).is_none());
        assert!(
            NativeRichTextTransferBundle::from_clipboards(&[clipboard_fixture(
                b"image".to_vec(),
                false,
                ClipboardFormat::ImagePng
            ),])
            .is_none()
        );
    }

    #[test]
    fn native_host_rich_text_transport_requires_explicit_format_and_direction_policy() {
        let entries = vec![
            clipboard_fixture(b"plain fallback".to_vec(), false, ClipboardFormat::Text),
            clipboard_fixture(b"{\\rtf1 rich}".to_vec(), false, ClipboardFormat::Rtf),
            clipboard_fixture(b"<b>rich</b>".to_vec(), false, ClipboardFormat::Html),
        ];
        let rich_read = NativeClipboardTransferPolicy::new(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(true, false),
        );
        let rich_write = NativeClipboardTransferPolicy::new(
            NativeClipboardPolicy::default(),
            NativeClipboardPolicy::new(false, true),
        );
        let active_read = NativeClipboardPolicy::new(true, false);
        let active_write = NativeClipboardPolicy::new(false, true);
        let mut message = Message::new();
        message.set_multi_clipboards(MultiClipboards {
            clipboards: entries.clone(),
            ..Default::default()
        });

        let NativeHostOutgoingClipboardDecision::Send(canonical) =
            native_host_prepare_outgoing_clipboard_message(&message, rich_read, active_read)
        else {
            panic!("explicit rich read must admit the canonical bundle");
        };
        let Some(message::Union::MultiClipboards(canonical)) = canonical.union else {
            panic!("three representations must remain atomic");
        };
        assert_eq!(canonical.clipboards.len(), 3);
        assert!(canonical
            .clipboards
            .iter()
            .all(|clipboard| !clipboard.compress));

        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(
                &message,
                NativeClipboardTransferPolicy::new(
                    NativeClipboardPolicy::new(true, false),
                    NativeClipboardPolicy::default(),
                ),
                active_read,
            ),
            NativeHostOutgoingClipboardDecision::Reject
        ));
        assert!(matches!(
            native_host_prepare_outgoing_clipboard_message(&message, rich_read, active_write),
            NativeHostOutgoingClipboardDecision::Reject
        ));

        let incoming =
            native_host_prepare_incoming_clipboard_entries(&entries, rich_write, active_write)
                .expect("explicit rich write must admit a bounded canonical bundle");
        assert_eq!(incoming.len(), 3);
        assert!(incoming.iter().all(|clipboard| !clipboard.compress));
        assert!(
            native_host_prepare_incoming_clipboard_entries(&entries, rich_write, active_read,)
                .is_none()
        );
        assert!(
            native_host_prepare_incoming_clipboard_entries(&entries, rich_read, active_write,)
                .is_none()
        );
    }
