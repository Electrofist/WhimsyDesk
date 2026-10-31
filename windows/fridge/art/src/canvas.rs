//! Thin helpers over tiny-skia so the recipes read like the Swift ones: points, y up,
//! rounded rects, gradients, strokes and CoreGraphics-style drop shadows.

use crate::pixel::blur_plane;
use fridge_core::geometry::DoorSpec;
use tiny_skia::{
    Color, FillRule, GradientStop, LineCap, LinearGradient, Mask, Paint, Path, PathBuilder, Pixmap, PixmapPaint, Point,
    RadialGradient, Shader, SpreadMode, Stroke, Transform,
};

pub fn rgba(r: f32, g: f32, b: f32, a: f32) -> Color {
    Color::from_rgba(r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0), a.clamp(0.0, 1.0)).unwrap()
}

pub fn hex(v: u32, a: f32) -> Color {
    rgba(((v >> 16) & 0xFF) as f32 / 255.0, ((v >> 8) & 0xFF) as f32 / 255.0, (v & 0xFF) as f32 / 255.0, a)
}

/// A pixmap of `w x h` points at `scale` with the origin at the bottom left, like `Art.render`.
pub fn canvas(w: f64, h: f64, scale: f32) -> (Pixmap, Transform) {
    let pw = ((w as f32 * scale).round() as u32).max(1);
    let ph = ((h as f32 * scale).round() as u32).max(1);
    let pm = Pixmap::new(pw, ph).unwrap();
    (pm, Transform::from_row(scale, 0.0, 0.0, -scale, 0.0, ph as f32))
}

/// Maps view points (y up) to pixels of a pixmap that covers the frame from pixel (x0, y0).
pub fn frame_transform(scale: f32, frame_h: f32, x0: i32, y0: i32) -> Transform {
    Transform::from_row(scale, 0.0, 0.0, -scale, -(x0 as f32), frame_h - y0 as f32)
}

pub fn rect_path(x: f64, y: f64, w: f64, h: f64) -> Path {
    PathBuilder::from_rect(tiny_skia::Rect::from_xywh(x as f32, y as f32, w.max(0.001) as f32, h.max(0.001) as f32).unwrap())
}

const KAPPA: f32 = 0.552_284_8;

/// Corner radii: bottom left, bottom right, top right, top left (y up).
fn rounded(x: f64, y: f64, w: f64, h: f64, r: [f64; 4]) -> Path {
    let (x, y, w, h) = (x as f32, y as f32, w as f32, h as f32);
    let [bl, br, tr, tl] = r.map(|v| v as f32);
    let mut pb = PathBuilder::new();
    pb.move_to(x, y + bl);
    pb.line_to(x, y + h - tl);
    if tl > 0.0 {
        pb.cubic_to(x, y + h - tl + tl * KAPPA, x + tl - tl * KAPPA, y + h, x + tl, y + h);
    }
    pb.line_to(x + w - tr, y + h);
    if tr > 0.0 {
        pb.cubic_to(x + w - tr + tr * KAPPA, y + h, x + w, y + h - tr + tr * KAPPA, x + w, y + h - tr);
    }
    pb.line_to(x + w, y + br);
    if br > 0.0 {
        pb.cubic_to(x + w, y + br - br * KAPPA, x + w - br + br * KAPPA, y, x + w - br, y);
    }
    pb.line_to(x + bl, y);
    if bl > 0.0 {
        pb.cubic_to(x + bl - bl * KAPPA, y, x, y + bl - bl * KAPPA, x, y + bl);
    }
    pb.close();
    pb.finish().unwrap()
}

/// `CGPath(roundedRect:)`: the radius is clamped to half the shorter side.
pub fn rrect(x: f64, y: f64, w: f64, h: f64, r: f64) -> Path {
    let r = r.min(w.min(h) / 2.0).max(0.0);
    rounded(x, y, w, h, [r; 4])
}

/// `DoorSpec.outline`: only the outer corners are rounded.
pub fn door_outline(spec: &DoorSpec, x: f64, y: f64, w: f64, h: f64, radius: f64) -> Path {
    let r = radius.min(h / 2.0);
    let top = if spec.round_top { r } else { 0.0 };
    let bottom = if spec.round_bottom { r } else { 0.0 };
    rounded(x, y, w, h, [bottom, bottom, top, top])
}

pub fn ellipse(x: f64, y: f64, w: f64, h: f64) -> Option<Path> {
    PathBuilder::from_oval(tiny_skia::Rect::from_xywh(x as f32, y as f32, w as f32, h as f32)?)
}

pub fn polygon(points: &[(f64, f64)]) -> Path {
    let mut pb = PathBuilder::new();
    pb.move_to(points[0].0 as f32, points[0].1 as f32);
    for p in &points[1..] {
        pb.line_to(p.0 as f32, p.1 as f32);
    }
    pb.close();
    pb.finish().unwrap()
}

pub fn line(a: (f64, f64), b: (f64, f64)) -> Path {
    let mut pb = PathBuilder::new();
    pb.move_to(a.0 as f32, a.1 as f32);
    pb.line_to(b.0 as f32, b.1 as f32);
    pb.finish().unwrap()
}

