//! The static art, ported recipe by recipe from `FridgeArt.swift`, `InteriorArt.swift` and
//! `DoorRig.swift`. Each function paints with a transform from its own space (points, y up)
//! into the target pixmap, so the compositor can draw straight into frame-aligned sprites.

use crate::canvas::*;
use fridge_core::geometry::{DoorSpec, BIN_DEPTH, BIN_INSET, BIN_LIP_HEIGHT, BODY_SIZE, DOOR_CORNER_RADIUS, DOOR_HALF_THICKNESS, OPENING};
use fridge_core::{InteriorGeometry, SeededRandom};
use tiny_skia::{LineCap, Mask, Pixmap, Transform};

/// CoreGraphics shadow offsets and blurs are in device pixels, not points. The Mac reference is a
/// Retina screen (2 px per point), so one CG shadow unit is half a point.
pub const CG_SHADOW_PT: f64 = 0.5;

// MARK: Cabinet

pub fn cabinet(pm: &mut Pixmap, tf: Transform) {
    let (bw, bh) = BODY_SIZE;
    let body = (0.0, 8.0, bw, bh - 8.0);
    let body_path = rrect(body.0, body.1, body.2, body.3, 28.0);

    for x in [22.0, 230.0] {
        fill(pm, &rrect(x, 0.0, 28.0, 14.0, 4.0), hex(0x262A2D, 1.0), tf, None);
    }

    let paint = [(0.0, hex(0xC9CF3A, 1.0)), (0.5, hex(0x9DA716, 1.0)), (1.0, hex(0x6E7303, 1.0))];
    fill_linear(pm, &body_path, &paint, (0.0, 0.0), (body.2, 0.0), tf, None);

    // Clipped to the body: right side, top highlight, plinth shade. None extend past their ends.
    let side = [(0.0, rgba(0.0, 0.0, 0.0, 0.0)), (1.0, rgba(0.05, 0.12, 0.10, 0.34))];
    let clip = clip_rect(pm, tf, body_path.clone(), (body.2 - 16.0, -10.0, 40.0, bh + 20.0));
    fill_linear(pm, &body_path, &side, (body.2 - 16.0, 0.0), (body.2, 0.0), tf, Some(&clip));
    let top = [(0.0, rgba(1.0, 1.0, 1.0, 0.0)), (1.0, rgba(1.0, 1.0, 1.0, 0.55))];
    let clip = clip_rect(pm, tf, body_path.clone(), (-10.0, body.1 + body.3 - 12.0, bw + 20.0, 40.0));
    fill_linear(pm, &body_path, &top, (0.0, body.1 + body.3 - 12.0), (0.0, body.1 + body.3), tf, Some(&clip));
    let plinth = [(0.0, rgba(0.0, 0.0, 0.0, 0.30)), (1.0, rgba(0.0, 0.0, 0.0, 0.0))];
    let clip = clip_rect(pm, tf, body_path.clone(), (-10.0, body.1, bw + 20.0, 14.0));
    fill_linear(pm, &body_path, &plinth, (0.0, body.1), (0.0, body.1 + 14.0), tf, Some(&clip));

    // White moulded liner frame round the opening.
    let rim = (7.0, 15.0, bw - 14.0, bh - 22.0);
    let rim_stops = [(0.0, hex(0xDDE2E2, 1.0)), (0.5, hex(0xF6F8F7, 1.0)), (1.0, hex(0xD2D8D9, 1.0))];
    fill_linear(pm, &rrect(rim.0, rim.1, rim.2, rim.3, 14.0), &rim_stops, (rim.0, 0.0), (rim.0 + rim.2, 0.0), tf, None);
    stroke(pm, &rrect(rim.0 + 0.5, rim.1 + 0.5, rim.2 - 1.0, rim.3 - 1.0, 14.0), rgba(0.0, 0.0, 0.0, 0.18), 1.0, tf, None);
    let o = OPENING;
    stroke(pm, &rrect(o.x - 1.5, o.y - 1.5, o.w + 3.0, o.h + 3.0, 6.0), rgba(0.3, 0.36, 0.38, 0.35), 1.2, tf, None);

    // Outer bevel.
    stroke(pm, &body_path, rgba(0.0, 0.0, 0.0, 0.22), 1.0, tf, None);
    stroke(pm, &rrect(body.0 + 1.2, body.1 + 1.2, body.2 - 2.4, body.3 - 2.4, 27.0), rgba(1.0, 1.0, 1.0, 0.45), 1.0, tf, None);
}

