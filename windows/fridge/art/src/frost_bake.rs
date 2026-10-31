//! Shelf-ready item bitmaps and the frost / freezer burn bake (`FrostRenderer.swift`).

use crate::canvas::*;
use crate::pixel::{blur_plane, resize};
use crate::Image;
use fridge_core::{FrostState, SeededRandom};

/// Room round the icon, as a fraction of its size, so the icy edge glow fits.
pub const PAD_FRACTION: f64 = 0.07;

/// The icon (or a plain page when there is none) drawn into a square of `points + 2·pad`
/// at `scale`. Returns (side in pixels, premultiplied RGBA).
pub fn rasterize(icon: Option<&Image>, points: f64, scale: f32) -> (usize, Vec<u8>) {
    let pad = points * PAD_FRACTION;
    let total = points + pad * 2.0;
    let side = ((total * scale as f64).round() as usize).max(1);
    let icon_px = ((points * scale as f64).round() as usize).clamp(1, side);
    let off = (side - icon_px) / 2;
    let mut out = vec![0u8; side * side * 4];
    let src: Vec<u8> = match icon {
        Some(img) if img.width > 0 && img.height > 0 => resize(img.width as usize, img.height as usize, &img.data, icon_px, icon_px),
        _ => plain_document(icon_px),
    };
    for y in 0..icon_px {
        let d = ((y + off) * side + off) * 4;
        out[d..d + icon_px * 4].copy_from_slice(&src[y * icon_px * 4..(y + 1) * icon_px * 4]);
    }
    (side, out)
}

/// A generic page for files without an icon.
fn plain_document(px: usize) -> Vec<u8> {
    let s = px as f32 / 64.0;
    let (mut pm, tf) = canvas(64.0, 64.0, s);
    let page = polygon(&[(12.0, 2.0), (52.0, 2.0), (52.0, 48.0), (38.0, 62.0), (12.0, 62.0)]);
    fill_linear(&mut pm, &page, &[(0.0, hex(0xE9EEF2, 1.0)), (1.0, hex(0xFFFFFF, 1.0))], (0.0, 2.0), (0.0, 62.0), tf, None);
    stroke(&mut pm, &page, rgba(0.35, 0.42, 0.48, 0.55), 1.2, tf, None);
    let fold = polygon(&[(38.0, 62.0), (38.0, 48.0), (52.0, 48.0)]);
    fill(&mut pm, &fold, hex(0xD4DCE2, 1.0), tf, None);
    stroke(&mut pm, &fold, rgba(0.35, 0.42, 0.48, 0.55), 1.0, tf, None);
    for (i, y) in [40.0, 33.0, 26.0, 19.0, 12.0].iter().enumerate() {
        let x1 = if i == 0 { 32.0 } else { 44.0 };
        stroke(&mut pm, &line((19.0, *y), (x1, *y)), rgba(0.45, 0.52, 0.58, 0.45), 2.0, tf, None);
    }
    let mut data = pm.take();
    if data.len() != px * px * 4 {
        data.resize(px * px * 4, 0);
    }
    data
}

/// Bakes frost and burn into a premultiplied RGBA square (top row first). Returns None when the
/// item is fresh and the bitmap stays untouched.
pub fn bake(base: &[u8], w: usize, h: usize, state: &FrostState, seed: u64) -> Option<Vec<u8>> {
    if state.frost < 0.03 && state.burn < 0.02 {
        return None;
    }
    let mut px = base.to_vec();
    let desaturate = state.burn as f32 * 0.85;
    let ice_tint = state.burn as f32 * 0.16;
    let frost = state.frost as f32;

    for y in 0..h {
        let ty = y as f32 / ((h.max(2) - 1) as f32);
        let haze = frost * 0.50 * (1.0 - ty * 1.35).max(0.0).powf(1.7);
        for x in 0..w {
            let i = (y * w + x) * 4;
            let a = px[i + 3] as f32;
            if a == 0.0 {
                continue;
            }
            let (mut r, mut g, mut b) = (px[i] as f32, px[i + 1] as f32, px[i + 2] as f32);
            if desaturate > 0.0 {
                let luma = 0.299 * r + 0.587 * g + 0.114 * b;
                r += (luma - r) * desaturate;
                g += (luma - g) * desaturate;
                b += (luma - b) * desaturate;
            }
            if ice_tint > 0.0 {
                r += (0.78 * a - r) * ice_tint;
                g += (0.91 * a - g) * ice_tint;
                b += (1.00 * a - b) * ice_tint;
            }
            if haze > 0.0 {
                r += (a - r) * haze;
                g += (a - g) * haze;
                b += (a - b) * haze;
            }
            px[i] = r.clamp(0.0, 255.0) as u8;
            px[i + 1] = g.clamp(0.0, 255.0) as u8;
            px[i + 2] = b.clamp(0.0, 255.0) as u8;
        }
    }

    // Rime specks, biased toward the top rows.
    let mut rng = SeededRandom::new(seed);
    let specks = (state.frost * (w * h) as f64 * 0.014) as usize;
    for _ in 0..specks {
        let x = rng.range(0.0, w as f64) as usize;
        let u = rng.unit();
        let y = (u * u * h as f64) as usize;
        let i = (y.min(h - 1) * w + x.min(w - 1)) * 4;
        let a = px[i + 3] as f32;
        if a < 200.0 {
            continue;
        }
        let k = rng.range(0.4, 0.9) as f32;
        for c in 0..3 {
            let v = px[i + c] as f32;
            px[i + c] = (v + (a - v) * k).min(255.0) as u8;
        }
    }

    if state.burn < 0.05 {
        return Some(px);
    }

    // Thin icy edge: a pale cyan glow following the silhouette, under the image.
    let mut plane: Vec<f32> = px.chunks_exact(4).map(|p| p[3] as f32 / 255.0).collect();
    blur_plane(&mut plane, w, h, (w as f32 * 0.035) / 2.0);
    let ga = (state.burn * 1.4).min(1.0) as f32;
    let glow = [0.80f32, 0.94, 1.0];
    for (i, k) in plane.iter().enumerate() {
        let s = k * ga;
        if s <= 0.0 {
            continue;
        }
        let o = i * 4;
        let inv = 1.0 - px[o + 3] as f32 / 255.0;
        for c in 0..3 {
            px[o + c] = (px[o + c] as f32 + glow[c] * 255.0 * s * inv + 0.5).min(255.0) as u8;
        }
        px[o + 3] = (px[o + 3] as f32 + 255.0 * s * inv + 0.5).min(255.0) as u8;
    }
    Some(px)
}

#[cfg(test)]
mod tests {
    use super::*;
    use fridge_core::FrostModel;

    fn icon() -> Vec<u8> {
        let mut v = vec![0u8; 32 * 32 * 4];
        for p in v.chunks_exact_mut(4) {
            p.copy_from_slice(&[200, 40, 40, 255]);
        }
        v
    }

    #[test]
    fn fresh_items_are_untouched() {
        let s = FrostModel::state_for_elapsed(60.0);
        assert!(bake(&icon(), 32, 32, &s, 7).is_none());
    }

    #[test]
    fn old_items_get_frost_and_are_deterministic() {
        let s = FrostModel::state_for_elapsed(10.0 * FrostModel::DAY);
        let a = bake(&icon(), 32, 32, &s, 7).unwrap();
        let b = bake(&icon(), 32, 32, &s, 7).unwrap();
        assert_eq!(a, b);
        // Hazier (whiter) at the top than at the bottom.
        assert!(a[1] > a[(31 * 32) * 4 + 1]);
    }
}
