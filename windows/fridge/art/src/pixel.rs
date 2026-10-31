//! Pixel work the renderer does by hand: premultiplied blending, bilinear sampling, the
//! perspective (homography) texture mapper, affine blits and a Gaussian blur.
//!
//! `Bitmap` pixels are premultiplied BGRA, top row first, the same layout as the window frame.

/// Premultiplied BGRA bitmap, top row first.
#[derive(Clone, Debug, Default)]
pub struct Bitmap {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

impl Bitmap {
    pub fn new(w: usize, h: usize) -> Bitmap {
        Bitmap { w, h, data: vec![0; w * h * 4] }
    }

    /// From premultiplied RGBA (tiny-skia, `Image`).
    pub fn from_rgba(w: usize, h: usize, mut data: Vec<u8>) -> Bitmap {
        swap_rb(&mut data);
        Bitmap { w, h, data }
    }

    pub fn from_pixmap(pm: tiny_skia::Pixmap) -> Bitmap {
        let (w, h) = (pm.width() as usize, pm.height() as usize);
        Bitmap::from_rgba(w, h, pm.take())
    }
}

/// Swaps red and blue in place (RGBA <-> BGRA).
pub fn swap_rb(data: &mut [u8]) {
    for p in data.chunks_exact_mut(4) {
        p.swap(0, 2);
    }
}

/// A bitmap placed in the frame at a whole pixel offset.
#[derive(Clone, Debug, Default)]
pub struct Sprite {
    pub bm: Bitmap,
    pub x: i32,
    pub y: i32,
}

#[inline(always)]
fn div255(v: u32) -> u32 {
    (v + 128 + ((v + 128) >> 8)) >> 8
}

/// Source-over of `src` onto `dst` at (dx, dy) with an opacity.
pub fn blit_over(dst: &mut Bitmap, src: &Bitmap, dx: i32, dy: i32, opacity: f32) {
    if opacity <= 0.0 {
        return;
    }
    let op = (opacity.min(1.0) * 255.0 + 0.5) as u32;
    let x0 = dx.max(0);
    let y0 = dy.max(0);
    let x1 = (dx + src.w as i32).min(dst.w as i32);
    let y1 = (dy + src.h as i32).min(dst.h as i32);
    if x0 >= x1 || y0 >= y1 {
        return;
    }
    let n = (x1 - x0) as usize;
    for y in y0..y1 {
        let s_off = (((y - dy) as usize) * src.w + (x0 - dx) as usize) * 4;
        let d_off = ((y as usize) * dst.w + x0 as usize) * 4;
        let s = &src.data[s_off..s_off + n * 4];
        let d = &mut dst.data[d_off..d_off + n * 4];
        if op >= 255 {
            for (sp, dp) in s.chunks_exact(4).zip(d.chunks_exact_mut(4)) {
                let sa = sp[3] as u32;
                if sa == 0 {
                    continue;
                }
                if sa == 255 {
                    dp.copy_from_slice(sp);
                    continue;
                }
                let inv = 255 - sa;
                for k in 0..4 {
                    dp[k] = (sp[k] as u32 + div255(dp[k] as u32 * inv)) as u8;
                }
            }
        } else {
            for (sp, dp) in s.chunks_exact(4).zip(d.chunks_exact_mut(4)) {
                if sp[3] == 0 {
                    continue;
                }
                let sa = div255(sp[3] as u32 * op);
                let inv = 255 - sa;
                for k in 0..4 {
                    dp[k] = (div255(sp[k] as u32 * op) + div255(dp[k] as u32 * inv)).min(255) as u8;
                }
            }
        }
    }
}

/// Copies `src` into `dst` at (dx, dy), replacing what is there.
pub fn blit_copy(dst: &mut Bitmap, src: &Bitmap, dx: i32, dy: i32) {
    let x0 = dx.max(0);
    let y0 = dy.max(0);
    let x1 = (dx + src.w as i32).min(dst.w as i32);
    let y1 = (dy + src.h as i32).min(dst.h as i32);
    if x0 >= x1 || y0 >= y1 {
        return;
    }
    let n = (x1 - x0) as usize * 4;
    for y in y0..y1 {
        let s_off = (((y - dy) as usize) * src.w + (x0 - dx) as usize) * 4;
        let d_off = ((y as usize) * dst.w + x0 as usize) * 4;
        dst.data[d_off..d_off + n].copy_from_slice(&src.data[s_off..s_off + n]);
    }
}

/// Bilinear sample at continuous pixel coordinates (pixel centres at +0.5), transparent outside.
#[inline(always)]
pub fn sample(bm: &Bitmap, u: f32, v: f32) -> [f32; 4] {
    let x = u - 0.5;
    let y = v - 0.5;
    let fx = x.floor();
    let fy = y.floor();
    let tx = x - fx;
    let ty = y - fy;
    let ix = fx as i32;
    let iy = fy as i32;
    let w = bm.w as i32;
    let h = bm.h as i32;
    let mut out = [0f32; 4];
    if ix >= 0 && iy >= 0 && ix + 1 < w && iy + 1 < h {
        let i0 = ((iy * w + ix) * 4) as usize;
        let i1 = i0 + (w as usize) * 4;
        let d = &bm.data;
        let w00 = (1.0 - tx) * (1.0 - ty);
        let w10 = tx * (1.0 - ty);
        let w01 = (1.0 - tx) * ty;
        let w11 = tx * ty;
        for k in 0..4 {
            out[k] = d[i0 + k] as f32 * w00 + d[i0 + 4 + k] as f32 * w10 + d[i1 + k] as f32 * w01 + d[i1 + 4 + k] as f32 * w11;
        }
        return out;
    }
    if ix < -1 || iy < -1 || ix >= w || iy >= h {
        return out;
    }
    let taps = [(ix, iy, (1.0 - tx) * (1.0 - ty)), (ix + 1, iy, tx * (1.0 - ty)), (ix, iy + 1, (1.0 - tx) * ty), (ix + 1, iy + 1, tx * ty)];
    for (px, py, wt) in taps {
        if px >= 0 && py >= 0 && px < w && py < h {
            let i = ((py * w + px) * 4) as usize;
            for k in 0..4 {
                out[k] += bm.data[i + k] as f32 * wt;
            }
        }
    }
    out
}

/// Blends a premultiplied float colour (0..255) over a destination pixel.
#[inline(always)]
fn over_f(dp: &mut [u8], c: [f32; 4]) {
    let a = c[3];
    if a <= 0.0 {
        return;
    }
    let inv = 1.0 - a / 255.0;
    for k in 0..4 {
        dp[k] = (c[k] + dp[k] as f32 * inv + 0.5).min(255.0) as u8;
    }
}

/// Horizontal mip chain: each level halves the width only. Doors shrink sideways as they turn.
#[derive(Clone, Debug, Default)]
pub struct Mips {
    pub levels: Vec<Bitmap>,
}

impl Mips {
    pub fn new(base: Bitmap, max_levels: usize) -> Mips {
        let mut levels = vec![base];
        while levels.len() < max_levels {
            let prev = levels.last().unwrap();
            if prev.w < 4 {
                break;
            }
            let w = prev.w.div_ceil(2);
            let mut next = Bitmap::new(w, prev.h);
            for y in 0..prev.h {
                let row = &prev.data[y * prev.w * 4..(y + 1) * prev.w * 4];
                let out = &mut next.data[y * w * 4..(y + 1) * w * 4];
                for x in 0..w {
                    let a = 2 * x;
                    let b = (2 * x + 1).min(prev.w - 1);
                    for k in 0..4 {
                        out[x * 4 + k] = ((row[a * 4 + k] as u32 + row[b * 4 + k] as u32 + 1) / 2) as u8;
                    }
                }
            }
            levels.push(next);
        }
        Mips { levels }
    }