/// A mask of `path` limited to a rectangle (both in the transform's space).
fn clip_rect(pm: &Pixmap, tf: Transform, path: tiny_skia::Path, r: (f64, f64, f64, f64)) -> Mask {
    let mut m = mask(pm, &path, tf);
    m.intersect_path(&rect_path(r.0, r.1, r.2, r.3), tiny_skia::FillRule::Winding, true, tf);
    m
}

// MARK: Interior

fn pt(x: f64, y: f64, depth: f64) -> (f64, f64) {
    let r = InteriorGeometry::project(x, y, depth);
    (r.0, r.1)
}

/// The inside of the cabinet. `tf` maps opening points; `clip` is the opening rectangle.
pub fn interior(pm: &mut Pixmap, tf: Transform, clip: &Mask, scale: f32) {
    let w = InteriorGeometry::OPENING_WIDTH;
    let h = InteriorGeometry::OPENING_HEIGHT;
    let m = Some(clip);
    let (fbl, fbr, ftl, ftr) = (pt(0.0, 0.0, 0.0), pt(w, 0.0, 0.0), pt(0.0, h, 0.0), pt(w, h, 0.0));
    let (bbl, bbr, btl, btr) = (pt(0.0, 0.0, 1.0), pt(w, 0.0, 1.0), pt(0.0, h, 1.0), pt(w, h, 1.0));

    fill(pm, &rect_path(0.0, 0.0, w, h), hex(0x9DB8C2, 1.0), tf, m);

    fill_linear(pm, &polygon(&[fbl, fbr, bbr, bbl]), &[(0.0, hex(0x9DBAC5, 1.0)), (1.0, hex(0xD3E4EA, 1.0))], (0.0, fbl.1), (0.0, bbl.1), tf, m);
    fill(pm, &polygon(&[pt(30.0, 0.0, 0.0), pt(110.0, 0.0, 0.0), pt(120.0, 0.0, 1.0), pt(60.0, 0.0, 1.0)]), rgba(1.0, 1.0, 1.0, 0.10), tf, m);

    fill_linear(pm, &polygon(&[fbl, bbl, btl, ftl]), &[(0.0, hex(0xB5CFD8, 1.0)), (1.0, hex(0xDCEAF0, 1.0))], (fbl.0, 0.0), (bbl.0, 0.0), tf, m);
    fill_linear(pm, &polygon(&[fbr, bbr, btr, ftr]), &[(0.0, hex(0xA9C5CF, 1.0)), (1.0, hex(0xD6E6EC, 1.0))], (fbr.0, 0.0), (bbr.0, 0.0), tf, m);
    fill_linear(pm, &polygon(&[bbl, bbr, btr, btl]), &[(0.0, hex(0xE0EEF3, 1.0)), (1.0, hex(0xF6FBFD, 1.0))], (0.0, bbl.1), (0.0, h), tf, m);

    let seam = rgba(0.1, 0.25, 0.32, 0.22);
    for (a, b) in [(fbl, bbl), (fbr, bbr), (bbl, bbr), (bbl, btl), (bbr, btr)] {
        stroke_cap(pm, &line(a, b), seam, 1.4, LineCap::Round, tf, m);
    }

    for front in InteriorGeometry::SHELF_FRONT_Y {
        rails(pm, tf, m, front, w);
    }
    for front in InteriorGeometry::SHELF_FRONT_Y {
        shelf(pm, tf, clip, front, w, scale);
    }

    let vignette = [(0.0, rgba(0.0, 0.05, 0.1, 0.0)), (0.62, rgba(0.0, 0.05, 0.1, 0.0)), (1.0, rgba(0.0, 0.05, 0.1, 0.30))];
    let c = (w / 2.0, h * 0.52);
    fill_radial(pm, &rect_path(0.0, 0.0, w, h), &vignette, c, c, h * 0.68, Transform::identity(), tf, m);
}

