#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeClipboardPolicy {
    remote_read: bool,
    remote_write: bool,
}

impl NativeClipboardPolicy {
    pub(crate) fn new(remote_read: bool, remote_write: bool) -> Self {
        Self {
            remote_read,
            remote_write,
        }
    }

    pub(crate) fn bidirectional(enabled: bool) -> Self {
        Self::new(enabled, enabled)
    }

    pub(crate) fn allows_remote_read(self) -> bool {
        self.remote_read
    }

    pub(crate) fn allows_remote_write(self) -> bool {
        self.remote_write
    }

    pub(crate) fn restricted_to(self, enabled: bool) -> Self {
        if enabled {
            self
        } else {
            Self::default()
        }
    }

    fn any_enabled(self) -> bool {
        self.remote_read || self.remote_write
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.remote_read || other.remote_read) && (!self.remote_write || other.remote_write)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct NativeClipboardTransferPolicy {
    small_text: NativeClipboardPolicy,
    rich_text: NativeClipboardPolicy,
    image: NativeClipboardPolicy,
}

impl NativeClipboardTransferPolicy {
    pub(crate) fn new(small_text: NativeClipboardPolicy, rich_text: NativeClipboardPolicy) -> Self {
        Self::with_image_policy(small_text, rich_text, NativeClipboardPolicy::default())
    }

    pub(crate) fn with_image_policy(
        small_text: NativeClipboardPolicy,
        rich_text: NativeClipboardPolicy,
        image: NativeClipboardPolicy,
    ) -> Self {
        Self {
            small_text,
            rich_text,
            image,
        }
    }

    pub(crate) fn small_text(self) -> NativeClipboardPolicy {
        self.small_text
    }

    pub(crate) fn rich_text(self) -> NativeClipboardPolicy {
        self.rich_text
    }

    pub(crate) fn image(self) -> NativeClipboardPolicy {
        self.image
    }

    pub(crate) fn directions(self) -> NativeClipboardPolicy {
        NativeClipboardPolicy::new(
            self.small_text.allows_remote_read()
                || self.rich_text.allows_remote_read()
                || self.image.allows_remote_read(),
            self.small_text.allows_remote_write()
                || self.rich_text.allows_remote_write()
                || self.image.allows_remote_write(),
        )
    }