    pub fn base(&self) -> &Bitmap {
        &self.levels[0]
    }
}

/// 3 x 3 projective matrix, row major, applied to column vectors (x, y, 1).
pub type Mat3 = [f64; 9];

pub fn mat_mul(a: &Mat3, b: &Mat3) -> Mat3 {
    let mut m = [0.0; 9];
    for r in 0..3 {
        for c in 0..3 {
            m[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
        }
    }
    m
}

pub fn mat_inverse(m: &Mat3) -> Option<Mat3> {
    let a = m;
    let c00 = a[4] * a[8] - a[5] * a[7];
    let c01 = a[5] * a[6] - a[3] * a[8];
    let c02 = a[3] * a[7] - a[4] * a[6];
    let det = a[0] * c00 + a[1] * c01 + a[2] * c02;
    if det.abs() < 1e-12 {
        return None;
    }
    let inv = 1.0 / det;
    Some([
        c00 * inv,
        (a[2] * a[7] - a[1] * a[8]) * inv,
        (a[1] * a[5] - a[2] * a[4]) * inv,
        c01 * inv,
        (a[0] * a[8] - a[2] * a[6]) * inv,
        (a[2] * a[3] - a[0] * a[5]) * inv,
        c02 * inv,
        (a[1] * a[6] - a[0] * a[7]) * inv,
        (a[0] * a[4] - a[1] * a[3]) * inv,
    ])
}

pub fn mat_apply(m: &Mat3, x: f64, y: f64) -> (f64, f64) {
    let w = m[6] * x + m[7] * y + m[8];
    ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)
}

/// The projective map taking the unit square corners (0,0), (1,0), (1,1), (0,1) to `q`.
pub fn square_to_quad(q: &[(f64, f64); 4]) -> Mat3 {
    let (x0, y0) = q[0];
    let (x1, y1) = q[1];
    let (x2, y2) = q[2];
    let (x3, y3) = q[3];
    let sx = x0 - x1 + x2 - x3;
    let sy = y0 - y1 + y2 - y3;
    if sx.abs() < 1e-12 && sy.abs() < 1e-12 {
        return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0.0, 0.0, 1.0];
    }
    let dx1 = x1 - x2;
    let dx2 = x3 - x2;
    let dy1 = y1 - y2;
    let dy2 = y3 - y2;
    let den = dx1 * dy2 - dx2 * dy1;
    let g = (sx * dy2 - dx2 * sy) / den;
    let h = (dx1 * sy - sx * dy1) / den;
    [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1.0]
}