fn rails(pm: &mut Pixmap, tf: Transform, m: Option<&Mask>, y: f64, w: f64) {
    for x in [0.0, w] {
        let a = pt(x, y, 0.0);
        let b = pt(x, y, 1.0);
        stroke(pm, &line(a, b), rgba(0.1, 0.25, 0.32, 0.35), 3.0, tf, m);
        stroke(pm, &line((a.0, a.1 + 2.0), (b.0, b.1 + 2.0)), rgba(1.0, 1.0, 1.0, 0.45), 1.0, tf, m);
    }
}

fn shelf(pm: &mut Pixmap, tf: Transform, clip: &Mask, y: f64, w: f64, scale: f32) {
    let (fl, fr, br, bl) = (pt(0.0, y, 0.0), pt(w, y, 0.0), pt(w, y, 1.0), pt(0.0, y, 1.0));
    let top = polygon(&[fl, fr, br, bl]);
    let m = Some(clip);

    // The glass throws a soft shadow on the wall below it.
    let off = (0.0, -5.0 * CG_SHADOW_PT);
    with_shadow(pm, scale, off, 9.0 * CG_SHADOW_PT, rgba(0.0, 0.1, 0.18, 0.32), m, |layer| {
        fill(layer, &top, rgba(0.80, 0.93, 0.97, 0.9), tf, None);
    });

    fill_linear(pm, &top, &[(0.0, rgba(0.86, 0.97, 1.0, 0.92)), (1.0, rgba(0.70, 0.88, 0.95, 0.88))], (0.0, fl.1), (0.0, bl.1), tf, m);

    let mut glare = mask(pm, &top, tf);
    glare.intersect_path(&rect_path(0.0, 0.0, w, InteriorGeometry::OPENING_HEIGHT), tiny_skia::FillRule::Winding, true, tf);
    let streak1 = polygon(&[(fl.0 + 40.0, fl.1), (fl.0 + 78.0, fl.1), (bl.0 + 70.0, bl.1), (bl.0 + 48.0, bl.1)]);
    fill(pm, &streak1, rgba(1.0, 1.0, 1.0, 0.20), tf, Some(&glare));
    let streak2 = polygon(&[(fl.0 + 130.0, fl.1), (fl.0 + 150.0, fl.1), (bl.0 + 138.0, bl.1), (bl.0 + 124.0, bl.1)]);
    fill(pm, &streak2, rgba(1.0, 1.0, 1.0, 0.12), tf, Some(&glare));

    let lip_h = 7.0;
    let lip = rect_path(fl.0, fl.1 - lip_h, fr.0 - fl.0, lip_h);
    let lip_stops = [(0.0, rgba(0.45, 0.72, 0.80, 0.95)), (0.5, rgba(0.75, 0.93, 0.98, 0.98)), (1.0, rgba(0.96, 1.0, 1.0, 1.0))];
    fill_linear(pm, &lip, &lip_stops, (0.0, fl.1 - lip_h), (0.0, fl.1), tf, m);
    stroke(pm, &line((fl.0, fl.1 - lip_h), (fr.0, fl.1 - lip_h)), rgba(0.1, 0.3, 0.38, 0.45), 0.9, tf, m);

    stroke(pm, &line(bl, br), rgba(1.0, 1.0, 1.0, 0.55), 1.0, tf, m);
}

