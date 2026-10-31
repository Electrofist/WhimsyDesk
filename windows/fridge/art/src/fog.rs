//! The fog plumes (`FogPlayer.swift`): two plumes from the same 40 frames, each 1.7 s, the
//! floor plume 0.18 s later and mirrored, with a faint cool shadow under the vapour.

use crate::pixel::{blur_plane, Bitmap};
use crate::Image;
use fridge_core::geometry::{Rect, FOG_DURATION, FOG_FRAME, FOG_FRAME_COUNT, FOG_SPILL_FRAME};

pub const FLOOR_DELAY: f64 = 0.18;
/// Shadow colour (0.10, 0.20, 0.30) as BGR bytes and opacity 0.22 in 1/256ths.
const SHADOW_BGR: [u32; 3] = [77, 51, 26];
const SHADOW_OPACITY_256: u32 = 56;
/// CALayer shadowRadius 9 pt; treated as the Gaussian sigma.
const SHADOW_RADIUS: f64 = 9.0;
const SHADOW_OFFSET_Y: f64 = -5.0;

pub struct Plume {
    pub rect: Rect,
    pub frame: usize,
    pub flip: bool,
    /// 0 spill, 1 floor (the shadow blur depends on the plume size).
    pub id: usize,
}

/// Which plumes show at `elapsed` seconds, and which frame each shows.
pub fn plumes(elapsed: f64, lite: bool) -> Vec<Plume> {
    let mut out = Vec::new();
    let pick = |t: f64| -> Option<usize> {
        if t >= FOG_DURATION {
            return None;
        }
        // Before its start the plume holds frame 0 (the animation fills backwards).
        let t = t.max(0.0);
        if lite {
            let n = FOG_FRAME_COUNT / 2;
            Some(((t / FOG_DURATION * n as f64) as usize).min(n - 1) * 2)
        } else {
            Some(((t / FOG_DURATION * FOG_FRAME_COUNT as f64) as usize).min(FOG_FRAME_COUNT - 1))
        }
    };
    if elapsed < 0.0 {
        return out;
    }
    if let Some(f) = pick(elapsed) {
        out.push(Plume { rect: FOG_SPILL_FRAME, frame: f, flip: false, id: 0 });
    }
    if let Some(f) = pick(elapsed - FLOOR_DELAY) {
        out.push(Plume { rect: FOG_FRAME, frame: f, flip: true, id: 1 });
    }
    out
}

/// Per row, the first and last column with any alpha (first > last when the row is empty).
pub type Spans = Vec<(i32, i32)>;

pub fn alpha_spans(w: usize, h: usize, alpha: impl Fn(usize) -> u8) -> Spans {
    (0..h)
        .map(|y| {
            let mut lo = i32::MAX;
            let mut hi = i32::MIN;
            for x in 0..w {
                if alpha(y * w + x) > 1 {
                    lo = lo.min(x as i32);
                    hi = x as i32;
                }
            }
            (lo, hi)
        })
        .collect()
}

pub fn image_spans(img: &Image) -> Spans {
    alpha_spans(img.width as usize, img.height as usize, |i| img.data[i * 4 + 3])
}

/// Blurred alpha of a 1x fog frame with a margin, for the shadow.
pub struct ShadowMask {
    pub w: usize,
    pub h: usize,
    pub margin: usize,
    pub data: Vec<u8>,
    pub spans: Spans,
}

pub fn shadow_mask(img: &Image, plume_w: f64) -> ShadowMask {
    let sigma = (SHADOW_RADIUS * img.width as f64 / plume_w) as f32;
    let margin = (sigma * 3.0).ceil() as usize + 1;
    let (w, h) = (img.width as usize + margin * 2, img.height as usize + margin * 2);
    let mut plane = vec![0f32; w * h];
    for y in 0..img.height as usize {
        for x in 0..img.width as usize {
            plane[(y + margin) * w + x + margin] = img.data[(y * img.width as usize + x) * 4 + 3] as f32;
        }
    }
    blur_plane(&mut plane, w, h, sigma);
    let data: Vec<u8> = plane.iter().map(|v| (v + 0.5).min(255.0) as u8).collect();
    let spans = alpha_spans(w, h, |i| data[i]);
    ShadowMask { w, h, margin, data, spans }
}