    fn any_enabled(self) -> bool {
        self.small_text.any_enabled() || self.rich_text.any_enabled() || self.image.any_enabled()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeClipboardDirection {
    RemoteRead,
    RemoteWrite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeClipboardPayloadDisposition {
    InlineSmallText,
    // This remains a routing requirement rather than admission: a separate
    // format-specific direction policy must authorize the bounded canonical payload.
    IndependentTransferRequired,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeRichTextFormat {
    Rtf,
    Html,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeRichTextTransferEnvelope {
    format: NativeRichTextFormat,
    payload: String,
}

impl NativeRichTextTransferEnvelope {
    fn from_clipboard(clipboard: &Clipboard) -> Option<Self> {
        let format = match clipboard.format.enum_value().ok()? {
            ClipboardFormat::Rtf => NativeRichTextFormat::Rtf,
            ClipboardFormat::Html => NativeRichTextFormat::Html,
            _ => return None,
        };
        if !clipboard.special_name.is_empty()
            || clipboard.width != 0
            || clipboard.height != 0
            || clipboard.content.is_empty()
            || clipboard.content.len() > MAX_CLIPBOARD_RICH_TEXT_WIRE_BYTES
        {
            return None;
        }
        let decoded = if clipboard.compress {
            hbb_common::compress::decompress_with_limit(
                &clipboard.content,
                MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES,
            )
            .ok()?
        } else {
            clipboard.content.to_vec()
        };
        if decoded.is_empty() || decoded.len() > MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES {
            return None;
        }
        let payload = String::from_utf8(decoded).ok()?;
        if payload.contains('\0') {
            return None;
        }
        Some(Self { format, payload })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeImageFormat {
    Rgba { width: i32, height: i32 },
    Png { width: i32, height: i32 },
    Svg,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeImageTransferEnvelope {
    format: NativeImageFormat,
    payload: Vec<u8>,
}

impl NativeImageTransferEnvelope {
    fn from_clipboard(clipboard: &Clipboard) -> Option<Self> {
        if !clipboard.special_name.is_empty() {
            return None;
        }
        match clipboard.format.enum_value().ok()? {
            ClipboardFormat::ImageRgba => {
                let pixel_count = native_image_pixel_count(clipboard.width, clipboard.height)?;
                let expected_bytes = pixel_count.checked_mul(4)?;
                let payload = native_image_payload_bytes(
                    clipboard,
                    MAX_CLIPBOARD_IMAGE_WIRE_BYTES,
                    MAX_CLIPBOARD_IMAGE_DECODED_BYTES,
                    true,
                )?;
                if payload.len() != expected_bytes {
                    return None;
                }
                Some(Self {
                    format: NativeImageFormat::Rgba {
                        width: clipboard.width,
                        height: clipboard.height,
                    },
                    payload,
                })
            }
            ClipboardFormat::ImagePng => {
                if clipboard.width != 0 || clipboard.height != 0 {
                    return None;
                }
                // Pinned upstream already emits PNG as its compressed image
                // representation, so a second zstd layer is non-canonical.
                let payload = native_image_payload_bytes(
                    clipboard,
                    MAX_CLIPBOARD_IMAGE_WIRE_BYTES,
                    MAX_CLIPBOARD_IMAGE_WIRE_BYTES,
                    false,
                )?;
                let (width, height) = native_png_dimensions(&payload)?;
                Some(Self {
                    format: NativeImageFormat::Png { width, height },
                    payload,
                })
            }
            ClipboardFormat::ImageSvg => {
                if clipboard.width != 0 || clipboard.height != 0 {
                    return None;
                }
                let payload = native_image_payload_bytes(
                    clipboard,
                    MAX_CLIPBOARD_SVG_WIRE_BYTES,
                    MAX_CLIPBOARD_SVG_UTF8_BYTES,
                    true,
                )?;
                let svg = std::str::from_utf8(&payload).ok()?;
                if svg.contains('\0') || !native_svg_has_canonical_root(svg) {
                    return None;
                }
                Some(Self {
                    format: NativeImageFormat::Svg,
                    payload,
                })
            }
            _ => None,
        }
    }

    fn into_canonical_clipboard(self) -> Clipboard {
        let (format, width, height) = match self.format {
            NativeImageFormat::Rgba { width, height } => {
                (ClipboardFormat::ImageRgba, width, height)
            }
            NativeImageFormat::Png { .. } => (ClipboardFormat::ImagePng, 0, 0),
            NativeImageFormat::Svg => (ClipboardFormat::ImageSvg, 0, 0),
        };
        Clipboard {
            content: self.payload.into(),
            format: format.into(),
            width,
            height,
            ..Default::default()
        }
    }

    fn outgoing_preference(&self) -> u8 {
        match self.format {
            NativeImageFormat::Svg => 3,
            NativeImageFormat::Png { .. } => 2,
            NativeImageFormat::Rgba { .. } => 1,
        }
    }
}

fn native_host_preferred_outgoing_image(
    clipboards: &[Clipboard],
) -> Option<NativeImageTransferEnvelope> {
    let mut preferred: Option<NativeImageTransferEnvelope> = None;
    for clipboard in clipboards {
        let candidate = NativeImageTransferEnvelope::from_clipboard(clipboard)?;
        if preferred
            .as_ref()
            .map(|current| candidate.outgoing_preference() > current.outgoing_preference())
            .unwrap_or(true)
        {
            preferred = Some(candidate);
        }
    }
    preferred
}

fn native_image_payload_bytes(
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

fn native_image_pixel_count(width: i32, height: i32) -> Option<usize> {
    if width <= 0
        || height <= 0
        || width > MAX_CLIPBOARD_IMAGE_DIMENSION
        || height > MAX_CLIPBOARD_IMAGE_DIMENSION
    {
        return None;
    }
    let pixels = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    (pixels <= MAX_CLIPBOARD_IMAGE_PIXELS).then_some(pixels)
}

fn native_png_dimensions(payload: &[u8]) -> Option<(i32, i32)> {
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
                let width = i32::try_from(width).ok()?;
                let height = i32::try_from(height).ok()?;
                native_image_pixel_count(width, height)?;
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

fn native_svg_has_canonical_root(svg: &str) -> bool {
    let mut remainder = svg.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if remainder.starts_with("<?xml") {
        let Some(end) = remainder
            .get(..1024.min(remainder.len()))
            .and_then(|prefix| prefix.find("?>"))
        else {
            return false;
        };
        remainder = remainder[end + 2..].trim_start();
    }
    if remainder
        .as_bytes()
        .windows(9)
        .any(|window| window.eq_ignore_ascii_case(b"<!doctype"))
    {
        return false;
    }
    let Some(after_root) = remainder.strip_prefix("<svg") else {
        return false;
    };
    after_root
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_whitespace() || *byte == b'>')
        && after_root.contains('>')
}

pub(crate) fn native_host_configured_clipboard_transfer_policy() -> NativeClipboardTransferPolicy {
    let broker = MEDIA_BROKER.lock().unwrap();
    if broker.binding.is_some() {
        broker.clipboard_transfer_policy
    } else {
        NativeClipboardTransferPolicy::default()
    }
}

fn native_host_small_text_payload(clipboard: &Clipboard) -> Option<String> {
    if clipboard.format.enum_value().ok()? != ClipboardFormat::Text
        || !clipboard.special_name.is_empty()
        || clipboard.width != 0
        || clipboard.height != 0
        || clipboard.content.is_empty()
        || clipboard.content.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES
    {
        return None;
    }
    let decoded = if clipboard.compress {
        hbb_common::compress::decompress_with_limit(
            &clipboard.content,
            MAX_CLIPBOARD_TEXT_UTF8_BYTES,
        )
        .ok()?
    } else {
        clipboard.content.to_vec()
    };
    if decoded.is_empty() || decoded.len() > MAX_CLIPBOARD_TEXT_UTF8_BYTES {
        return None;
    }
    let text = String::from_utf8(decoded).ok()?;
    (!text.contains('\0')).then_some(text)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct NativeRichTextTransferBundle {
    plain_text: Option<String>,
    rtf: Option<String>,
    html: Option<String>,
}

impl NativeRichTextTransferBundle {
    fn from_clipboards(clipboards: &[Clipboard]) -> Option<Self> {
        if clipboards.is_empty() || clipboards.len() > 3 {
            return None;
        }
        let mut bundle = Self::default();
        for clipboard in clipboards {
            match clipboard.format.enum_value().ok()? {
                ClipboardFormat::Text => {
                    if bundle.plain_text.is_some() {
                        return None;
                    }
                    bundle.plain_text = Some(native_host_small_text_payload(clipboard)?);
                }
                ClipboardFormat::Rtf | ClipboardFormat::Html => {
                    let envelope = NativeRichTextTransferEnvelope::from_clipboard(clipboard)?;
                    match envelope.format {
                        NativeRichTextFormat::Rtf => {
                            if bundle.rtf.is_some() {
                                return None;
                            }
                            bundle.rtf = Some(envelope.payload);
                        }
                        NativeRichTextFormat::Html => {
                            if bundle.html.is_some() {
                                return None;
                            }
                            bundle.html = Some(envelope.payload);
                        }
                    }
                }
                _ => return None,
            }
        }
        (bundle.rtf.is_some() || bundle.html.is_some()).then_some(bundle)
    }

    fn into_canonical_clipboards(self) -> Vec<Clipboard> {
        let mut clipboards = Vec::with_capacity(3);
        for (format, payload) in [
            (ClipboardFormat::Text, self.plain_text),
            (ClipboardFormat::Rtf, self.rtf),
            (ClipboardFormat::Html, self.html),
        ] {
            if let Some(payload) = payload {
                clipboards.push(native_host_canonical_clipboard(format, payload));
            }
        }
        clipboards
    }
}

fn native_host_canonical_clipboard(format: ClipboardFormat, payload: String) -> Clipboard {
    Clipboard {
        content: payload.into_bytes().into(),
        format: format.into(),
        ..Default::default()
    }
}

fn native_host_clipboard_payload_disposition(
    clipboard: &Clipboard,
) -> NativeClipboardPayloadDisposition {
    let Ok(format) = clipboard.format.enum_value() else {
        return NativeClipboardPayloadDisposition::Reject;
    };
    match format {
        ClipboardFormat::Text => {
            if native_host_small_text_payload(clipboard).is_some() {
                NativeClipboardPayloadDisposition::InlineSmallText
            } else {
                NativeClipboardPayloadDisposition::Reject
            }
        }
        ClipboardFormat::Rtf | ClipboardFormat::Html => {
            NativeRichTextTransferEnvelope::from_clipboard(clipboard)
                .map_or(NativeClipboardPayloadDisposition::Reject, |_| {
                    NativeClipboardPayloadDisposition::IndependentTransferRequired
                })
        }
        ClipboardFormat::ImageRgba | ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg => {
            NativeImageTransferEnvelope::from_clipboard(clipboard)
                .map_or(NativeClipboardPayloadDisposition::Reject, |_| {
                    NativeClipboardPayloadDisposition::IndependentTransferRequired
                })
        }
        // Special names are remote-controlled UTI/format identifiers. They
        // stay rejected until an explicit allowlist and bounded transfer
        // envelope own both the identifier and payload.
        ClipboardFormat::Special => NativeClipboardPayloadDisposition::Reject,
    }
}

fn native_host_small_text_clipboard(clipboard: &Clipboard) -> bool {
    native_host_clipboard_payload_disposition(clipboard)
        == NativeClipboardPayloadDisposition::InlineSmallText
}

fn native_host_clipboard_policy_allows(
    policy: NativeClipboardPolicy,
    direction: NativeClipboardDirection,
) -> bool {
    match direction {
        NativeClipboardDirection::RemoteRead => policy.allows_remote_read(),
        NativeClipboardDirection::RemoteWrite => policy.allows_remote_write(),
    }
}

fn native_host_clipboard_entries_disposition(
    clipboards: &[Clipboard],
) -> NativeClipboardPayloadDisposition {
    if clipboards.len() == 1
        && clipboards
            .first()
            .is_some_and(native_host_small_text_clipboard)
    {
        NativeClipboardPayloadDisposition::InlineSmallText
    } else if NativeRichTextTransferBundle::from_clipboards(clipboards).is_some()
        || (clipboards.len() == 1
            && clipboards
                .first()
                .and_then(NativeImageTransferEnvelope::from_clipboard)
                .is_some())
    {
        NativeClipboardPayloadDisposition::IndependentTransferRequired
    } else {
        NativeClipboardPayloadDisposition::Reject
    }
}

fn native_host_prepare_clipboard_entries(
    transfer_policy: NativeClipboardTransferPolicy,
    active_directions: NativeClipboardPolicy,
    direction: NativeClipboardDirection,
    clipboards: &[Clipboard],
) -> Option<Vec<Clipboard>> {
    if !native_host_clipboard_policy_allows(active_directions, direction) {
        return None;
    }
    if direction == NativeClipboardDirection::RemoteRead {
        if let Some(image) = native_host_preferred_outgoing_image(clipboards) {
            return native_host_clipboard_policy_allows(transfer_policy.image(), direction)
                .then(|| vec![image.into_canonical_clipboard()]);
        }
    }
    if let [clipboard] = clipboards {
        if let Some(image) = NativeImageTransferEnvelope::from_clipboard(clipboard) {
            return native_host_clipboard_policy_allows(transfer_policy.image(), direction)
                .then(|| vec![image.into_canonical_clipboard()]);
        }
    }
    match native_host_clipboard_entries_disposition(clipboards) {
        NativeClipboardPayloadDisposition::InlineSmallText
            if native_host_clipboard_policy_allows(transfer_policy.small_text(), direction) =>
        {
            let text = native_host_small_text_payload(clipboards.first()?)?;
            Some(vec![native_host_canonical_clipboard(
                ClipboardFormat::Text,
                text,
            )])
        }
        NativeClipboardPayloadDisposition::IndependentTransferRequired
            if native_host_clipboard_policy_allows(transfer_policy.rich_text(), direction) =>
        {
            Some(
                NativeRichTextTransferBundle::from_clipboards(clipboards)?
                    .into_canonical_clipboards(),
            )
        }
        _ => None,
    }
}

#[derive(Debug)]
pub(crate) enum NativeHostOutgoingClipboardDecision {
    NotClipboard,
    Send(Message),
    Reject,
}

pub(crate) fn native_host_prepare_outgoing_clipboard_message(
    message: &Message,
    transfer_policy: NativeClipboardTransferPolicy,
    active_directions: NativeClipboardPolicy,
) -> NativeHostOutgoingClipboardDecision {
    let entries = match message.union.as_ref() {
        Some(message::Union::Clipboard(clipboard)) => std::slice::from_ref(clipboard),
        Some(message::Union::MultiClipboards(clipboards)) => clipboards.clipboards.as_slice(),
        _ => return NativeHostOutgoingClipboardDecision::NotClipboard,
    };
    let Some(mut clipboards) = native_host_prepare_clipboard_entries(
        transfer_policy,
        active_directions,
        NativeClipboardDirection::RemoteRead,
        entries,
    ) else {
        return NativeHostOutgoingClipboardDecision::Reject;
    };
    let mut canonical = Message::new();
    if clipboards.len() == 1 {
        canonical.set_clipboard(clipboards.remove(0));
    } else {
        canonical.set_multi_clipboards(MultiClipboards {
            clipboards,
            ..Default::default()
        });
    }
    NativeHostOutgoingClipboardDecision::Send(canonical)
}

pub(crate) fn native_host_prepare_incoming_clipboard_entries(
    clipboards: &[Clipboard],
    transfer_policy: NativeClipboardTransferPolicy,
    active_directions: NativeClipboardPolicy,
) -> Option<Vec<Clipboard>> {
    native_host_prepare_clipboard_entries(
        transfer_policy,
        active_directions,
        NativeClipboardDirection::RemoteWrite,
        clipboards,
    )
}