/// Static rime, crystals and condensation (`InteriorArt.frost`), same seed and order.
pub fn interior_frost(pm: &mut Pixmap, tf: Transform, clip: &Mask) {
    let w = InteriorGeometry::OPENING_WIDTH;
    let h = InteriorGeometry::OPENING_HEIGHT;
    let m = Some(clip);
    let mut rng = SeededRandom::new(0xF205_7ED);

    let mut seams: Vec<((f64, f64), (f64, f64))> = vec![
        (pt(0.0, 0.0, 0.0), pt(0.0, 0.0, 1.0)),
        (pt(w, 0.0, 0.0), pt(w, 0.0, 1.0)),
        (pt(0.0, 0.0, 1.0), pt(w, 0.0, 1.0)),
        (pt(0.0, 0.0, 1.0), pt(0.0, h, 1.0)),
        (pt(w, 0.0, 1.0), pt(w, h, 1.0)),
        (pt(0.0, h, 0.0), pt(0.0, h, 1.0)),
        (pt(w, h, 0.0), pt(w, h, 1.0)),
    ];
    for y in InteriorGeometry::SHELF_FRONT_Y {
        seams.push((pt(0.0, y, 0.0), pt(0.0, y, 1.0)));
        seams.push((pt(w, y, 0.0), pt(w, y, 1.0)));
        seams.push((pt(0.0, y, 1.0), pt(w, y, 1.0)));
    }

    // Fine grain along every seam. Thousands of tiny dots: drawn directly as soft discs.
    let mut dots = DotPainter::new(pm, tf);
    for &(a, b) in &seams {
        let length = (b.0 - a.0).hypot(b.1 - a.1);
        let count = (length * 2.6) as usize;
        for _ in 0..count {
            let t = rng.unit();
            let spread = ((rng.unit() + rng.unit() + rng.unit()) / 3.0 - 0.5) * 2.0;
            let reach = 20.0;
            let dx = spread * reach;
            let dy = (rng.unit() - 0.5) * reach * 0.8;
            let x = a.0 + (b.0 - a.0) * t + dx;
            let y = a.1 + (b.1 - a.1) * t + dy;
            let fall = (1.0 - dx.hypot(dy) / reach).max(0.0);
            let r = rng.range(0.35, 1.25) * (0.5 + fall);
            let alpha = rng.range(0.10, 0.50) * fall;
            dots.disc(x, y, r, [0.95, 0.99, 1.0], alpha);
        }
    }
    dots.finish(pm, clip);

    // Crystal ferns: six-armed stars near the seams.
    for _ in 0..90 {
        let seam = seams[rng.range(0.0, seams.len() as f64) as usize];
        let t = rng.unit();
        let cx = seam.0 .0 + (seam.1 .0 - seam.0 .0) * t + (rng.unit() - 0.5) * 14.0;
        let cy = seam.0 .1 + (seam.1 .1 - seam.0 .1) * t + (rng.unit() - 0.5) * 14.0;
        let arm = rng.range(2.0, 5.5);
        let phase = rng.range(0.0, std::f64::consts::PI / 3.0);
        let color = rgba(1.0, 1.0, 1.0, rng.range(0.25, 0.6) as f32);
        for k in 0..6 {
            let a = phase + k as f64 * std::f64::consts::PI / 3.0;
            stroke_cap(pm, &line((cx, cy), (cx + a.cos() * arm, cy + a.sin() * arm)), color, 0.6, LineCap::Round, tf, m);
        }
    }

    // Condensation beads on the back wall.
    let bmin = pt(0.0, 0.0, 1.0);
    let bmax = pt(w, h, 1.0);
    for _ in 0..70 {
        let x = rng.range(bmin.0 + 6.0, bmax.0 - 6.0);
        let y = rng.range(bmin.1 + 10.0, bmax.1.min(h) - 6.0);
        let r = rng.range(1.1, 3.0);
        if let Some(bead) = ellipse(x - r, y - r, r * 2.0, r * 2.0) {
            fill(pm, &bead, rgba(0.82, 0.94, 1.0, 0.20), tf, m);
            stroke(pm, &bead, rgba(1.0, 1.0, 1.0, 0.42), 0.6, tf, m);
        }
        if let Some(hl) = ellipse(x - r * 0.55, y + r * 0.15, r * 0.55, r * 0.55) {
            fill(pm, &hl, rgba(1.0, 1.0, 1.0, 0.85), tf, m);
        }
    }
}

/// Paints many small antialiased discs straight into a float buffer (much faster than a path
/// per dot), then lays the result over the pixmap in one go. Source-over, in drawing order.
struct DotPainter {
    w: usize,
    h: usize,
    buf: Vec<[f32; 4]>,
    tf: Transform,
    scale: f32,
}

impl DotPainter {
    fn new(pm: &Pixmap, tf: Transform) -> DotPainter {
        let (w, h) = (pm.width() as usize, pm.height() as usize);
        DotPainter { w, h, buf: vec![[0.0; 4]; w * h], tf, scale: tf.sx.abs() }
    }

