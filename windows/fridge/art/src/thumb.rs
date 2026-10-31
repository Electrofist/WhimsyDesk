//! Reading pictures: PNG decode (premultiplied), JPEG decode with EXIF orientation, and the
//! photo magnet thumbnail (longest side at most 480 px, PNG).

use crate::pixel::resize;
use crate::Image;

/// Straight-alpha RGBA, top row first.
pub struct Straight {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

pub fn premultiply(data: &mut [u8]) {
    for p in data.chunks_exact_mut(4) {
        let a = p[3] as u32;
        if a == 255 {
            continue;
        }
        for c in &mut p[..3] {
            *c = ((*c as u32 * a + 127) / 255) as u8;
        }
    }
}

pub fn unpremultiply(data: &mut [u8]) {
    for p in data.chunks_exact_mut(4) {
        let a = p[3] as u32;
        if a == 255 || a == 0 {
            continue;
        }
        for c in &mut p[..3] {
            *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
        }
    }
}

/// Any PNG as straight RGBA8.
pub fn decode_png_straight(bytes: &[u8]) -> Option<Straight> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let (w, h) = (info.width as usize, info.height as usize);
    let src = &buf[..info.buffer_size()];
    let mut data = Vec::with_capacity(w * h * 4);
    match info.color_type {
        png::ColorType::Rgba => data.extend_from_slice(src),
        png::ColorType::Rgb => {
            for p in src.chunks_exact(3) {
                data.extend_from_slice(&[p[0], p[1], p[2], 255]);
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for p in src.chunks_exact(2) {
                data.extend_from_slice(&[p[0], p[0], p[0], p[1]]);
            }
        }
        png::ColorType::Grayscale => {
            for &g in src {
                data.extend_from_slice(&[g, g, g, 255]);
            }
        }
        png::ColorType::Indexed => return None,
    }
    if data.len() != w * h * 4 {
        return None;
    }
    Some(Straight { w, h, data })
}

pub fn decode_png(bytes: &[u8]) -> Option<Image> {
    let mut s = decode_png_straight(bytes)?;
    premultiply(&mut s.data);
    Some(Image { width: s.w as u32, height: s.h as u32, data: s.data })
}

/// A JPEG as straight RGBA8, decoded at a reduced size when it is much larger than `max_side`,
/// with its EXIF orientation applied.
pub fn decode_jpeg(bytes: &[u8], max_side: usize) -> Option<Straight> {
    let mut dec = jpeg_decoder::Decoder::new(std::io::Cursor::new(bytes));
    dec.read_info().ok()?;
    let info = dec.info()?;
    let (w0, h0) = (info.width as usize, info.height as usize);
    if w0 == 0 || h0 == 0 {
        return None;
    }
    if w0.max(h0) > max_side * 2 {
        // DCT scaling picks a size at least this large.
        let k = max_side as f64 / w0.max(h0) as f64;
        let _ = dec.scale(((w0 as f64 * k).ceil() as u16).max(1), ((h0 as f64 * k).ceil() as u16).max(1));
    }
    let pixels = dec.decode().ok()?;
    let info = dec.info()?;
    let (w, h) = (info.width as usize, info.height as usize);
    let mut data = Vec::with_capacity(w * h * 4);
    match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => {
            for p in pixels.chunks_exact(3) {
                data.extend_from_slice(&[p[0], p[1], p[2], 255]);
            }
        }
        jpeg_decoder::PixelFormat::L8 => {
            for &g in &pixels {
                data.extend_from_slice(&[g, g, g, 255]);
            }
        }
        jpeg_decoder::PixelFormat::L16 => {
            for p in pixels.chunks_exact(2) {
                data.extend_from_slice(&[p[0], p[0], p[0], 255]);
            }
        }
        jpeg_decoder::PixelFormat::CMYK32 => {
            // Adobe CMYK JPEGs are stored inverted.
            for p in pixels.chunks_exact(4) {
                let k = p[3] as u32;
                let f = |c: u8| ((c as u32 * k) / 255) as u8;
                data.extend_from_slice(&[f(p[0]), f(p[1]), f(p[2]), 255]);
            }
        }
    }
    if data.len() != w * h * 4 {
        return None;
    }
    let orientation = dec.exif_data().and_then(exif_orientation).unwrap_or(1);
    Some(orient(Straight { w, h, data }, orientation))
}