fn paint(shader: Shader<'static>) -> Paint<'static> {
    Paint { shader, anti_alias: true, ..Paint::default() }
}

pub fn fill(pm: &mut Pixmap, path: &Path, color: Color, tf: Transform, mask: Option<&Mask>) {
    let mut p = Paint::default();
    p.set_color(color);
    p.anti_alias = true;
    pm.fill_path(path, &p, FillRule::Winding, tf, mask);
}

fn stops(s: &[(f32, Color)]) -> Vec<GradientStop> {
    s.iter().map(|(t, c)| GradientStop::new(*t, *c)).collect()
}

/// Fills `path` with a linear gradient from `a` to `b` (extended past both ends).
pub fn fill_linear(pm: &mut Pixmap, path: &Path, s: &[(f32, Color)], a: (f64, f64), b: (f64, f64), tf: Transform, mask: Option<&Mask>) {
    let shader = LinearGradient::new(
        Point::from_xy(a.0 as f32, a.1 as f32),
        Point::from_xy(b.0 as f32, b.1 as f32),
        stops(s),
        SpreadMode::Pad,
        Transform::identity(),
    );
    if let Some(shader) = shader {
        pm.fill_path(path, &paint(shader), FillRule::Winding, tf, mask);
    }
}

/// Fills `path` with a radial gradient. `focal` is where stop 0 sits (radius 0); the circle of
/// `radius` round `center` is stop 1. `gtf` maps gradient space into the path's space.
#[allow(clippy::too_many_arguments)]
pub fn fill_radial(
    pm: &mut Pixmap,
    path: &Path,
    s: &[(f32, Color)],
    focal: (f64, f64),
    center: (f64, f64),
    radius: f64,
    gtf: Transform,
    tf: Transform,
    mask: Option<&Mask>,
) {
    let shader = RadialGradient::new(
        Point::from_xy(focal.0 as f32, focal.1 as f32),
        Point::from_xy(center.0 as f32, center.1 as f32),
        radius as f32,
        stops(s),
        SpreadMode::Pad,
        gtf,
    );
    if let Some(shader) = shader {
        pm.fill_path(path, &paint(shader), FillRule::Winding, tf, mask);
    }
}

pub fn stroke(pm: &mut Pixmap, path: &Path, color: Color, width: f64, tf: Transform, mask: Option<&Mask>) {
    stroke_cap(pm, path, color, width, LineCap::Butt, tf, mask);
}

pub fn stroke_cap(pm: &mut Pixmap, path: &Path, color: Color, width: f64, cap: LineCap, tf: Transform, mask: Option<&Mask>) {
    let mut p = Paint::default();
    p.set_color(color);
    p.anti_alias = true;
    let st = Stroke { width: width as f32, line_cap: cap, ..Stroke::default() };
    pm.stroke_path(path, &p, &st, tf, mask);
}

/// A clip mask from a path.
pub fn mask(pm: &Pixmap, path: &Path, tf: Transform) -> Mask {
    let mut m = Mask::new(pm.width(), pm.height()).unwrap();
    m.fill_path(path, FillRule::Winding, true, tf);
    m
}

/// `CGContext.setShadow` around a drawing: `draw` paints into a fresh layer, whose alpha is
/// blurred (sigma = blur / 2), offset (points, y up), tinted and laid down first.
#[allow(clippy::too_many_arguments)]
pub fn with_shadow(
    pm: &mut Pixmap,
    scale: f32,
    offset: (f64, f64),
    blur: f64,
    color: Color,
    mask: Option<&Mask>,
    draw: impl FnOnce(&mut Pixmap),
) {
    let mut layer = Pixmap::new(pm.width(), pm.height()).unwrap();
    draw(&mut layer);
    let shadow = shadow_of(&layer, scale, offset, blur, color);
    pm.draw_pixmap(0, 0, shadow.as_ref(), &PixmapPaint::default(), Transform::identity(), mask);
    pm.draw_pixmap(0, 0, layer.as_ref(), &PixmapPaint::default(), Transform::identity(), mask);
}

/// The blurred, tinted, offset alpha of `layer` as a new pixmap of the same size.
pub fn shadow_of(layer: &Pixmap, scale: f32, offset: (f64, f64), blur: f64, color: Color) -> Pixmap {
    let (w, h) = (layer.width() as usize, layer.height() as usize);
    let mut plane: Vec<f32> = layer.data().chunks_exact(4).map(|p| p[3] as f32 / 255.0).collect();
    blur_plane(&mut plane, w, h, (blur as f32 / 2.0) * scale);
    let dx = (offset.0 as f32 * scale).round() as i64;
    let dy = (-offset.1 as f32 * scale).round() as i64;
    let mut out = Pixmap::new(w as u32, h as u32).unwrap();
    let (r, g, b, a) = (color.red(), color.green(), color.blue(), color.alpha());
    let data = out.data_mut();
    for y in 0..h as i64 {
        let sy = y - dy;
        if sy < 0 || sy >= h as i64 {
            continue;
        }
        for x in 0..w as i64 {
            let sx = x - dx;
            if sx < 0 || sx >= w as i64 {
                continue;
            }
            let k = plane[(sy as usize) * w + sx as usize] * a;
            if k <= 0.0 {
                continue;
            }
            let i = ((y as usize) * w + x as usize) * 4;
            data[i] = (r * k * 255.0 + 0.5) as u8;
            data[i + 1] = (g * k * 255.0 + 0.5) as u8;
            data[i + 2] = (b * k * 255.0 + 0.5) as u8;
            data[i + 3] = (k * 255.0 + 0.5).min(255.0) as u8;
        }
    }
    out
}

/// Draws `src` onto `dst` with an opacity and an optional mask.
pub fn draw_layer(dst: &mut Pixmap, src: &Pixmap, opacity: f32, mask: Option<&Mask>) {
    let p = PixmapPaint { opacity, ..PixmapPaint::default() };
    dst.draw_pixmap(0, 0, src.as_ref(), &p, Transform::identity(), mask);
}