    fn disc(&mut self, x: f64, y: f64, r: f64, rgb: [f32; 3], alpha: f64) {
        if alpha <= 0.0 || r <= 0.0 {
            return;
        }
        let mut p = tiny_skia::Point::from_xy(x as f32, y as f32);
        self.tf.map_point(&mut p);
        let rp = r as f32 * self.scale;
        let x0 = ((p.x - rp - 1.0).floor().max(0.0)) as usize;
        let y0 = ((p.y - rp - 1.0).floor().max(0.0)) as usize;
        let x1 = ((p.x + rp + 1.0).ceil() as i64).clamp(0, self.w as i64) as usize;
        let y1 = ((p.y + rp + 1.0).ceil() as i64).clamp(0, self.h as i64) as usize;
        let a = alpha as f32;
        for yy in y0..y1 {
            for xx in x0..x1 {
                // Coverage from the distance of the pixel centre to the rim, 4 x 4 supersampled
                // for dots smaller than a pixel.
                let cov = if rp < 1.5 {
                    let mut n = 0;
                    for sy in 0..4 {
                        for sx in 0..4 {
                            let dx = xx as f32 + (sx as f32 + 0.5) / 4.0 - p.x;
                            let dy = yy as f32 + (sy as f32 + 0.5) / 4.0 - p.y;
                            if dx * dx + dy * dy <= rp * rp {
                                n += 1;
                            }
                        }
                    }
                    n as f32 / 16.0
                } else {
                    let dx = xx as f32 + 0.5 - p.x;
                    let dy = yy as f32 + 0.5 - p.y;
                    (rp - (dx * dx + dy * dy).sqrt() + 0.5).clamp(0.0, 1.0)
                };
                if cov <= 0.0 {
                    continue;
                }
                let k = a * cov;
                let d = &mut self.buf[yy * self.w + xx];
                let inv = 1.0 - k;
                d[0] = rgb[0] * k + d[0] * inv;
                d[1] = rgb[1] * k + d[1] * inv;
                d[2] = rgb[2] * k + d[2] * inv;
                d[3] = k + d[3] * inv;
            }
        }
    }

    fn finish(self, pm: &mut Pixmap, clip: &Mask) {
        let mut layer = Pixmap::new(self.w as u32, self.h as u32).unwrap();
        let data = layer.data_mut();
        for (i, c) in self.buf.iter().enumerate() {
            if c[3] <= 0.0 {
                continue;
            }
            let o = i * 4;
            data[o] = (c[0] * 255.0 + 0.5).min(255.0) as u8;
            data[o + 1] = (c[1] * 255.0 + 0.5).min(255.0) as u8;
            data[o + 2] = (c[2] * 255.0 + 0.5).min(255.0) as u8;
            data[o + 3] = (c[3] * 255.0 + 0.5).min(255.0) as u8;
        }
        draw_layer(pm, &layer, 1.0, Some(clip));
    }
}

// MARK: Doors

/// Door front: the artwork stretched into the door, clipped to the outline, two bevels.
/// `art` is premultiplied RGBA already resized to the pixmap size.
pub fn door_front(spec: &DoorSpec, art: Option<&Pixmap>, scale: f32) -> Pixmap {
    let (w, h) = (spec.width(), spec.height());
    let (mut pm, tf) = canvas(w, h, scale);
    let path = door_outline(spec, 0.0, 0.0, w, h, DOOR_CORNER_RADIUS);
    match art {
        Some(img) => {
            let shader = tiny_skia::Pattern::new(
                img.as_ref(),
                tiny_skia::SpreadMode::Pad,
                tiny_skia::FilterQuality::Nearest,
                1.0,
                tf.invert().unwrap(),
            );
            let p = tiny_skia::Paint { shader, anti_alias: true, ..Default::default() };
            pm.fill_path(&path, &p, tiny_skia::FillRule::Winding, tf, None);
        }
        None => fill(&mut pm, &path, hex(0x9DA716, 1.0), tf, None),
    }
    stroke(&mut pm, &path, rgba(0.0, 0.0, 0.0, 0.35), 1.0, tf, None);
    let inner = door_outline(spec, 1.3, 1.3, w - 2.6, h - 2.6, DOOR_CORNER_RADIUS - 1.0);
    stroke(&mut pm, &inner, rgba(1.0, 1.0, 0.8, 0.30), 1.0, tf, None);
    pm
}