/// Maps frame pixels to texture pixels for a texture of `tw x th` pixels whose corners
/// (top left, top right, bottom right, bottom left) land on `quad` in the frame.
pub fn texture_map(quad: &[(f64, f64); 4], tw: f64, th: f64) -> Option<Mat3> {
    let to_frame = square_to_quad(quad);
    let to_unit = mat_inverse(&to_frame)?;
    Some(mat_mul(&[tw, 0.0, 0.0, 0.0, th, 0.0, 0.0, 0.0, 1.0], &to_unit))
}

/// Signed area of a polygon in frame pixels (y down): positive when it runs clockwise on screen.
pub fn signed_area(p: &[(f64, f64)]) -> f64 {
    let mut a = 0.0;
    for i in 0..p.len() {
        let (x0, y0) = p[i];
        let (x1, y1) = p[(i + 1) % p.len()];
        a += x0 * y1 - x1 * y0;
    }
    a * 0.5
}

/// Options for drawing one textured quad.
pub struct Warp<'a> {
    pub tex: &'a Mips,
    /// Frame pixel -> base texture pixel.
    pub map: Mat3,
    /// Where the quad is, frame pixels.
    pub quad: [(f64, f64); 4],
    /// Multiplies colour (not alpha): 1 - shade.
    pub tint: f32,
    /// Extra convex clip (frame pixels, clockwise on screen), for faces cut by the cabinet plane.
    pub clip: Option<Vec<(f64, f64)>>,
}

