//! Metadata accompanying SCM_RIGHTS. Validate before importing any GPU object.
use serde::{Deserialize, Serialize};

pub const R8: u32 = u32::from_le_bytes(*b"R8  ");
pub const GR88: u32 = u32::from_le_bytes(*b"GR88");
pub const MAX_LEASES: usize = 3;

/// Sealed memfd in software compatibility mode. BGRA, opaque alpha, tight rows.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SoftwareFrame {
    pub generation: u64,
    pub lease: u64,
    pub pts: i64,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
}
impl SoftwareFrame {
    pub fn byte_len(&self) -> Result<usize, &'static str> {
        if self.generation == 0
            || self.lease == 0
            || self.width == 0
            || self.height == 0
            || u64::from(self.width) * u64::from(self.height) > 2560 * 1600
            || self.stride != self.width.checked_mul(4).ok_or("software row overflow")?
        {
            return Err("invalid software frame");
        }
        usize::try_from(u64::from(self.stride) * u64::from(self.height))
            .map_err(|_| "software frame overflow")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Frame {
    pub generation: u64,
    pub lease: u64,
    pub pts: i64,
    pub width: u32,
    pub height: u32,
    pub objects: Vec<Object>,
    pub layers: Vec<Layer>,
    pub color: Color,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Object {
    pub size: u64,
    pub modifier: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Layer {
    pub format: u32,
    pub planes: Vec<Plane>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Plane {
    pub object: u32,
    pub offset: u64,
    pub pitch: u32,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Matrix {
    Bt601,
    Bt709,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Range {
    Limited,
    Full,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Chroma {
    Left,
    Center,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ColorSource {
    Vui,
    CompatibilityDefault,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Color {
    pub matrix: Matrix,
    pub range: Range,
    pub chroma: Chroma,
    /// H.273 values; HDR transfer characteristics are rejected by the SDR path.
    pub primaries: u8,
    pub transfer: u8,
    pub source: ColorSource,
}
impl Color {
    pub fn compatibility_default(height: u32) -> Self {
        Self {
            matrix: if height > 576 {
                Matrix::Bt709
            } else {
                Matrix::Bt601
            },
            range: Range::Limited,
            chroma: Chroma::Left,
            primaries: 2,
            transfer: 2,
            source: ColorSource::CompatibilityDefault,
        }
    }
}

impl Frame {
    pub fn validate(&self, received_fds: usize, generation: u64) -> Result<(), &'static str> {
        if self.generation == 0 || self.generation != generation || self.lease == 0 {
            return Err("stale generation or invalid lease");
        }
        if self.width == 0
            || self.height == 0
            || self.width > 8192
            || self.height > 8192
            || self.width % 2 != 0
            || self.height % 2 != 0
        {
            return Err("invalid NV12 dimensions");
        }
        if self.objects.is_empty() || self.objects.len() > 4 || self.objects.len() != received_fds {
            return Err("object/FD count mismatch");
        }
        if self
            .objects
            .iter()
            .any(|o| o.size == 0 || o.size > 256 * 1024 * 1024)
        {
            return Err("invalid object size");
        }
        if self.layers.len() != 2 || self.layers[0].format != R8 || self.layers[1].format != GR88 {
            return Err("expected separate Y and UV layers");
        }
        if matches!(self.color.transfer, 16 | 18) {
            return Err("HDR requires a separate color pipeline");
        }
        let mut used = [false; 4];
        for (index, layer) in self.layers.iter().enumerate() {
            if layer.planes.len() != 1 {
                return Err("expected one plane per layer");
            }
            let plane = &layer.planes[0];
            let object = self
                .objects
                .get(plane.object as usize)
                .ok_or("invalid object index")?;
            used[plane.object as usize] = true;
            if plane.pitch < self.width || plane.pitch > 1024 * 1024 {
                return Err("invalid plane pitch");
            }
            let rows = if index == 0 {
                self.height
            } else {
                self.height / 2
            };
            let end = plane
                .offset
                .checked_add(u64::from(plane.pitch) * u64::from(rows - 1))
                .and_then(|n| n.checked_add(u64::from(self.width)))
                .ok_or("plane overflow")?;
            if end > object.size {
                return Err("plane exceeds object bounds");
            }
        }
        if used[..self.objects.len()].iter().any(|used| !used) {
            return Err("unreferenced object");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Frame {
        Frame {
            generation: 3,
            lease: 1,
            pts: 0,
            width: 256,
            height: 128,
            objects: vec![
                Object {
                    size: 256 * 128,
                    modifier: 0,
                },
                Object {
                    size: 256 * 64,
                    modifier: 0,
                },
            ],
            layers: vec![
                Layer {
                    format: R8,
                    planes: vec![Plane {
                        object: 0,
                        offset: 0,
                        pitch: 256,
                    }],
                },
                Layer {
                    format: GR88,
                    planes: vec![Plane {
                        object: 1,
                        offset: 0,
                        pitch: 256,
                    }],
                },
            ],
            color: Color::compatibility_default(128),
        }
    }
    #[test]
    fn validates_two_objects_and_rejects_truncated_or_stale_frames() {
        let mut frame = sample();
        assert!(frame.validate(2, 3).is_ok());
        assert!(frame.validate(1, 3).is_err());
        assert!(frame.validate(2, 4).is_err());
        frame.objects[1].size -= 1;
        assert!(frame.validate(2, 3).is_err());
    }
    #[test]
    fn rejects_overflow_bad_index_hdr_and_unreferenced_fds() {
        for invalid in 0..4 {
            let mut frame = sample();
            match invalid {
                0 => frame.layers[1].planes[0].offset = u64::MAX,
                1 => frame.layers[1].planes[0].object = 4,
                2 => frame.color.transfer = 16,
                _ => frame.objects.push(Object {
                    size: 1,
                    modifier: 0,
                }),
            }
            assert!(frame.validate(frame.objects.len(), 3).is_err());
        }
    }
    #[test]
    fn missing_vui_policy_is_explicit() {
        assert_eq!(Color::compatibility_default(576).matrix, Matrix::Bt601);
        assert_eq!(Color::compatibility_default(1440).matrix, Matrix::Bt709);
        assert_eq!(
            Color::compatibility_default(1440).source,
            ColorSource::CompatibilityDefault
        );
    }
}