/// Door liner (`FridgeArt.doorBack`), drawn as seen from inside: the compositor mirrors it.
pub fn door_back(spec: &DoorSpec, scale: f32) -> Pixmap {
    let (w, h) = (spec.width(), spec.height());
    let (mut pm, tf) = canvas(w, h, scale);
    let path = door_outline(spec, 0.0, 0.0, w, h, DOOR_CORNER_RADIUS);
    fill_linear(&mut pm, &path, &[(0.0, hex(0xDCE8EE, 1.0)), (1.0, hex(0xF3F8FA, 1.0))], (0.0, 0.0), (0.0, h), tf, None);

    let panel = rrect(18.0, 18.0, w - 36.0, h - 36.0, 12.0);
    fill_linear(&mut pm, &panel, &[(0.0, hex(0xC9D8E0, 1.0)), (1.0, hex(0xE6EFF3, 1.0))], (0.0, 0.0), (w, 0.0), tf, None);
    stroke(&mut pm, &panel, rgba(0.2, 0.3, 0.36, 0.25), 1.2, tf, None);
    stroke(&mut pm, &rrect(19.5, 19.5, w - 39.0, h - 39.0, 11.0), rgba(1.0, 1.0, 1.0, 0.6), 1.0, tf, None);
    for &y in spec.bin_y {
        let r = (BIN_INSET, y - 18.0, w - 2.0 * BIN_INSET, 18.0);
        let stops = [(0.0, rgba(0.0, 0.1, 0.15, 0.0)), (1.0, rgba(0.0, 0.1, 0.15, 0.22))];
        fill_linear(&mut pm, &rect_path(r.0, r.1, r.2, r.3), &stops, (0.0, r.1), (0.0, r.1 + r.3), tf, None);
    }

    stroke(&mut pm, &door_outline(spec, 7.0, 7.0, w - 14.0, h - 14.0, 18.0), hex(0x3A4449, 1.0), 13.0, tf, None);
    stroke(&mut pm, &door_outline(spec, 10.5, 10.5, w - 21.0, h - 21.0, 15.0), rgba(1.0, 1.0, 1.0, 0.18), 1.2, tf, None);
    stroke(&mut pm, &door_outline(spec, 3.5, 3.5, w - 7.0, h - 7.0, 21.0), rgba(0.0, 0.0, 0.0, 0.35), 1.0, tf, None);
    stroke(&mut pm, &path, rgba(0.0, 0.0, 0.0, 0.25), 1.0, tf, None);
    pm
}

/// The free edge strip: (bottom inset, top inset, height) in door space.
pub fn edge_span(spec: &DoorSpec) -> (f64, f64, f64) {
    let top = if spec.round_top { DOOR_CORNER_RADIUS * 0.5 } else { 1.0 };
    let bottom = if spec.round_bottom { DOOR_CORNER_RADIUS * 0.5 } else { 1.0 };
    (bottom, top, spec.height() - top - bottom)
}

/// The door's thickness seen face-on: painted steel rounding over, then the dark gasket.
/// Texture x runs from the front face (left) to the liner (right).
pub fn door_edge(spec: &DoorSpec, scale: f32) -> Pixmap {
    let (_, _, eh) = edge_span(spec);
    let ew = DOOR_HALF_THICKNESS * 2.0;
    let (mut pm, tf) = canvas(ew, eh, scale);
    let stops = [
        (0.0, hex(0x505006, 1.0)),
        (0.10, hex(0x9DA716, 1.0)),
        (0.28, hex(0xE4E57A, 1.0)),
        (0.55, hex(0xB6BD21, 1.0)),
        (0.72, hex(0x7D8202, 1.0)),
        (0.76, hex(0x2B2E2A, 1.0)),
        (1.0, hex(0x3A3D38, 1.0)),
    ];
    fill_linear(&mut pm, &rrect(0.0, 0.0, ew, eh, DOOR_HALF_THICKNESS * 0.8), &stops, (0.0, 0.0), (ew, 0.0), tf, None);
    pm
}

pub fn bin_lip_height(spec: &DoorSpec, index: usize) -> f64 {
    if index == 0 && spec.bin_y.len() > 1 {
        BIN_LIP_HEIGHT + 8.0
    } else {
        BIN_LIP_HEIGHT
    }
}

pub fn bin_width(spec: &DoorSpec) -> f64 {
    spec.width() - 2.0 * BIN_INSET
}

