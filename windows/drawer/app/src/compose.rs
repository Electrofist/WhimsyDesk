//! Puts one frame together: cast shadow, back layer, front layer, as premultiplied BGRA pixels
//! ready for `UpdateLayeredWindow`. No Windows calls, so it is tested here.
//!
//! The artwork is 780x300 pt and always drawn in full; the window just shows its top `h` pixel
//! rows (pushed down by the sag). The expensive part, rendering the layers, happens once per
//! theme and DPI scale; a frame is only a cheap "over" blend of cached pixels.

use crate::placement::Placement;
use drawer_art::{render_back, render_cast_shadow, render_front, Theme};

/// The cast shadow is pre-rendered at this many slide positions and the nearest one is used.
const SHADOW_STEPS: usize = 12;

pub struct Compositor {
    /// Artwork size in pixels.
    w: usize,
    h: usize,
    back: Vec<u8>,
    front: Vec<u8>,
    shadows: Vec<Vec<u8>>,
    /// What is inside the drawer (a full-size layer), drawn between the back and the front.
    contents: Option<Vec<u8>>,
}

impl Compositor {
    pub fn new(theme: &Theme, scale: f64) -> Self {
        let back = render_back(theme, scale);
        let front = render_front(theme, scale);
        let shadows = (0..SHADOW_STEPS)
            .map(|i| {
                render_cast_shadow(i as f64 / (SHADOW_STEPS - 1) as f64, scale)
                    .to_bgra8_premultiplied()
            })
            .collect();
        Self {
            w: back.width(),
            h: back.height(),
            back: back.to_bgra8_premultiplied(),
            front: front.to_bgra8_premultiplied(),
            shadows,
            contents: None,
        }
    }

    /// Replaces the contents layer (`size()` pixels, BGRA premultiplied).
    pub fn set_contents(&mut self, layer: Option<Vec<u8>>) {
        if let Some(l) = &layer {
            assert_eq!(
                l.len(),
                self.w * self.h * 4,
                "contents layer has the wrong size"
            );
        }
        self.contents = layer;
    }

    pub fn size(&self) -> (usize, usize) {
        (self.w, self.h)
    }

    fn shadow_for(&self, position: f64) -> &[u8] {
        let i = (position.clamp(0.0, 1.0) * (SHADOW_STEPS - 1) as f64).round() as usize;
        &self.shadows[i]
    }

    /// Draw a frame into `out` (BGRA, premultiplied, `p.w * p.h * 4` bytes; it is cleared first).
    pub fn compose(&self, position: f64, p: &Placement, out: &mut [u8]) {
        let (w, h) = (p.w as usize, p.h as usize);
        assert!(out.len() >= w * h * 4, "frame buffer too small");
        let out = &mut out[..w * h * 4];
        out.fill(0);
        let mut frame = Frame { buf: out, w, h };
        self.blit(&mut frame, self.shadow_for(position), p.sag_px);
        self.blit(&mut frame, &self.back, p.sag_px);
        if let Some(contents) = &self.contents {
            self.blit(&mut frame, contents, p.sag_px);
        }
        self.blit(&mut frame, &self.front, p.sag_px);
    }

    /// Source-over of one artwork layer; `dy` shifts it down inside the frame.
    fn blit(&self, frame: &mut Frame, src: &[u8], dy: i32) {
        let cols = self.w.min(frame.w);
        for fy in 0..frame.h {
            let sy = fy as i32 - dy;
            if sy < 0 || sy as usize >= self.h {
                continue;
            }
            let s = &src[sy as usize * self.w * 4..][..cols * 4];
            let d = &mut frame.buf[fy * frame.w * 4..][..cols * 4];
            over_row(d, s);
        }
    }
}

/// The frame being built; drawing helpers for the contents layer live here.
pub struct Frame<'a> {
    pub buf: &'a mut [u8],
    pub w: usize,
    pub h: usize,
}

impl Frame<'_> {
    pub fn pixel(&self, x: usize, y: usize) -> [u8; 4] {
        let i = (y * self.w + x) * 4;
        [
            self.buf[i],
            self.buf[i + 1],
            self.buf[i + 2],
            self.buf[i + 3],
        ]
    }
}

