//! Small premultiplied-BGRA pictures (item icons, label text) and a layer to draw them on. No
//! Windows calls: icons and text masks come in from the shell as plain bytes, so this is tested
//! on any OS.

/// A picture with a "logical" rectangle inside it: the part that sits where the item is. The rest
/// is padding that holds a soft shadow.
#[derive(Clone, Debug, PartialEq)]
pub struct Sprite {
    pub w: usize,
    pub h: usize,
    /// BGRA, premultiplied, `w * h * 4` bytes.
    pub data: Vec<u8>,
    /// Where the logical rectangle starts inside the picture, and its size.
    pub ox: usize,
    pub oy: usize,
    pub lw: usize,
    pub lh: usize,
}

impl Sprite {
    pub fn from_bgra(w: usize, h: usize, data: Vec<u8>) -> Sprite {
        assert_eq!(data.len(), w * h * 4);
        Sprite {
            w,
            h,
            data,
            ox: 0,
            oy: 0,
            lw: w,
            lh: h,
        }
    }

    /// From an RGBA premultiplied picture (what `IShellItemImageFactory` gives after conversion).
    pub fn from_rgba(w: usize, h: usize, rgba: &[u8]) -> Sprite {
        let mut data = rgba.to_vec();
        for px in data.chunks_exact_mut(4) {
            px.swap(0, 2);
        }
        Sprite::from_bgra(w, h, data)
    }

    /// Coloured text from an 8-bit coverage mask: `rgb` at `alpha` where the mask is set.
    pub fn from_mask(w: usize, h: usize, mask: &[u8], rgb: [u8; 3], alpha: f32) -> Sprite {
        assert_eq!(mask.len(), w * h);
        let mut data = vec![0u8; w * h * 4];
        for (px, &m) in data.chunks_exact_mut(4).zip(mask) {
            let a = m as f32 / 255.0 * alpha;
            px[0] = (rgb[2] as f32 * a).round() as u8;
            px[1] = (rgb[1] as f32 * a).round() as u8;
            px[2] = (rgb[0] as f32 * a).round() as u8;
            px[3] = (a * 255.0).round() as u8;
        }
        Sprite::from_bgra(w, h, data)
    }

    /// Bilinear resize (icons are asked for at the right size, so this is the rare case).
    pub fn resized(&self, w: usize, h: usize) -> Sprite {
        if (w, h) == (self.w, self.h) || w == 0 || h == 0 {
            return self.clone();
        }
        let mut data = vec![0u8; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let sx = (x as f64 + 0.5) * self.w as f64 / w as f64 - 0.5;
                let sy = (y as f64 + 0.5) * self.h as f64 / h as f64 - 0.5;
                // Stay inside the picture so the edges do not fade out.
                let px = self.sample(
                    sx.clamp(0.0, self.w as f64 - 1.0),
                    sy.clamp(0.0, self.h as f64 - 1.0),
                );
                for k in 0..4 {
                    data[(y * w + x) * 4 + k] = px[k].round().clamp(0.0, 255.0) as u8;
                }
            }
        }
        Sprite::from_bgra(w, h, data)
    }

    /// Bilinear sample at pixel-centre coordinates; outside the picture is transparent.
    fn sample(&self, x: f64, y: f64) -> [f32; 4] {
        let (x0, y0) = (x.floor(), y.floor());
        let (fx, fy) = ((x - x0) as f32, (y - y0) as f32);
        let get = |ix: i64, iy: i64| -> [f32; 4] {
            if ix < 0 || iy < 0 || ix >= self.w as i64 || iy >= self.h as i64 {
                return [0.0; 4];
            }
            let i = (iy as usize * self.w + ix as usize) * 4;
            [
                self.data[i] as f32,
                self.data[i + 1] as f32,
                self.data[i + 2] as f32,
                self.data[i + 3] as f32,
            ]
        };
        let (a, b, c, d) = (
            get(x0 as i64, y0 as i64),
            get(x0 as i64 + 1, y0 as i64),
            get(x0 as i64, y0 as i64 + 1),
            get(x0 as i64 + 1, y0 as i64 + 1),
        );
        let mut out = [0.0; 4];
        for k in 0..4 {
            let top = a[k] * (1.0 - fx) + b[k] * fx;
            let bottom = c[k] * (1.0 - fx) + d[k] * fx;
            out[k] = top * (1.0 - fy) + bottom * fy;
        }
        out
    }

    /// This sprite over a blurred black copy of its own shape, moved by `(dx, dy)` pixels. The
    /// result is padded so the shadow fits; the logical rectangle stays the original's.
    /// `sigma` is the blur's standard deviation in pixels.
    pub fn with_shadow(&self, sigma: f64, dx: f64, dy: f64, alpha: f32) -> Sprite {
        let pad = (sigma * 3.0).ceil() as usize + dx.abs().max(dy.abs()).ceil() as usize + 1;
        let (w, h) = (self.w + pad * 2, self.h + pad * 2);
        let mut a = vec![0f32; w * h];
        let (sx, sy) = (dx.round() as i64, dy.round() as i64);
        for y in 0..self.h {
            for x in 0..self.w {
                let v = self.data[(y * self.w + x) * 4 + 3] as f32 / 255.0;
                let tx = (x + pad) as i64 + sx;
                let ty = (y + pad) as i64 + sy;
                a[ty as usize * w + tx as usize] = v;
            }
        }
        box_blur_3(&mut a, w, h, sigma);
        let mut data = vec![0u8; w * h * 4];
        for (i, px) in data.chunks_exact_mut(4).enumerate() {
            px[3] = (a[i] * alpha * 255.0).round().min(255.0) as u8; // black, premultiplied
        }
        // The sprite itself on top.
        for y in 0..self.h {
            for x in 0..self.w {
                let s = &self.data[(y * self.w + x) * 4..][..4];
                let d = &mut data[((y + pad) * w + x + pad) * 4..][..4];
                over_px(d, s, 1.0);
            }
        }
        Sprite {
            w,
            h,
            data,
            ox: self.ox + pad,
            oy: self.oy + pad,
            lw: self.lw,
            lh: self.lh,
        }
    }
}