/// Bin floor, `width x depth`; texture top is the liner side.
pub fn bin_floor(spec: &DoorSpec, scale: f32) -> Pixmap {
    let (w, d) = (bin_width(spec), BIN_DEPTH);
    let (mut pm, tf) = canvas(w, d, scale);
    fill(&mut pm, &rect_path(0.0, 0.0, w, d), rgba(0.86, 0.93, 0.96, 0.95), tf, None);
    stroke(&mut pm, &rect_path(0.5, 0.5, w - 1.0, d - 1.0), rgba(1.0, 1.0, 1.0, 0.8), 1.0, tf, None);
    pm
}

/// Clear front lip of a bin: gradient from its bottom edge up, rounded 3, white border.
pub fn bin_lip(spec: &DoorSpec, lip_h: f64, scale: f32) -> Pixmap {
    let w = bin_width(spec);
    let (mut pm, tf) = canvas(w, lip_h, scale);
    let stops = [(0.0, rgba(0.97, 0.99, 1.0, 0.96)), (0.55, rgba(0.80, 0.90, 0.95, 0.90)), (1.0, rgba(0.66, 0.80, 0.88, 0.92))];
    fill_linear(&mut pm, &rrect(0.0, 0.0, w, lip_h, 3.0), &stops, (0.0, 0.0), (0.0, lip_h), tf, None);
    stroke(&mut pm, &rrect(0.5, 0.5, w - 1.0, lip_h - 1.0, 2.5), rgba(1.0, 1.0, 1.0, 0.9), 1.0, tf, None);
    pm
}

pub fn bin_cheek(lip_h: f64, scale: f32) -> Pixmap {
    let (mut pm, tf) = canvas(BIN_DEPTH, lip_h, scale);
    fill(&mut pm, &rect_path(0.0, 0.0, BIN_DEPTH, lip_h), rgba(0.78, 0.88, 0.93, 0.92), tf, None);
    pm
}

// MARK: Hinge

pub const HINGE_SIZE: (f64, f64) = (13.0, 40.0);

/// Hinge plate drawn on a 20 x 64 grid into a 13 x 40 box. `tf` maps the 13 x 40 box.
pub fn hinge(pm: &mut Pixmap, tf: Transform, scale: f32) {
    let box_clip = mask(pm, &rect_path(0.0, 0.0, HINGE_SIZE.0, HINGE_SIZE.1), tf);
    let t = tf.pre_scale((HINGE_SIZE.0 / 20.0) as f32, (HINGE_SIZE.1 / 64.0) as f32);
    let plate = rrect(1.0, 2.0, 18.0, 60.0, 4.0);
    let off = (1.0 * CG_SHADOW_PT, -1.5 * CG_SHADOW_PT);
    with_shadow(pm, scale, off, 2.5 * CG_SHADOW_PT, rgba(0.0, 0.0, 0.0, 0.5), Some(&box_clip), |layer| {
        fill(layer, &plate, hex(0x9AA9A3, 1.0), t, None);
    });
    let steel = [(0.0, hex(0x6D7E78, 1.0)), (0.35, hex(0xF2F8F6, 1.0)), (0.7, hex(0xB0C0BA, 1.0)), (1.0, hex(0x72847D, 1.0))];
    fill_linear(pm, &plate, &steel, (1.0, 0.0), (19.0, 0.0), t, Some(&box_clip));
    stroke(pm, &plate, rgba(0.0, 0.0, 0.0, 0.35), 0.8, t, Some(&box_clip));
    for y in [22.0, 32.0, 42.0] {
        stroke(pm, &line((2.0, y), (18.0, y)), rgba(0.0, 0.0, 0.0, 0.3), 0.8, t, Some(&box_clip));
    }
    for y in [10.0, 54.0] {
        if let Some(screw) = ellipse(7.0, y - 3.0, 6.0, 6.0) {
            fill(pm, &screw, hex(0x5A6B65, 1.0), t, Some(&box_clip));
        }
        stroke(pm, &line((7.8, y), (12.2, y)), rgba(1.0, 1.0, 1.0, 0.6), 0.8, t, Some(&box_clip));
    }
}

// MARK: Shadows

pub const CONTACT_SHADOW_SIZE: (f64, f64) = (380.0, 70.0);
pub const LIFT_SHADOW_SIZE: (f64, f64) = (460.0, 150.0);
pub const ITEM_SHADOW_SIZE: (f64, f64) = (64.0, 18.0);

