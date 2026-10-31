//! Sticky notes and photo magnets (`NoteArt.swift`).

use crate::canvas::*;
use crate::pixel::resize;
use crate::recipes::CG_SHADOW_PT;
use crate::Image;
use ab_glyph::{Font, FontVec, GlyphId, PxScale, ScaleFont};
use tiny_skia::{Pixmap, Transform};

pub const NOTE_SIZE: f64 = 70.0;
/// Text rect on the note (bottom-left origin), from the insets top 13, left 7, bottom 6, right 7.
pub const TEXT_RECT: (f64, f64, f64, f64) = (7.0, 6.0, 56.0, 51.0);

/// Paper and strip colours: yellow, pink, mint, blue.
pub const PALETTE: [(u32, u32); 4] = [(0xFFE873, 0xF2D649), (0xFFB3C7, 0xF297B0), (0xB8F0C8, 0x96DFAD), (0xB5DDFF, 0x92C8F5)];
pub const MAGNET_COLORS: [u32; 4] = [0xE8453C, 0x2F7DE1, 0x2DB36B, 0xF2A516];

/// The Mac uses Noteworthy Bold 11 pt: 18 pt lines, first baseline 14 pt under the top of the
/// text rect, two lines in the 51 pt rect. Caveat Bold at this size matches its width and weight.
pub const FONT_SIZE: f32 = 14.5;
pub const LINE_HEIGHT: f64 = 18.0;
pub const FIRST_BASELINE: f64 = 14.0;
const INK: (f32, f32, f32, f32) = (0.16, 0.17, 0.22, 0.92);

pub const PHOTO_BORDER: f64 = 4.0;
pub const PHOTO_CHIN: f64 = 11.0;
pub const PHOTO_MAX_SIDE: f64 = 84.0;
pub const MAGNET_RADIUS: f64 = 7.0;

fn wrap_index(i: usize, n: usize) -> usize {
    i % n
}

/// The print's size for a picture of `w x h` pixels, without the magnet headroom.
pub fn photo_print_size(w: u32, h: u32) -> (f64, f64) {
    let aspect = (w as f64 / (h.max(1)) as f64).clamp(0.4, 2.5);
    let inner = if aspect >= 1.0 {
        (PHOTO_MAX_SIDE, (PHOTO_MAX_SIDE / aspect).round())
    } else {
        ((PHOTO_MAX_SIDE * aspect).round(), PHOTO_MAX_SIDE)
    };
    (inner.0 + PHOTO_BORDER * 2.0, inner.1 + PHOTO_BORDER + PHOTO_CHIN)
}

pub fn photo_layer_size(w: u32, h: u32) -> (f64, f64) {
    let p = photo_print_size(w, h);
    (p.0, p.1 + MAGNET_RADIUS)
}

// MARK: Text

pub struct NoteFont {
    font: FontVec,
}

impl NoteFont {
    pub fn new(bytes: &[u8]) -> Option<NoteFont> {
        FontVec::try_from_vec(bytes.to_vec()).ok().map(|font| NoteFont { font })
    }

    fn px_scale(&self, em_px: f32) -> PxScale {
        let upem = self.font.units_per_em().unwrap_or(1000.0);
        PxScale::from(em_px * self.font.height_unscaled() / upem)
    }

    /// Advance width of a string in points.
    pub fn width(&self, s: &str) -> f64 {
        let sf = self.font.as_scaled(self.px_scale(FONT_SIZE));
        let mut w = 0.0f32;
        let mut prev: Option<GlyphId> = None;
        for c in s.chars() {
            let id = sf.glyph_id(c);
            if let Some(p) = prev {
                w += sf.kern(p, id);
            }
            w += sf.h_advance(id);
            prev = Some(id);
        }
        w as f64
    }

    /// Word-wrapped lines for the text rect, the last visible one truncated with an ellipsis.
    pub fn layout(&self, text: &str) -> Vec<String> {
        let max_w = TEXT_RECT.2;
        let visible = ((TEXT_RECT.3 / LINE_HEIGHT).floor() as usize).max(1);
        // Every wrapped line with the byte offset where it starts, so the rest can be re-joined.
        let mut lines: Vec<(String, usize)> = Vec::new();
        let mut offset = 0usize;
        for para in text.split('\n') {
            let mut line = String::new();
            let mut line_start = offset;
            let mut pos = offset;
            for word in split_keep_spaces(para) {
                if !line.is_empty() {
                    let candidate = format!("{line}{word}");
                    if self.width(candidate.trim_end()) <= max_w {
                        line = candidate;
                        pos += word.len();
                        continue;
                    }
                    lines.push((line.trim_end().to_string(), line_start));
                    line = String::new();
                }
                line_start = pos;
                if self.width(word.trim_end()) <= max_w {
                    line = word.to_string();
                } else {
                    // A word longer than the line: break it by characters.
                    let mut char_pos = pos;
                    for c in word.chars() {
                        let next = format!("{line}{c}");
                        if !line.is_empty() && self.width(next.trim_end()) > max_w {
                            lines.push((line.trim_end().to_string(), line_start));
                            line = c.to_string();
                            line_start = char_pos;
                        } else {
                            line = next;
                        }
                        char_pos += c.len_utf8();
                    }
                }
                pos += word.len();
            }
            lines.push((line.trim_end().to_string(), line_start));
            offset += para.len() + 1;
        }
        if lines.len() <= visible {
            return lines.into_iter().map(|l| l.0).collect();
        }
        let mut out: Vec<String> = lines[..visible - 1].iter().map(|l| l.0.clone()).collect();
        let rest_start = lines[visible - 1].1.min(text.len());
        let rest: String = text[rest_start..].split_whitespace().collect::<Vec<_>>().join(" ");
        out.push(self.truncate(&rest, max_w));
        out
    }