/// Three box blurs approximate a gaussian of the given sigma.
fn box_blur_3(a: &mut [f32], w: usize, h: usize, sigma: f64) {
    if sigma <= 0.0 {
        return;
    }
    // Box width for 3 passes: sqrt(12 sigma^2 / 3 + 1).
    let width = ((4.0 * sigma * sigma + 1.0).sqrt().round() as usize).max(1);
    let r = width / 2;
    let mut tmp = vec![0f32; a.len()];
    for _ in 0..3 {
        blur_axis(a, &mut tmp, w, h, r, true);
        blur_axis(&tmp, a, w, h, r, false);
    }
}

fn blur_axis(src: &[f32], dst: &mut [f32], w: usize, h: usize, r: usize, horizontal: bool) {
    let (len, lines) = if horizontal { (w, h) } else { (h, w) };
    let at = |line: usize, i: usize| {
        if horizontal {
            line * w + i
        } else {
            i * w + line
        }
    };
    let scale = 1.0 / (2 * r + 1) as f32;
    for line in 0..lines {
        let mut sum = 0.0;
        for i in 0..=r.min(len - 1) {
            sum += src[at(line, i)];
        }
        for i in 0..len {
            dst[at(line, i)] = sum * scale;
            let add = i + r + 1;
            if add < len {
                sum += src[at(line, add)];
            }
            if i >= r {
                sum -= src[at(line, i - r)];
            }
        }
    }
}

/// `dst = src * k + dst * (1 - src.alpha * k)` for one premultiplied BGRA pixel.
fn over_px(dst: &mut [u8], src: &[u8], k: f32) {
    let sa = src[3] as f32 * k / 255.0;
    if sa <= 0.0 {
        return;
    }
    for c in 0..4 {
        let v = src[c] as f32 * k + dst[c] as f32 * (1.0 - sa);
        dst[c] = v.round().clamp(0.0, 255.0) as u8;
    }
}

/// A full-size BGRA premultiplied picture that sprites are drawn onto.
pub struct Layer {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

impl Layer {
    pub fn new(w: usize, h: usize) -> Layer {
        Layer {
            w,
            h,
            data: vec![0; w * h * 4],
        }
    }