/// Draws a texture through a homography onto `dst`, bilinear, premultiplied, source-over.
/// Only pixels in the quad's bounding box are visited. The texture border gives the edges
/// their antialiasing.
pub fn warp(dst: &mut Bitmap, wp: &Warp) {
    let pts: &[(f64, f64)] = match &wp.clip {
        Some(c) => c,
        None => &wp.quad,
    };
    if pts.len() < 3 {
        return;
    }
    let mut minx = f64::MAX;
    let mut miny = f64::MAX;
    let mut maxx = f64::MIN;
    let mut maxy = f64::MIN;
    for &(x, y) in pts {
        minx = minx.min(x);
        miny = miny.min(y);
        maxx = maxx.max(x);
        maxy = maxy.max(y);
    }
    let x0 = (minx.floor() as i64 - 1).max(0) as usize;
    let y0 = (miny.floor() as i64 - 1).max(0) as usize;
    let x1 = ((maxx.ceil() as i64 + 1).min(dst.w as i64)).max(0) as usize;
    let y1 = ((maxy.ceil() as i64 + 1).min(dst.h as i64)).max(0) as usize;
    if x0 >= x1 || y0 >= y1 {
        return;
    }

    // Horizontal compression at the centre picks the mip level.
    let cx = (minx + maxx) * 0.5;
    let cy = (miny + maxy) * 0.5;
    let (ua, _) = mat_apply(&wp.map, cx, cy);
    let (ub, _) = mat_apply(&wp.map, cx + 1.0, cy);
    let (uc, _) = mat_apply(&wp.map, cx, cy + 1.0);
    let squeeze = (ub - ua).abs().max((uc - ua).abs() * 0.5);
    let mut level = 0usize;
    let mut s = squeeze;
    while s >= 2.0 && level + 1 < wp.tex.levels.len() {
        s *= 0.5;
        level += 1;
    }
    let tex = &wp.tex.levels[level];
    let ufac = tex.w as f64 / wp.tex.levels[0].w as f64;

    // Edge equations for the optional clip polygon (inside >= 0, in pixels).
    let edges: Vec<(f64, f64, f64)> = match &wp.clip {
        Some(c) => {
            let sign = if signed_area(c) >= 0.0 { 1.0 } else { -1.0 };
            (0..c.len())
                .map(|i| {
                    let (ax, ay) = c[i];
                    let (bx, by) = c[(i + 1) % c.len()];
                    let (nx, ny) = (-(by - ay) * sign, (bx - ax) * sign);
                    let len = (nx * nx + ny * ny).sqrt().max(1e-9);
                    (nx / len, ny / len, -(nx * ax + ny * ay) / len)
                })
                .collect()
        }
        None => Vec::new(),
    };
    // Edges point inward for clockwise polygons with y down; flip sign so inside is positive.
    let m = wp.map;
    let tint = wp.tint.clamp(0.0, 1.0);
    let tw = tex.w as f32 + 1.0;
    let th = tex.h as f32 + 1.0;
    for y in y0..y1 {
        let py = y as f64 + 0.5;
        let fx0 = x0 as f64 + 0.5;
        let mut nu = (m[0] * fx0 + m[1] * py + m[2]) * ufac;
        let mut nv = m[3] * fx0 + m[4] * py + m[5];
        let mut nw = m[6] * fx0 + m[7] * py + m[8];
        let du = m[0] * ufac;
        let dv = m[3];
        let dw = m[6];
        let row = y * dst.w * 4;
        for x in x0..x1 {
            if nw > 1e-9 {
                let iw = 1.0 / nw;
                let u = (nu * iw) as f32;
                let v = (nv * iw) as f32;
                if u > -1.0 && v > -1.0 && u < tw && v < th {
                    let mut c = sample(tex, u, v);
                    if c[3] > 0.0 {
                        if !edges.is_empty() {
                            let px = x as f64 + 0.5;
                            let mut cov = 1.0f64;
                            for &(a, b, d) in &edges {
                                let dist = a * px + b * py + d;
                                cov = cov.min((dist + 0.5).clamp(0.0, 1.0));
                            }
                            if cov < 1.0 {
                                let k = cov as f32;
                                for ch in c.iter_mut() {
                                    *ch *= k;
                                }
                            }
                        }
                        if tint < 1.0 {
                            c[0] *= tint;
                            c[1] *= tint;
                            c[2] *= tint;
                        }
                        let i = row + x * 4;
                        over_f(&mut dst.data[i..i + 4], c);
                    }
                }
            }
            nu += du;
            nv += dv;
            nw += dw;
        }
    }
}