    fn truncate(&self, s: &str, max_w: f64) -> String {
        if self.width(s) <= max_w {
            return s.to_string();
        }
        let chars: Vec<char> = s.chars().collect();
        for n in (0..chars.len()).rev() {
            let head: String = chars[..n].iter().collect();
            let candidate = format!("{}\u{2026}", head.trim_end());
            if self.width(&candidate) <= max_w {
                return candidate;
            }
        }
        "\u{2026}".to_string()
    }

    /// Draws the lines into a note pixmap (70 x 70 pt at `scale`).
    fn draw(&self, pm: &mut Pixmap, lines: &[String], scale: f32) {
        let em_px = FONT_SIZE * scale;
        let px = self.px_scale(em_px);
        let sf = self.font.as_scaled(px);
        let (w, h) = (pm.width() as i32, pm.height() as i32);
        let top = TEXT_RECT.1 + TEXT_RECT.3;
        let data = pm.data_mut();
        for (i, line) in lines.iter().enumerate() {
            let baseline_pt = top - FIRST_BASELINE - i as f64 * LINE_HEIGHT;
            let by = ((NOTE_SIZE - baseline_pt) as f32) * scale;
            let mut x = TEXT_RECT.0 as f32 * scale;
            let mut prev: Option<GlyphId> = None;
            for c in line.chars() {
                let id = sf.glyph_id(c);
                if let Some(p) = prev {
                    x += sf.kern(p, id);
                }
                let glyph = id.with_scale_and_position(px, ab_glyph::point(x, by));
                x += sf.h_advance(id);
                prev = Some(id);
                let Some(outlined) = self.font.outline_glyph(glyph) else { continue };
                let b = outlined.px_bounds();
                outlined.draw(|gx, gy, cov| {
                    let xx = b.min.x as i32 + gx as i32;
                    let yy = b.min.y as i32 + gy as i32;
                    if xx < 0 || yy < 0 || xx >= w || yy >= h || cov <= 0.0 {
                        return;
                    }
                    let k = cov.min(1.0) * INK.3;
                    let o = ((yy * w + xx) * 4) as usize;
                    let inv = 1.0 - k;
                    let ink = [INK.0, INK.1, INK.2, 1.0];
                    for ch in 0..4 {
                        let v = ink[ch] * 255.0 * k + data[o + ch] as f32 * inv;
                        data[o + ch] = (v + 0.5).min(255.0) as u8;
                    }
                });
            }
        }
    }
}