/// Bilinear sample of a premultiplied RGBA image, returned as BGRA.
#[inline(always)]
fn sample_rgba(img: &Image, u: f32, v: f32) -> [f32; 4] {
    let x = u - 0.5;
    let y = v - 0.5;
    let fx = x.floor();
    let fy = y.floor();
    let (ix, iy) = (fx as i32, fy as i32);
    let (w, h) = (img.width as i32, img.height as i32);
    let (tx, ty) = (x - fx, y - fy);
    let d = &img.data;
    if ix >= 0 && iy >= 0 && ix + 1 < w && iy + 1 < h {
        let i0 = ((iy * w + ix) * 4) as usize;
        let i1 = i0 + w as usize * 4;
        let (w00, w10, w01, w11) = ((1.0 - tx) * (1.0 - ty), tx * (1.0 - ty), (1.0 - tx) * ty, tx * ty);
        let f = |k: usize| d[i0 + k] as f32 * w00 + d[i0 + 4 + k] as f32 * w10 + d[i1 + k] as f32 * w01 + d[i1 + 4 + k] as f32 * w11;
        return [f(2), f(1), f(0), f(3)];
    }
    let mut out = [0f32; 4];
    let taps = [(ix, iy, (1.0 - tx) * (1.0 - ty)), (ix + 1, iy, tx * (1.0 - ty)), (ix, iy + 1, (1.0 - tx) * ty), (ix + 1, iy + 1, tx * ty)];
    for (px, py, wt) in taps {
        if px >= 0 && py >= 0 && px < w && py < h && wt > 0.0 {
            let i = ((py * w + px) * 4) as usize;
            out[0] += d[i + 2] as f32 * wt;
            out[1] += d[i + 1] as f32 * wt;
            out[2] += d[i] as f32 * wt;
            out[3] += d[i + 3] as f32 * wt;
        }
    }
    out
}

/// Union of the spans of rows `r` and `r + 1` (out of range rows count as empty).
fn rows_span(spans: &Spans, r: i32) -> (i32, i32) {
    let mut lo = i32::MAX;
    let mut hi = i32::MIN;
    for k in [r, r + 1] {
        if k >= 0 && (k as usize) < spans.len() {
            let (a, b) = spans[k as usize];
            if a <= b {
                lo = lo.min(a);
                hi = hi.max(b);
            }
        }
    }
    (lo, hi)
}

