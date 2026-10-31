//! Stretches a finished frame while the fridge is being resized, so the drag stays smooth. The
//! art is re-rendered crisply at the new size on release (as on the Mac).

/// Bilinear resample of premultiplied 4-byte pixels (any channel order), top row first.
pub fn resample(src: &[u8], sw: u32, sh: u32, dst: &mut [u8], dw: u32, dh: u32) {
    let (sw, sh, dw, dh) = (sw as usize, sh as usize, dw as usize, dh as usize);
    if sw == 0 || sh == 0 || dw == 0 || dh == 0 || src.len() < sw * sh * 4 || dst.len() < dw * dh * 4 {
        return;
    }
    if sw == dw && sh == dh {
        dst[..dw * dh * 4].copy_from_slice(&src[..sw * sh * 4]);
        return;
    }
    let sx = sw as f32 / dw as f32;
    let sy = sh as f32 / dh as f32;
    for y in 0..dh {
        let fy = ((y as f32 + 0.5) * sy - 0.5).clamp(0.0, (sh - 1) as f32);
        let y0 = fy as usize;
        let y1 = (y0 + 1).min(sh - 1);
        let wy = fy - y0 as f32;
        for x in 0..dw {
            let fx = ((x as f32 + 0.5) * sx - 0.5).clamp(0.0, (sw - 1) as f32);
            let x0 = fx as usize;
            let x1 = (x0 + 1).min(sw - 1);
            let wx = fx - x0 as f32;
            let o = (y * dw + x) * 4;
            for c in 0..4 {
                let p = |xx: usize, yy: usize| src[(yy * sw + xx) * 4 + c] as f32;
                let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * wx;
                let bottom = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * wx;
                dst[o + c] = (top + (bottom - top) * wy + 0.5).clamp(0.0, 255.0) as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_size_is_a_copy() {
        let src: Vec<u8> = (0..16u8).collect();
        let mut dst = vec![0; 16];
        resample(&src, 2, 2, &mut dst, 2, 2);
        assert_eq!(src, dst);
    }

    #[test]
    fn flat_colour_stays_flat_and_premultiplied() {
        let src = [10u8, 20, 30, 40].repeat(4 * 4);
        let mut dst = vec![0; 7 * 5 * 4];
        resample(&src, 4, 4, &mut dst, 7, 5);
        for px in dst.chunks(4) {
            assert_eq!(px, [10, 20, 30, 40]);
        }
    }
}