/// Splits into words, each keeping its trailing spaces.
fn split_keep_spaces(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b' ' {
            let mut j = i;
            while j < bytes.len() && bytes[j] == b' ' {
                j += 1;
            }
            out.push(&s[start..j]);
            start = j;
            i = j;
        } else {
            i += 1;
        }
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

// MARK: Sticky note

/// A sticky note at `scale`, premultiplied RGBA.
pub fn note(text: &str, color: usize, font: Option<&NoteFont>, scale: f32) -> Pixmap {
    let (paper, strip) = PALETTE[wrap_index(color, PALETTE.len())];
    let s = NOTE_SIZE;
    let (mut pm, tf) = canvas(s, s, scale);
    let all = rect_path(0.0, 0.0, s, s);
    fill_linear(&mut pm, &all, &[(0.0, hex(strip, 1.0)), (0.35, hex(paper, 1.0)), (1.0, hex(paper, 1.0))], (0.0, 0.0), (0.0, s), tf, None);
    fill(&mut pm, &rect_path(0.0, s - 10.0, s, 10.0), hex(strip, 0.55), tf, None);
    fill(&mut pm, &polygon(&[(s - 13.0, 0.0), (s, 0.0), (s, 11.0)]), rgba(1.0, 1.0, 1.0, 0.32), tf, None);
    stroke(&mut pm, &rect_path(0.25, 0.25, s - 0.5, s - 0.5), rgba(0.0, 0.0, 0.0, 0.10), 0.5, tf, None);
    if let Some(font) = font {
        if !text.is_empty() {
            let lines = font.layout(text);
            font.draw(&mut pm, &lines, scale);
        }
    }
    pm
}

// MARK: Photo magnet

/// A photo magnet at `scale`: print, picture, gloss and the round magnet on top.
pub fn photo(image: Option<&Image>, magnet_color: usize, scale: f32) -> Pixmap {
    let (iw, ih) = image.map(|i| (i.width, i.height)).unwrap_or((4, 3));
    let print = photo_print_size(iw, ih);
    let size = photo_layer_size(iw, ih);
    let (mut pm, tf) = canvas(size.0, size.1, scale);

    let paper = rect_path(0.0, 0.0, print.0, print.1);
    fill_linear(&mut pm, &paper, &[(0.0, hex(0xEDEBE6, 1.0)), (1.0, hex(0xFBFAF7, 1.0))], (0.0, 0.0), (0.0, print.1), tf, None);
    stroke(&mut pm, &rect_path(0.25, 0.25, print.0 - 0.5, print.1 - 0.5), rgba(0.0, 0.0, 0.0, 0.14), 0.5, tf, None);

    let win = (PHOTO_BORDER, PHOTO_CHIN, print.0 - PHOTO_BORDER * 2.0, print.1 - PHOTO_BORDER - PHOTO_CHIN);
    let win_path = rect_path(win.0, win.1, win.2, win.3);
    match image {
        Some(img) if img.width > 0 && img.height > 0 => {
            let fillk = (win.2 / iw as f64).max(win.3 / ih as f64);
            let drawn = (iw as f64 * fillk, ih as f64 * fillk);
            let left = win.0 + win.2 / 2.0 - drawn.0 / 2.0;
            let top = win.1 + win.3 / 2.0 + drawn.1 / 2.0;
            // Shrink the picture to about its drawn pixel size first (area average), then place it.
            let pw = ((drawn.0 * scale as f64).round() as usize).max(1);
            let ph = ((drawn.1 * scale as f64).round() as usize).max(1);
            let small = resize(img.width as usize, img.height as usize, &img.data, pw, ph);
            if let Some(src) = Pixmap::from_vec(small, tiny_skia::IntSize::from_wh(pw as u32, ph as u32).unwrap()) {
                let pat_tf = Transform::from_row(
                    (drawn.0 / pw as f64) as f32,
                    0.0,
                    0.0,
                    -((drawn.1 / ph as f64) as f32),
                    left as f32,
                    top as f32,
                );
                let shader = tiny_skia::Pattern::new(src.as_ref(), tiny_skia::SpreadMode::Pad, tiny_skia::FilterQuality::Bilinear, 1.0, pat_tf);
                let p = tiny_skia::Paint { shader, anti_alias: true, ..Default::default() };
                pm.fill_path(&win_path, &p, tiny_skia::FillRule::Winding, tf, None);
            }
        }
        _ => fill(&mut pm, &win_path, rgba(0.62, 0.66, 0.68, 1.0), tf, None),
    }
    let gloss = [(0.0, rgba(1.0, 1.0, 1.0, 0.0)), (0.6, rgba(1.0, 1.0, 1.0, 0.0)), (1.0, rgba(1.0, 1.0, 1.0, 0.16))];
    fill_linear(&mut pm, &win_path, &gloss, (win.0, win.1), (win.0 + win.2, win.1 + win.3), tf, None);

    magnet(&mut pm, tf, (print.0 / 2.0, print.1 - 1.0), magnet_color, scale);
    pm
}

fn magnet(pm: &mut Pixmap, tf: Transform, center: (f64, f64), color: usize, scale: f32) {
    let base = MAGNET_COLORS[wrap_index(color, MAGNET_COLORS.len())];
    let r = MAGNET_RADIUS - 0.5;
    let Some(disc) = ellipse(center.0 - r, center.1 - r, r * 2.0, r * 2.0) else { return };
    let off = (0.0, -1.5 * CG_SHADOW_PT);
    with_shadow(pm, scale, off, 2.5 * CG_SHADOW_PT, rgba(0.0, 0.0, 0.0, 0.45), None, |layer| {
        fill(layer, &disc, hex(base, 1.0), tf, None);
    });
    let shine = [(0.0, rgba(1.0, 1.0, 1.0, 0.65)), (0.45, rgba(1.0, 1.0, 1.0, 0.08)), (1.0, rgba(0.0, 0.0, 0.0, 0.25))];
    let focal = (center.0 - r * 0.35, center.1 + r * 0.4);
    fill_radial(pm, &disc, &shine, focal, center, r * 1.1, Transform::identity(), tf, None);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn photo_sizes() {
        assert_eq!(photo_print_size(400, 300), (92.0, 78.0));
        assert_eq!(photo_layer_size(300, 400), (71.0, 106.0));
        // Very wide pictures are clamped to 2.5:1.
        assert_eq!(photo_print_size(1000, 10), (92.0, 49.0));
    }

    #[test]
    fn split_words() {
        assert_eq!(split_keep_spaces("a bc  d"), vec!["a ", "bc  ", "d"]);
    }
}