/// Draws one plume over the frame (view coordinates, not risen with the scene). Only the parts
/// of each row that hold vapour or shadow are visited.
pub fn draw_plume(dst: &mut Bitmap, img: &Image, spans: &Spans, shadow: Option<&ShadowMask>, plume: &Plume, scale: f64) {
    let fh = dst.h as f64;
    let r = plume.rect;
    let x0 = r.x * scale;
    let x1 = (r.x + r.w) * scale;
    let y0 = fh - (r.y + r.h) * scale;
    let y1 = fh - r.y * scale;
    let (iw, ih) = (img.width as f64, img.height as f64);
    let ku = iw / (x1 - x0);
    let kv = ih / (y1 - y0);
    // The shadow sits 5 pt lower: each pixel shows the vapour's alpha from above it.
    let shadow_dv = -SHADOW_OFFSET_Y * scale * kv;
    let ms = shadow.map(|m| (m.w - 2 * m.margin) as f64 / iw).unwrap_or(1.0);
    let margin_px = shadow.map(|m| (m.margin as f64 / ms / ku).ceil() + SHADOW_OFFSET_Y.abs() * scale).unwrap_or(0.0) + 2.0;
    let py0 = ((y0 - margin_px).floor().max(0.0)) as usize;
    let py1 = ((y1 + margin_px).ceil().min(dst.h as f64)).max(0.0) as usize;
    // Image u (unflipped) to frame x.
    let x_of_u = |u: f64| -> f64 {
        let u = if plume.flip { iw - u } else { u };
        x0 + u / ku - 0.5
    };
    let cx0 = ((x0 - margin_px).floor().max(0.0)) as usize;
    let cx1 = ((x1 + margin_px).ceil().min(dst.w as f64)).max(cx0 as f64) as usize;
    let mut cols = Columns { start: cx0, img: Vec::with_capacity(cx1 - cx0), mask: Vec::with_capacity(cx1 - cx0) };
    for x in cx0..cx1 {
        let mut u = ((x as f64 + 0.5) - x0) * ku;
        if plume.flip {
            u = iw - u;
        }
        let ux = u - 0.5;
        let ui = ux.floor() as i32;
        cols.img.push((ui, ((ux - ui as f64) * 256.0) as u32));
        let mu = match shadow {
            Some(m) => u * ms + m.margin as f64 - 0.5,
            None => 0.0,
        };
        let mi = mu.floor() as i32;
        cols.mask.push((mi, ((mu - mi as f64) * 256.0) as u32));
    }
    for y in py0..py1 {
        let v = ((y as f64 + 0.5) - y0) * kv;
        // Columns to visit for this row.
        let mut lo = f64::MAX;
        let mut hi = f64::MIN;
        let (a, b) = rows_span(spans, (v - 0.5).floor() as i32);
        if a <= b {
            for u in [a as f64 - 1.0, b as f64 + 2.0] {
                let x = x_of_u(u);
                lo = lo.min(x);
                hi = hi.max(x);
            }
        }
        if let Some(m) = shadow {
            let mv = (v - shadow_dv) * ms + m.margin as f64;
            let (a, b) = rows_span(&m.spans, (mv - 0.5).floor() as i32);
            if a <= b {
                for mu in [a as f64 - 1.0, b as f64 + 2.0] {
                    let x = x_of_u((mu - m.margin as f64) / ms);
                    lo = lo.min(x);
                    hi = hi.max(x);
                }
            }
        }
        if lo > hi {
            continue;
        }
        let px0 = ((lo.floor() - 1.0).max(0.0) as usize).max(cx0);
        let px1 = (((hi.ceil() + 2.0).min(dst.w as f64)).max(0.0) as usize).min(cx1);
        let row = y * dst.w * 4;
        // Vapour row taps and weight (8 bit).
        let vy = v - 0.5;
        let vi = vy.floor() as i32;
        let vw = ((vy - vi as f64) * 256.0) as u32;
        let (mvi, mvw) = match shadow {
            Some(m) => {
                let my = (v - shadow_dv) * ms + m.margin as f64 - 0.5;
                let i = my.floor() as i32;
                (i, ((my - i as f64) * 256.0) as u32)
            }
            None => (0, 0),
        };
        let (w, h) = (img.width as i32, img.height as i32);
        for x in px0..px1 {
            let ci = x - cols.start;
            let i = row + x * 4;
            if let Some(m) = shadow {
                let (mui, muw) = cols.mask[ci];
                if mui >= 0 && mvi >= 0 && mui + 1 < m.w as i32 && mvi + 1 < m.h as i32 {
                    let o = mvi as usize * m.w + mui as usize;
                    let d = &m.data;
                    let top = d[o] as u32 * (256 - muw) + d[o + 1] as u32 * muw;
                    let bot = d[o + m.w] as u32 * (256 - muw) + d[o + m.w + 1] as u32 * muw;
                    let a = (top * (256 - mvw) + bot * mvw) >> 16; // 0..255
                    if a > 0 {
                        let k = a * SHADOW_OPACITY_256 >> 8; // 0..56
                        let inv = 255 - k;
                        let dp = &mut dst.data[i..i + 4];
                        dp[0] = ((SHADOW_BGR[0] * k + dp[0] as u32 * inv) / 255) as u8;
                        dp[1] = ((SHADOW_BGR[1] * k + dp[1] as u32 * inv) / 255) as u8;
                        dp[2] = ((SHADOW_BGR[2] * k + dp[2] as u32 * inv) / 255) as u8;
                        dp[3] = ((255 * k + dp[3] as u32 * inv) / 255) as u8;
                    }
                }
            }
            let (ui, uw) = cols.img[ci];
            let c: [u32; 4] = if ui >= 0 && vi >= 0 && ui + 1 < w && vi + 1 < h {
                let o0 = ((vi * w + ui) * 4) as usize;
                let o1 = o0 + w as usize * 4;
                let d = &img.data;
                if d[o0 + 3] | d[o0 + 7] | d[o1 + 3] | d[o1 + 7] == 0 {
                    continue;
                }
                let f = |k: usize| {
                    let top = d[o0 + k] as u32 * (256 - uw) + d[o0 + 4 + k] as u32 * uw;
                    let bot = d[o1 + k] as u32 * (256 - uw) + d[o1 + 4 + k] as u32 * uw;
                    (top * (256 - vw) + bot * vw) >> 16
                };
                [f(2), f(1), f(0), f(3)]
            } else if ui >= -1 && vi >= -1 && ui < w && vi < h {
                let u = ((x as f64 + 0.5) - x0) * ku;
                let u = if plume.flip { iw - u } else { u };
                let c = sample_rgba(img, u as f32, v as f32);
                [c[0] as u32, c[1] as u32, c[2] as u32, c[3] as u32]
            } else {
                continue;
            };
            if c[3] == 0 {
                continue;
            }
            let inv = 255 - c[3];
            let dp = &mut dst.data[i..i + 4];
            for k in 0..4 {
                dp[k] = (c[k] + (dp[k] as u32 * inv + 127) / 255).min(255) as u8;
            }
        }
    }
}

/// Per column of the plume's box: image tap and weight, and shadow mask tap and weight.
struct Columns {
    start: usize,
    img: Vec<(i32, u32)>,
    mask: Vec<(i32, u32)>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timing() {
        let p = plumes(0.0, false);
        assert_eq!(p.len(), 2);
        assert_eq!(p[0].frame, 0);
        assert_eq!(p[1].frame, 0);
        assert_eq!(plumes(0.85, false)[0].frame, 20);
        let p = plumes(1.75, false);
        assert_eq!(p.len(), 1);
        assert!(p[0].flip);
        assert!(plumes(1.9, false).is_empty());
        assert_eq!(plumes(0.1, true)[0].frame % 2, 0);
    }
}