/// Draws `src` with an affine map onto `dst`. `inv` maps a destination pixel centre to a source
/// pixel position: (u, v) = (a·x + b·y + c, d·x + e·y + f). `bounds` limits the visited area.
pub fn blit_affine(dst: &mut Bitmap, src: &Bitmap, inv: [f64; 6], bounds: (f64, f64, f64, f64), opacity: f32) {
    if opacity <= 0.0 {
        return;
    }
    let x0 = (bounds.0.floor() as i64 - 1).max(0) as usize;
    let y0 = (bounds.1.floor() as i64 - 1).max(0) as usize;
    let x1 = ((bounds.2.ceil() as i64 + 1).min(dst.w as i64)).max(0) as usize;
    let y1 = ((bounds.3.ceil() as i64 + 1).min(dst.h as i64)).max(0) as usize;
    let op = opacity.min(1.0);
    let tw = src.w as f32 + 1.0;
    let th = src.h as f32 + 1.0;
    for y in y0..y1 {
        let py = y as f64 + 0.5;
        let row = y * dst.w * 4;
        for x in x0..x1 {
            let px = x as f64 + 0.5;
            let u = (inv[0] * px + inv[1] * py + inv[2]) as f32;
            let v = (inv[3] * px + inv[4] * py + inv[5]) as f32;
            if u <= -1.0 || v <= -1.0 || u >= tw || v >= th {
                continue;
            }
            let mut c = sample(src, u, v);
            if c[3] <= 0.0 {
                continue;
            }
            if op < 1.0 {
                for ch in c.iter_mut() {
                    *ch *= op;
                }
            }
            let i = row + x * 4;
            over_f(&mut dst.data[i..i + 4], c);
        }
    }
}

/// Affine map helpers: forward 2 x 3 (x' = a x + b y + c, y' = d x + e y + f).
pub fn affine_invert(m: [f64; 6]) -> Option<[f64; 6]> {
    let det = m[0] * m[4] - m[1] * m[3];
    if det.abs() < 1e-12 {
        return None;
    }
    let id = 1.0 / det;
    let a = m[4] * id;
    let b = -m[1] * id;
    let d = -m[3] * id;
    let e = m[0] * id;
    Some([a, b, -(a * m[2] + b * m[5]), d, e, -(d * m[2] + e * m[5])])
}

pub fn affine_apply(m: &[f64; 6], x: f64, y: f64) -> (f64, f64) {
    (m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5])
}

/// Bounding box of the four corners of a `w x h` rectangle under an affine map.
pub fn affine_bounds(m: &[f64; 6], w: f64, h: f64) -> (f64, f64, f64, f64) {
    let pts = [affine_apply(m, 0.0, 0.0), affine_apply(m, w, 0.0), affine_apply(m, w, h), affine_apply(m, 0.0, h)];
    let mut b = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for (x, y) in pts {
        b.0 = b.0.min(x);
        b.1 = b.1.min(y);
        b.2 = b.2.max(x);
        b.3 = b.3.max(y);
    }
    b
}

/// Gaussian blur of a single channel, approximated by three box blurs. Zero outside.
pub fn blur_plane(plane: &mut [f32], w: usize, h: usize, sigma: f32) {
    if sigma < 0.3 || w == 0 || h == 0 {
        return;
    }
    let boxes = box_sizes(sigma, 3);
    let mut tmp = vec![0f32; plane.len()];
    for r in boxes {
        box_h(plane, &mut tmp, w, h, r);
        box_v(&tmp, plane, w, h, r);
    }
}

fn box_sizes(sigma: f32, n: usize) -> Vec<usize> {
    let ideal = ((12.0 * sigma * sigma / n as f32) + 1.0).sqrt();
    let mut wl = ideal.floor() as i32;
    if wl % 2 == 0 {
        wl -= 1;
    }
    let wu = wl + 2;
    let m_ideal = (12.0 * sigma * sigma - (n as i32 * wl * wl) as f32 - (4 * n as i32 * wl) as f32 - 3.0 * n as f32) / (-4.0 * wl as f32 - 4.0);
    let m = m_ideal.round() as i32;
    (0..n as i32).map(|i| (((if i < m { wl } else { wu }) - 1) / 2).max(0) as usize).collect()
}

fn box_h(src: &[f32], dst: &mut [f32], w: usize, h: usize, r: usize) {
    let norm = 1.0 / (2 * r + 1) as f32;
    for y in 0..h {
        let row = &src[y * w..(y + 1) * w];
        let out = &mut dst[y * w..(y + 1) * w];
        let mut acc = 0f32;
        for x in 0..=r.min(w - 1) {
            acc += row[x];
        }
        for x in 0..w {
            out[x] = acc * norm;
            let add = x + r + 1;
            if add < w {
                acc += row[add];
            }
            if x >= r {
                acc -= row[x - r];
            }
        }
    }
}

