//! Reads the two bundled PCM WAV clicks into a format block and sample bytes for `waveOut`.

#[derive(Clone, Debug, PartialEq)]
pub struct Wav {
    pub format_tag: u16,
    pub channels: u16,
    pub sample_rate: u32,
    pub byte_rate: u32,
    pub block_align: u16,
    pub bits_per_sample: u16,
    pub data: Vec<u8>,
}

/// Parses a RIFF/WAVE file. Only uncompressed PCM is accepted.
pub fn parse(bytes: &[u8]) -> Option<Wav> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let u16_at = |o: usize| Some(u16::from_le_bytes(bytes.get(o..o + 2)?.try_into().ok()?));
    let u32_at = |o: usize| Some(u32::from_le_bytes(bytes.get(o..o + 4)?.try_into().ok()?));
    let mut pos = 12;
    let mut fmt: Option<(u16, u16, u32, u32, u16, u16)> = None;
    let mut data: Option<Vec<u8>> = None;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32_at(pos + 4)? as usize;
        let body = pos + 8;
        let end = body.checked_add(size)?.min(bytes.len());
        if id == b"fmt " && size >= 16 {
            fmt = Some((u16_at(body)?, u16_at(body + 2)?, u32_at(body + 4)?, u32_at(body + 8)?, u16_at(body + 12)?, u16_at(body + 14)?));
        } else if id == b"data" {
            data = Some(bytes[body..end].to_vec());
        }
        // Chunks are padded to an even size.
        pos = body + size + (size & 1);
    }
    let (format_tag, channels, sample_rate, byte_rate, block_align, bits_per_sample) = fmt?;
    if format_tag != 1 || channels == 0 || block_align == 0 {
        return None;
    }
    let mut data = data?;
    data.truncate(data.len() - data.len() % block_align as usize);
    Some(Wav { format_tag, channels, sample_rate, byte_rate, block_align, bits_per_sample, data })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_bundled_clicks() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets/sounds");
        for name in ["open_click.wav", "seal_click.wav"] {
            let w = parse(&std::fs::read(dir.join(name)).unwrap()).unwrap();
            assert_eq!(w.format_tag, 1);
            assert_eq!(w.sample_rate, 44_100);
            assert_eq!(w.channels, 1);
            assert_eq!(w.bits_per_sample, 16);
            assert!(!w.data.is_empty());
        }
    }

    #[test]
    fn rejects_other_files() {
        assert!(parse(b"not a wav").is_none());
        assert!(parse(b"RIFF\0\0\0\0WAVE").is_none());
    }
}