/// The orientation tag (1...8) from raw EXIF data starting at the TIFF header.
pub fn exif_orientation(tiff: &[u8]) -> Option<u16> {
    if tiff.len() < 8 {
        return None;
    }
    let le = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let u16_at = |o: usize| -> Option<u16> {
        let b = tiff.get(o..o + 2)?;
        Some(if le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) })
    };
    let u32_at = |o: usize| -> Option<u32> {
        let b = tiff.get(o..o + 4)?;
        Some(if le { u32::from_le_bytes([b[0], b[1], b[2], b[3]]) } else { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) })
    };
    let ifd = u32_at(4)? as usize;
    let count = u16_at(ifd)? as usize;
    for i in 0..count {
        let e = ifd + 2 + i * 12;
        if u16_at(e)? == 0x0112 {
            let v = u16_at(e + 8)?;
            return if (1..=8).contains(&v) { Some(v) } else { None };
        }
    }
    None
}

/// Applies an EXIF orientation so the picture stands upright.
pub fn orient(img: Straight, o: u16) -> Straight {
    if o <= 1 || o > 8 {
        return img;
    }
    let (w, h) = (img.w, img.h);
    let swap = o >= 5;
    let (nw, nh) = if swap { (h, w) } else { (w, h) };
    let mut out = vec![0u8; nw * nh * 4];
    for y in 0..nh {
        for x in 0..nw {
            // Source pixel for output (x, y).
            let (sx, sy) = match o {
                2 => (w - 1 - x, y),
                3 => (w - 1 - x, h - 1 - y),
                4 => (x, h - 1 - y),
                5 => (y, x),
                6 => (y, h - 1 - x),
                7 => (w - 1 - y, h - 1 - x),
                8 => (w - 1 - y, x),
                _ => (x, y),
            };
            let s = (sy * w + sx) * 4;
            let d = (y * nw + x) * 4;
            out[d..d + 4].copy_from_slice(&img.data[s..s + 4]);
        }
    }
    Straight { w: nw, h: nh, data: out }
}

pub const THUMB_MAX: usize = 480;

/// PNG bytes of a thumbnail no larger than 480 px on its longest side, or None if the file is
/// not a PNG or JPEG this crate can read.
pub fn thumbnail(bytes: &[u8]) -> Option<Vec<u8>> {
    let img = if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        decode_png_straight(bytes)?
    } else if bytes.starts_with(&[0xFF, 0xD8]) {
        decode_jpeg(bytes, THUMB_MAX)?
    } else {
        return None;
    };
    let longest = img.w.max(img.h);
    let (w, h) = if longest > THUMB_MAX {
        let k = THUMB_MAX as f64 / longest as f64;
        (((img.w as f64 * k).round() as usize).max(1), ((img.h as f64 * k).round() as usize).max(1))
    } else {
        (img.w, img.h)
    };
    let mut data = img.data;
    if (w, h) != (img.w, img.h) {
        premultiply(&mut data);
        data = resize(img.w, img.h, &data, w, h);
        unpremultiply(&mut data);
    }
    encode_png(w, h, &data)
}

pub fn encode_png(w: usize, h: usize, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w as u32, h as u32);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orientation_six_rotates_clockwise() {
        // 2 x 1: red, green. Orientation 6 means the stored image must turn 90° clockwise.
        let img = Straight { w: 2, h: 1, data: vec![255, 0, 0, 255, 0, 255, 0, 255] };
        let out = orient(img, 6);
        assert_eq!((out.w, out.h), (1, 2));
        assert_eq!(&out.data[0..4], &[255, 0, 0, 255]);
        assert_eq!(&out.data[4..8], &[0, 255, 0, 255]);
    }

    #[test]
    fn exif_orientation_is_read() {
        // Little endian TIFF header, one IFD entry: orientation = 6.
        let mut t = b"II*\0".to_vec();
        t.extend_from_slice(&8u32.to_le_bytes());
        t.extend_from_slice(&1u16.to_le_bytes());
        t.extend_from_slice(&0x0112u16.to_le_bytes());
        t.extend_from_slice(&3u16.to_le_bytes());
        t.extend_from_slice(&1u32.to_le_bytes());
        t.extend_from_slice(&6u16.to_le_bytes());
        t.extend_from_slice(&[0, 0]);
        assert_eq!(exif_orientation(&t), Some(6));
    }

    #[test]
    fn big_png_is_shrunk() {
        let data = vec![128u8; 1000 * 500 * 4];
        let png = encode_png(1000, 500, &data).unwrap();
        let thumb = thumbnail(&png).unwrap();
        let s = decode_png_straight(&thumb).unwrap();
        assert_eq!((s.w, s.h), (480, 240));
    }
}
