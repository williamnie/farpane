//! Canonical clipboard envelopes, shared by GUI, Viewer and Host adapters.
//! Payloads are not JSON fields and must never be included in Debug or errors.
//! Limits match the macOS FarPane contract; no image decoder/rendering is used.
use serde::{Deserialize, Serialize};
use std::{fmt, io};

pub const TEXT_LIMIT: usize = 64 * 1024;
pub const RICH_LIMIT: usize = 1024 * 1024;
pub const SVG_LIMIT: usize = 4 * 1024 * 1024;
pub const IMAGE_LIMIT: usize = 128 * 1024 * 1024;
pub const MAX_DIMENSION: u32 = 8192;
pub const MAX_PIXELS: usize = 7680 * 4320;
pub const MAX_PARTS: usize = 3;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Format {
    Text,
    Html,
    Rtf,
    Png,
    Rgba,
    Svg,
}
impl Format {
    pub fn limit(self) -> usize {
        match self {
            Self::Text => TEXT_LIMIT,
            Self::Html | Self::Rtf => RICH_LIMIT,
            Self::Svg => SVG_LIMIT,
            Self::Png | Self::Rgba => IMAGE_LIMIT,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    Text,
    RichText,
    Image,
}
pub fn category(formats: &[Format]) -> io::Result<Category> {
    if formats.is_empty()
        || formats.len() > MAX_PARTS
        || formats
            .iter()
            .enumerate()
            .any(|(i, f)| formats[..i].contains(f))
    {
        return Err(invalid());
    }
    if formats == [Format::Text] {
        Ok(Category::Text)
    } else if formats
        .iter()
        .all(|f| matches!(f, Format::Text | Format::Html | Format::Rtf))
    {
        Ok(Category::RichText)
    } else if formats.len() == 1 && matches!(formats[0], Format::Png | Format::Rgba | Format::Svg) {
        Ok(Category::Image)
    } else {
        Err(invalid())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Send,
    Receive,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Directions {
    pub send: bool,
    pub receive: bool,
}
impl Directions {
    pub fn allows(self, direction: Direction) -> bool {
        match direction {
            Direction::Send => self.send,
            Direction::Receive => self.receive,
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub text: Directions,
    pub rich_text: Directions,
    pub image: Directions,
}
impl Policy {
    pub fn allows(self, category: Category, direction: Direction) -> bool {
        match category {
            Category::Text => self.text,
            Category::RichText => self.rich_text,
            Category::Image => self.image,
        }
        .allows(direction)
    }
    pub fn any(self, direction: Direction) -> bool {
        [self.text, self.rich_text, self.image]
            .into_iter()
            .any(|p| p.allows(direction))
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Token {
    pub serial: u64,
    pub revision: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Item {
    pub format: Format,
    pub offset: u32,
    pub length: u32,
    pub width: u32,
    pub height: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Offer {
    pub token: Token,
    pub items: Vec<Item>,
}

pub(crate) fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Invalid clipboard envelope")
}
pub fn pixels(width: u32, height: u32) -> io::Result<usize> {
    let n = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(invalid)?;
    if width == 0
        || height == 0
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || n > MAX_PIXELS
    {
        return Err(invalid());
    }
    Ok(n)
}
impl Offer {
    /// Layout validation happens before mapping or decoding any payload.
    pub fn layout(&self) -> io::Result<(Category, usize)> {
        if self.token.serial == 0
            || self.token.revision == 0
            || self.items.is_empty()
            || self.items.len() > MAX_PARTS
        {
            return Err(invalid());
        }
        let mut length = 0usize;
        let mut seen = Vec::with_capacity(MAX_PARTS);
        for item in &self.items {
            if item.offset as usize != length
                || item.length == 0
                || item.length as usize > item.format.limit()
                || seen.contains(&item.format)
            {
                return Err(invalid());
            }
            seen.push(item.format);
            if item.format == Format::Rgba {
                if pixels(item.width, item.height)?.checked_mul(4) != Some(item.length as usize) {
                    return Err(invalid());
                }
            } else if item.width != 0 || item.height != 0 {
                return Err(invalid());
            }
            length = length
                .checked_add(item.length as usize)
                .ok_or_else(invalid)?;
            if length > IMAGE_LIMIT {
                return Err(invalid());
            }
        }
        // Plain-text fallback belongs to the rich bundle's grant, as on Mac;
        // a separate text-only offer still needs the independent text grant.
        let category = category(&seen)?;
        Ok((category, length))
    }
    pub fn validate(&self, bytes: &[u8]) -> io::Result<Category> {
        let (kind, length) = self.layout()?;
        if bytes.len() != length {
            return Err(invalid());
        }
        for item in &self.items {
            let start = item.offset as usize;
            validate_item(item, &bytes[start..start + item.length as usize])?;
        }
        Ok(kind)
    }
}

pub struct Part<B = Vec<u8>> {
    pub format: Format,
    pub width: u32,
    pub height: u32,
    pub bytes: B,
}
impl<B: AsRef<[u8]>> fmt::Debug for Part<B> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClipboardPart")
            .field("format", &self.format)
            .field("length", &self.bytes.as_ref().len())
            .finish()
    }
}
impl Part {
    pub fn new(format: Format, bytes: Vec<u8>) -> Self {
        Self {
            format,
            width: 0,
            height: 0,
            bytes,
        }
    }
}
pub fn describe<B: AsRef<[u8]>>(token: Token, parts: &[Part<B>]) -> io::Result<Offer> {
    if parts.is_empty() || parts.len() > MAX_PARTS {
        return Err(invalid());
    }
    let mut items = Vec::with_capacity(parts.len());
    let mut offset = 0usize;
    for part in parts {
        let length = u32::try_from(part.bytes.as_ref().len()).map_err(|_| invalid())?;
        let item = Item {
            format: part.format,
            offset: u32::try_from(offset).map_err(|_| invalid())?,
            length,
            width: part.width,
            height: part.height,
        };
        validate_item(&item, part.bytes.as_ref())?;
        offset = offset
            .checked_add(part.bytes.as_ref().len())
            .ok_or_else(invalid)?;
        items.push(item);
    }
    let offer = Offer { token, items };
    offer.layout()?;
    Ok(offer)
}
pub fn validate_item(item: &Item, bytes: &[u8]) -> io::Result<()> {
    if bytes.is_empty() || bytes.len() != item.length as usize || bytes.len() > item.format.limit()
    {
        return Err(invalid());
    }
    if item.format != Format::Rgba && (item.width != 0 || item.height != 0) {
        return Err(invalid());
    }
    match item.format {
        Format::Text | Format::Html | Format::Rtf => {
            utf8(bytes)?;
        }
        Format::Rgba => {
            if pixels(item.width, item.height)?.checked_mul(4) != Some(bytes.len()) {
                return Err(invalid());
            }
        }
        Format::Png => {
            png_dimensions(bytes)?;
        }
        Format::Svg => {
            svg(bytes)?;
        }
    }
    Ok(())
}
fn utf8(bytes: &[u8]) -> io::Result<&str> {
    if bytes.contains(&0) {
        return Err(invalid());
    }
    std::str::from_utf8(bytes).map_err(|_| invalid())
}
/// Structural/dimension admission, not an image decode or proof of IDAT/CRC
/// correctness. Never rasterize PNGs just to offer a clipboard MIME type.
pub fn png_dimensions(payload: &[u8]) -> io::Result<(u32, u32)> {
    if payload.len() < 33 || payload.get(..8) != Some(b"\x89PNG\r\n\x1a\n") {
        return Err(invalid());
    }
    let mut offset = 8usize;
    let mut dimensions = None;
    let mut image_data = false;
    loop {
        let header_end = offset.checked_add(8).ok_or_else(invalid)?;
        let header = payload.get(offset..header_end).ok_or_else(invalid)?;
        let length = u32::from_be_bytes(header[..4].try_into().unwrap()) as usize;
        let end = header_end
            .checked_add(length)
            .and_then(|n| n.checked_add(4))
            .ok_or_else(invalid)?;
        if end > payload.len() {
            return Err(invalid());
        }
        let data = &payload[header_end..header_end + length];
        match &header[4..] {
            b"IHDR" if offset == 8 && length == 13 && dimensions.is_none() => {
                let width = u32::from_be_bytes(data[0..4].try_into().unwrap());
                let height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                pixels(width, height)?;
                let valid = match data[9] {
                    0 => matches!(data[8], 1 | 2 | 4 | 8 | 16),
                    2 | 4 | 6 => matches!(data[8], 8 | 16),
                    3 => matches!(data[8], 1 | 2 | 4 | 8),
                    _ => false,
                };
                if !valid || data[10] != 0 || data[11] != 0 || data[12] > 1 {
                    return Err(invalid());
                }
                dimensions = Some((width, height));
            }
            b"IHDR" => return Err(invalid()),
            b"IDAT" if dimensions.is_some() && length > 0 => image_data = true,
            b"IEND" if length == 0 && end == payload.len() && image_data => {
                return dimensions.ok_or_else(invalid)
            }
            b"IEND" => return Err(invalid()),
            _ if dimensions.is_none() => return Err(invalid()),
            _ => {}
        }
        offset = end;
    }
}
fn svg(payload: &[u8]) -> io::Result<()> {
    let text = utf8(payload)?;
    let mut rest = text.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if rest.starts_with("<?xml") {
        // byte windows avoid slicing a UTF-8 character at byte 1024.
        let end = rest.as_bytes()[..rest.len().min(1024)]
            .windows(2)
            .position(|p| p == b"?>")
            .ok_or_else(invalid)?;
        rest = rest[end + 2..].trim_start();
    }
    if rest
        .as_bytes()
        .windows(9)
        .any(|p| p.eq_ignore_ascii_case(b"<!doctype"))
    {
        return Err(invalid());
    }
    let after = rest.strip_prefix("<svg").ok_or_else(invalid)?;
    if !after
        .as_bytes()
        .first()
        .is_some_and(|b| b.is_ascii_whitespace() || *b == b'>')
        || !after.contains('>')
    {
        return Err(invalid());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn token() -> Token {
        Token {
            serial: 1,
            revision: 1,
        }
    }
    #[test]
    fn bundles_require_one_category_unique_formats_and_exact_bounds() {
        let parts = vec![
            Part::new(Format::Text, b"plain".to_vec()),
            Part::new(Format::Html, b"<b>plain</b>".to_vec()),
            Part::new(Format::Rtf, b"{\\rtf1 plain}".to_vec()),
        ];
        let offer = describe(token(), &parts).unwrap();
        let bytes = parts
            .iter()
            .flat_map(|p| p.bytes.iter().copied())
            .collect::<Vec<_>>();
        assert_eq!(offer.validate(&bytes).unwrap(), Category::RichText);
        let mut overlap = offer.clone();
        overlap.items[1].offset = 0;
        assert!(overlap.layout().is_err());
        let mut duplicate = offer.clone();
        duplicate.items[1].format = Format::Text;
        assert!(duplicate.layout().is_err());
        assert!(offer.validate(&bytes[..bytes.len() - 1]).is_err());
        assert!(describe(
            token(),
            &[Part::new(Format::Text, vec![b'x'; TEXT_LIMIT + 1])]
        )
        .is_err());
        assert!(describe(
            token(),
            &[Part::new(Format::Text, b"hidden\0data".to_vec())]
        )
        .is_err());
        assert!(describe(token(), &[Part::new(Format::Html, vec![0xff])]).is_err());
        let mut image = offer;
        image.items[1].format = Format::Svg;
        assert!(image.layout().is_err());
    }
    #[test]
    fn grants_are_per_type_and_direction_and_do_not_enable_text_fallback_alone() {
        let p = Policy {
            rich_text: Directions {
                send: true,
                receive: false,
            },
            ..Default::default()
        };
        assert!(p.allows(Category::RichText, Direction::Send));
        assert!(!p.allows(Category::Text, Direction::Send));
        assert!(!p.any(Direction::Receive));
        assert!(!Policy::default().any(Direction::Send));
        let part = Part::new(Format::Rtf, b"{\\rtf1 private-content}".to_vec());
        assert!(!format!("{part:?}").contains("private-content"));
    }
    #[test]
    fn image_admission_rejects_overflow_noncanonical_svg_and_png_truncation() {
        assert!(pixels(8192, 8192).is_err());
        assert!(pixels(u32::MAX, u32::MAX).is_err());
        assert!(pixels(0, 1).is_err());
        let part = Part {
            format: Format::Rgba,
            width: 2,
            height: 1,
            bytes: vec![0; 8],
        };
        assert!(describe(token(), &[part]).is_ok());
        for bytes in [
            b"<!DOCTYPE svg><svg/>".as_slice(),
            b"<svgx>bad</svgx>",
            b"<svg>\0</svg>",
        ] {
            assert!(describe(token(), &[Part::new(Format::Svg, bytes.to_vec())]).is_err());
        }
        assert!(describe(
            token(),
            &[Part::new(
                Format::Svg,
                b"<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".to_vec()
            )]
        )
        .is_ok());
        // Canonical PNG chunk structure fixture; this validator does not decode IDAT.
        fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
            out.extend_from_slice(&(data.len() as u32).to_be_bytes());
            out.extend_from_slice(kind);
            out.extend_from_slice(data);
            out.extend_from_slice(&[0; 4]);
        }
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        let mut ihdr = vec![0, 0, 0, 2, 0, 0, 0, 1, 8, 6, 0, 0, 0];
        chunk(&mut png, b"IHDR", &ihdr);
        chunk(&mut png, b"IDAT", &[1]);
        chunk(&mut png, b"IEND", &[]);
        assert_eq!(png_dimensions(&png).unwrap(), (2, 1));
        for end in 0..png.len() {
            assert!(png_dimensions(&png[..end]).is_err());
        }
        ihdr[0..4].copy_from_slice(&9000u32.to_be_bytes());
        let mut large = b"\x89PNG\r\n\x1a\n".to_vec();
        chunk(&mut large, b"IHDR", &ihdr);
        chunk(&mut large, b"IDAT", &[1]);
        chunk(&mut large, b"IEND", &[]);
        assert!(png_dimensions(&large).is_err());
        png.push(0);
        assert!(png_dimensions(&png).is_err());
    }
}