    /// Draws `s` so its logical rectangle has its top-left at `(left, top)`, turned by `angle`
    /// radians (clockwise on screen) about the logical rectangle's centre, at `alpha` opacity.
    pub fn draw(&mut self, s: &Sprite, left: f64, top: f64, angle: f64, alpha: f32) {
        let (cx, cy) = (left + s.lw as f64 / 2.0, top + s.lh as f64 / 2.0);
        let (sin, cos) = angle.sin_cos();
        // The sprite's corners, turned, give the area to visit.
        let (hx, hy) = (
            s.lw as f64 / 2.0 + s.ox.max(s.w - s.ox - s.lw) as f64,
            s.lh as f64 / 2.0 + s.oy.max(s.h - s.oy - s.lh) as f64,
        );
        let ex = hx * cos.abs() + hy * sin.abs() + 1.0;
        let ey = hx * sin.abs() + hy * cos.abs() + 1.0;
        let (x0, x1) = (
            ((cx - ex).floor().max(0.0)) as usize,
            ((cx + ex).ceil().min(self.w as f64)) as usize,
        );
        let (y0, y1) = (
            ((cy - ey).floor().max(0.0)) as usize,
            ((cy + ey).ceil().min(self.h as f64)) as usize,
        );
        for y in y0..y1 {
            for x in x0..x1 {
                let (rx, ry) = (x as f64 + 0.5 - cx, y as f64 + 0.5 - cy);
                // Undo the turn to find the spot in the sprite.
                let (ux, uy) = (rx * cos + ry * sin, -rx * sin + ry * cos);
                let px = ux + s.lw as f64 / 2.0 + s.ox as f64 - 0.5;
                let py = uy + s.lh as f64 / 2.0 + s.oy as f64 - 0.5;
                let c = s.sample(px, py);
                if c[3] <= 0.0 {
                    continue;
                }
                let src = [
                    c[0].round() as u8,
                    c[1].round() as u8,
                    c[2].round() as u8,
                    c[3].round() as u8,
                ];
                over_px(&mut self.data[(y * self.w + x) * 4..][..4], &src, alpha);
            }
        }
    }