/// `tf` maps the 380 x 70 shadow box.
pub fn contact_shadow(pm: &mut Pixmap, tf: Transform) {
    let (w, h) = CONTACT_SHADOW_SIZE;
    let all = rect_path(0.0, 0.0, w, h);
    let g = [(0.0, rgba(0.0, 0.0, 0.0, 0.55)), (0.55, rgba(0.0, 0.0, 0.0, 0.22)), (1.0, rgba(0.0, 0.0, 0.0, 0.0))];
    let gt = Transform::from_translate((w / 2.0) as f32, (h / 2.0) as f32).pre_scale(1.0, 0.18);
    fill_radial(pm, &all, &g, (0.0, 0.0), (0.0, 0.0), w / 2.0, gt, tf, None);
    let ao = [(0.0, rgba(0.0, 0.0, 0.0, 0.70)), (0.8, rgba(0.0, 0.0, 0.0, 0.30)), (1.0, rgba(0.0, 0.0, 0.0, 0.0))];
    let gt = Transform::from_translate((w / 2.0) as f32, (h / 2.0 + 1.0) as f32).pre_scale(1.0, 0.06);
    fill_radial(pm, &all, &ao, (0.0, 0.0), (0.0, 0.0), BODY_SIZE.0 / 2.0 + 6.0, gt, tf, None);
}

pub fn lift_shadow(pm: &mut Pixmap, tf: Transform) {
    let (w, h) = LIFT_SHADOW_SIZE;
    let g = [(0.0, rgba(0.0, 0.0, 0.0, 0.42)), (0.5, rgba(0.0, 0.0, 0.0, 0.18)), (1.0, rgba(0.0, 0.0, 0.0, 0.0))];
    let gt = Transform::from_translate((w / 2.0) as f32, (h / 2.0) as f32).pre_scale(1.0, 0.30);
    fill_radial(pm, &rect_path(0.0, 0.0, w, h), &g, (0.0, 0.0), (0.0, 0.0), w / 2.0, gt, tf, None);
}

pub fn item_shadow(scale: f32) -> Pixmap {
    let (w, h) = ITEM_SHADOW_SIZE;
    let (mut pm, tf) = canvas(w, h, scale);
    let g = [(0.0, rgba(0.0, 0.05, 0.1, 0.55)), (0.6, rgba(0.0, 0.05, 0.1, 0.22)), (1.0, rgba(0.0, 0.0, 0.0, 0.0))];
    let gt = Transform::from_translate((w / 2.0) as f32, (h / 2.0) as f32).pre_scale(1.0, (h / w) as f32);
    fill_radial(&mut pm, &rect_path(0.0, 0.0, w, h), &g, (0.0, 0.0), (0.0, 0.0), w / 2.0, gt, tf, None);
    pm
}

// MARK: Divider and compartment light

pub const DIVIDER: (f64, f64, f64, f64) = (12.0, 363.0, 256.0, 12.0);

/// `tf` maps scene points.
pub fn divider(pm: &mut Pixmap, tf: Transform) {
    let (x, y, w, h) = DIVIDER;
    let stops = [(0.0, hex(0xC9D0D2, 1.0)), (0.35, hex(0xF4F7F7, 1.0)), (0.7, hex(0xDDE3E4, 1.0)), (1.0, hex(0xA9B2B5, 1.0))];
    fill_linear(pm, &rrect(x, y, w, h, 3.0), &stops, (0.0, y), (0.0, y + h), tf, None);
}

/// The compartment glow over a slice rect (scene points): radial, centred at (0.5, 0.82) of the
/// slice, radii 0.65 w and 0.82 h, colour to clear.
pub fn glow(pm: &mut Pixmap, tf: Transform, slice: (f64, f64, f64, f64), color: (f32, f32, f32, f32)) {
    let (x, y, w, h) = slice;
    let c = rgba(color.0, color.1, color.2, color.3);
    let clear = rgba(color.0, color.1, color.2, 0.0);
    let gt = Transform::from_translate((x + 0.5 * w) as f32, (y + 0.82 * h) as f32).pre_scale((0.65 * w) as f32, (0.82 * h) as f32);
    fill_radial(pm, &rect_path(x, y, w, h), &[(0.0, c), (1.0, clear)], (0.0, 0.0), (0.0, 0.0), 1.0, gt, tf, None);
}