/// `dst = src + dst * (1 - src.alpha)` for premultiplied BGRA rows.
fn over_row(dst: &mut [u8], src: &[u8]) {
    for (d, s) in dst.chunks_exact_mut(4).zip(src.chunks_exact(4)) {
        let a = s[3] as u32;
        if a == 0 {
            continue;
        }
        if a == 255 {
            d.copy_from_slice(s);
            continue;
        }
        let inv = 255 - a;
        for k in 0..4 {
            d[k] = (s[k] as u32 + (d[k] as u32 * inv + 127) / 255).min(255) as u8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::placement::{placement, Monitor, RectPx};
    use drawer_art::DARK;

    fn mon() -> Monitor {
        Monitor {
            bounds: RectPx::new(0, 0, 1920, 1080),
            work: RectPx::new(0, 0, 1920, 1040),
            dpi_scale: 1.0,
            primary: true,
        }
    }

    #[test]
    fn over_blends_premultiplied_pixels() {
        let mut d = [0, 0, 200, 255];
        over_row(&mut d, &[0, 0, 100, 128]);
        assert_eq!(d[3], 255);
        assert!((d[2] as i32 - 200).abs() <= 100 + 1 && d[2] > 100);
        let mut d = [10, 20, 30, 40];
        over_row(&mut d, &[0, 0, 0, 0]);
        assert_eq!(d, [10, 20, 30, 40], "transparent source changes nothing");
        over_row(&mut d, &[1, 2, 3, 255]);
        assert_eq!(d, [1, 2, 3, 255], "opaque source replaces");
    }

    #[test]
    fn a_closed_frame_has_a_front_panel_and_transparent_margins() {
        let c = Compositor::new(&DARK, 1.0);
        assert_eq!(c.size(), (780, 300));
        let p = placement(&mon(), 0.0, false);
        let mut buf = vec![0u8; (p.w * p.h * 4) as usize];
        c.compose(0.0, &p, &mut buf);
        let f = Frame {
            buf: &mut buf,
            w: p.w as usize,
            h: p.h as usize,
        };
        assert_eq!(f.pixel(390, 40)[3], 255, "the panel is opaque");
        assert_eq!(f.pixel(3, 3)[3], 0, "the corner is see-through");
    }

    #[test]
    fn the_contents_layer_sits_between_back_and_front() {
        let mut c = Compositor::new(&DARK, 1.0);
        let p = placement(&mon(), 1.0, false);
        let mut buf = vec![0u8; (p.w * p.h * 4) as usize];
        // A magenta layer over everything: it must show in the open box and be hidden behind the
        // opaque front panel.
        c.set_contents(Some(
            [255u8, 0, 255, 255]
                .iter()
                .copied()
                .cycle()
                .take(780 * 300 * 4)
                .collect(),
        ));
        c.compose(1.0, &p, &mut buf);
        let f = Frame {
            buf: &mut buf,
            w: p.w as usize,
            h: p.h as usize,
        };
        assert_eq!(
            f.pixel(390, 40),
            c_front_pixel(&c, 390, 40),
            "panel covers it"
        );
        assert_eq!(
            f.pixel(390, 200),
            [255, 0, 255, 255],
            "visible inside the box"
        );
    }

    fn c_front_pixel(c: &Compositor, x: usize, y: usize) -> [u8; 4] {
        let i = (y * c.w + x) * 4;
        [c.front[i], c.front[i + 1], c.front[i + 2], c.front[i + 3]]
    }

    #[test]
    fn sag_pushes_the_art_down() {
        let c = Compositor::new(&DARK, 1.0);
        let mut p = placement(&mon(), 0.0, false);
        p.sag_px = 3;
        let mut buf = vec![0u8; (p.w * p.h * 4) as usize];
        c.compose(0.0, &p, &mut buf);
        let f = Frame {
            buf: &mut buf,
            w: p.w as usize,
            h: p.h as usize,
        };
        assert_eq!(f.pixel(390, 43), c_front_pixel(&c, 390, 40));
    }

    #[test]
    fn a_shorter_window_shows_only_the_top_of_the_art() {
        let c = Compositor::new(&DARK, 1.0);
        let p = placement(&mon(), 0.0, false);
        assert!((p.h as usize) < c.size().1);
        let mut buf = vec![0u8; (p.w * p.h * 4) as usize];
        c.compose(0.0, &p, &mut buf); // must not panic or overrun
    }
}