    /// A soft dark oval: full strength in the middle, fading to nothing at the edge.
    pub fn contact_shadow(&mut self, x: f64, y: f64, w: f64, h: f64, alpha: f32) {
        let (cx, cy, rx, ry) = (x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0);
        let (x0, x1) = (
            (x.floor().max(0.0)) as usize,
            ((x + w).ceil().min(self.w as f64)) as usize,
        );
        let (y0, y1) = (
            (y.floor().max(0.0)) as usize,
            ((y + h).ceil().min(self.h as f64)) as usize,
        );
        for py in y0..y1 {
            for px in x0..x1 {
                let (dx, dy) = ((px as f64 + 0.5 - cx) / rx, (py as f64 + 0.5 - cy) / ry);
                let d = (dx * dx + dy * dy).sqrt();
                if d >= 1.0 {
                    continue;
                }
                let a = (1.0 - d) as f32 * alpha;
                let black = [0u8, 0, 0, (a * 255.0).round() as u8];
                over_px(&mut self.data[(py * self.w + px) * 4..][..4], &black, 1.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: usize, h: usize, bgra: [u8; 4]) -> Sprite {
        Sprite::from_bgra(w, h, bgra.iter().copied().cycle().take(w * h * 4).collect())
    }

    #[test]
    fn rgba_converts_to_bgra() {
        let s = Sprite::from_rgba(1, 1, &[10, 20, 30, 255]);
        assert_eq!(s.data, vec![30, 20, 10, 255]);
    }

    #[test]
    fn mask_text_is_premultiplied() {
        let s = Sprite::from_mask(2, 1, &[255, 128], [255, 255, 255], 0.5);
        assert_eq!(s.data[3], 128);
        assert_eq!(
            s.data[0], 128,
            "white at half alpha is 128 in every channel"
        );
        assert!(s.data[7] > 0 && s.data[7] < 128, "half coverage is fainter");
    }

    #[test]
    fn resize_keeps_a_flat_colour() {
        let s = solid(4, 4, [10, 20, 30, 255]).resized(9, 7);
        assert_eq!((s.w, s.h), (9, 7));
        assert!(s.data.chunks(4).all(|p| p == [10, 20, 30, 255]));
    }

    #[test]
    fn shadow_pads_and_darkens_around_the_shape() {
        let s = solid(10, 10, [255, 255, 255, 255]).with_shadow(2.0, 0.0, 2.0, 0.5);
        assert!(s.w > 10 && s.h > 10);
        assert_eq!((s.lw, s.lh), (10, 10));
        assert_eq!(
            s.data[((s.oy + 5) * s.w + s.ox + 5) * 4 + 3],
            255,
            "the shape stays on top"
        );
        // Just below the shape: dark, partly transparent, no colour.
        let i = ((s.oy + 11) * s.w + s.ox + 5) * 4;
        assert!(
            s.data[i + 3] > 20 && s.data[i + 3] < 130,
            "{}",
            s.data[i + 3]
        );
        assert_eq!(&s.data[i..i + 3], &[0, 0, 0]);
        // The shadow is weaker above than below (it is pushed down).
        let above = s.data[((s.oy - 2) * s.w + s.ox + 5) * 4 + 3];
        let below = s.data[((s.oy + 12) * s.w + s.ox + 5) * 4 + 3];
        assert!(below > above);
    }

    #[test]
    fn drawing_without_a_turn_copies_pixels_in_place() {
        let mut l = Layer::new(20, 20);
        l.draw(&solid(4, 4, [1, 2, 3, 255]), 5.0, 6.0, 0.0, 1.0);
        let at = |x: usize, y: usize| l.data[(y * 20 + x) * 4..][..4].to_vec();
        assert_eq!(at(5, 6), vec![1, 2, 3, 255]);
        assert_eq!(at(8, 9), vec![1, 2, 3, 255]);
        assert_eq!(at(4, 6)[3], 0);
        assert_eq!(at(9, 9)[3], 0);
    }

    #[test]
    fn alpha_fades_a_sprite() {
        let mut l = Layer::new(8, 8);
        l.draw(&solid(4, 4, [200, 200, 200, 255]), 2.0, 2.0, 0.0, 0.3);
        let a = l.data[(3 * 8 + 3) * 4 + 3];
        assert!((a as i32 - 77).abs() <= 1, "{a}");
    }

    #[test]
    fn a_quarter_turn_swaps_width_and_height() {
        let mut l = Layer::new(30, 30);
        l.draw(
            &solid(10, 4, [9, 9, 9, 255]),
            10.0,
            13.0,
            std::f64::consts::FRAC_PI_2,
            1.0,
        );
        let alpha = |x: usize, y: usize| l.data[(y * 30 + x) * 4 + 3];
        assert_eq!(alpha(15, 10), 255, "now tall");
        assert_eq!(alpha(15, 18), 255);
        assert_eq!(alpha(11, 15), 0, "no longer wide");
        assert_eq!(alpha(19, 15), 0);
    }

    #[test]
    fn a_small_turn_stays_around_the_same_centre() {
        let mut l = Layer::new(40, 40);
        l.draw(&solid(20, 20, [9, 9, 9, 255]), 10.0, 10.0, 0.06, 1.0);
        assert_eq!(l.data[(20 * 40 + 20) * 4 + 3], 255);
        assert_eq!(l.data[(5 * 40 + 5) * 4 + 3], 0);
    }

    #[test]
    fn drawing_near_the_edge_does_not_overrun() {
        let mut l = Layer::new(10, 10);
        l.draw(
            &solid(8, 8, [9, 9, 9, 255]).with_shadow(2.0, 0.0, 1.0, 0.5),
            -3.0,
            7.0,
            0.3,
            1.0,
        );
        l.draw(&solid(8, 8, [9, 9, 9, 255]), 8.0, -4.0, 0.3, 1.0);
    }

    #[test]
    fn contact_shadow_is_darkest_in_the_middle() {
        let mut l = Layer::new(40, 20);
        l.contact_shadow(4.0, 4.0, 32.0, 10.0, 0.45);
        let a = |x: usize, y: usize| l.data[(y * 40 + x) * 4 + 3];
        assert!(a(20, 9) > 100);
        assert!(a(20, 9) > a(8, 9));
        assert_eq!(a(2, 9), 0);
    }
}