fn box_v(src: &[f32], dst: &mut [f32], w: usize, h: usize, r: usize) {
    let norm = 1.0 / (2 * r + 1) as f32;
    let mut acc = vec![0f32; w];
    for y in 0..=r.min(h - 1) {
        for x in 0..w {
            acc[x] += src[y * w + x];
        }
    }
    for y in 0..h {
        for x in 0..w {
            dst[y * w + x] = acc[x] * norm;
        }
        let add = y + r + 1;
        if add < h {
            for x in 0..w {
                acc[x] += src[add * w + x];
            }
        }
        if y >= r {
            let sub = y - r;
            for x in 0..w {
                acc[x] -= src[sub * w + x];
            }
        }
    }
}

/// Resamples a premultiplied RGBA image to `w x h` pixels: area average when shrinking,
/// bilinear when growing. Channel order is kept.
pub fn resize(src_w: usize, src_h: usize, src: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 4];
    if src_w == 0 || src_h == 0 || w == 0 || h == 0 {
        return out;
    }
    let sx = src_w as f64 / w as f64;
    let sy = src_h as f64 / h as f64;
    if sx <= 1.0 && sy <= 1.0 {
        let bm = Bitmap { w: src_w, h: src_h, data: src.to_vec() };
        for y in 0..h {
            for x in 0..w {
                let u = ((x as f64 + 0.5) * sx).clamp(0.5, src_w as f64 - 0.5) as f32;
                let v = ((y as f64 + 0.5) * sy).clamp(0.5, src_h as f64 - 0.5) as f32;
                let c = sample(&bm, u, v);
                let i = (y * w + x) * 4;
                for k in 0..4 {
                    out[i + k] = (c[k] + 0.5).min(255.0) as u8;
                }
            }
        }
        return out;
    }
    // Box filter with fractional coverage.
    for y in 0..h {
        let fy0 = y as f64 * sy;
        let fy1 = ((y + 1) as f64 * sy).min(src_h as f64);
        for x in 0..w {
            let fx0 = x as f64 * sx;
            let fx1 = ((x + 1) as f64 * sx).min(src_w as f64);
            let mut acc = [0f64; 4];
            let mut total = 0.0;
            let mut yy = fy0.floor() as usize;
            while (yy as f64) < fy1 && yy < src_h {
                let wy = ((yy + 1) as f64).min(fy1) - (yy as f64).max(fy0);
                let mut xx = fx0.floor() as usize;
                while (xx as f64) < fx1 && xx < src_w {
                    let wx = ((xx + 1) as f64).min(fx1) - (xx as f64).max(fx0);
                    let wgt = wx * wy;
                    let i = (yy * src_w + xx) * 4;
                    for k in 0..4 {
                        acc[k] += src[i + k] as f64 * wgt;
                    }
                    total += wgt;
                    xx += 1;
                }
                yy += 1;
            }
            let i = (y * w + x) * 4;
            for k in 0..4 {
                out[i + k] = (acc[k] / total.max(1e-9) + 0.5).min(255.0) as u8;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn homography_maps_corners_exactly() {
        let quad = [(10.5, 20.0), (200.0, 35.0), (180.0, 400.0), (15.0, 380.0)];
        let (tw, th) = (544.0, 730.0);
        let m = texture_map(&quad, tw, th).unwrap();
        let expect = [(0.0, 0.0), (tw, 0.0), (tw, th), (0.0, th)];
        for (q, e) in quad.iter().zip(expect.iter()) {
            let (u, v) = mat_apply(&m, q.0, q.1);
            assert!((u - e.0).abs() < 1e-6 && (v - e.1).abs() < 1e-6, "{q:?} -> ({u}, {v}) want {e:?}");
        }
    }

    #[test]
    fn blur_keeps_mass() {
        let (w, h) = (64, 64);
        let mut p = vec![0f32; w * h];
        p[32 * w + 32] = 100.0;
        blur_plane(&mut p, w, h, 3.0);
        let sum: f32 = p.iter().sum();
        assert!((sum - 100.0).abs() < 0.5, "{sum}");
        assert!(p[32 * w + 32] < 10.0);
    }

    #[test]
    fn blit_over_opaque_replaces() {
        let mut dst = Bitmap::new(4, 4);
        let mut src = Bitmap::new(2, 2);
        src.data.iter_mut().for_each(|v| *v = 255);
        blit_over(&mut dst, &src, 1, 1, 1.0);
        assert_eq!(dst.data[(1 * 4 + 1) * 4 + 3], 255);
        assert_eq!(dst.data[3], 0);
    }
}
