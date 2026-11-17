//! A small software canvas: premultiplied float RGBA, anti-aliased paths, gradients, clipping and
//! blurred shadows. It does only what the drawer's artwork needs (the Mac app draws with AppKit).
//!
//! Coordinates are design points, origin top-left, y down, like the flipped Swift view. The canvas
//! multiplies by `scale` (device pixels per point) when it rasterizes.

use std::rc::Rc;

pub type P = (f64, f64);

/// Straight (not premultiplied) colour, each channel 0 to 1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Color {
    pub const CLEAR: Color = Color {
        r: 0.0,
        g: 0.0,
        b: 0.0,
        a: 0.0,
    };

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }
    /// `0xRRGGBB` with an alpha.
    pub fn hex(hex: u32, a: f32) -> Self {
        Self {
            r: ((hex >> 16) & 0xFF) as f32 / 255.0,
            g: ((hex >> 8) & 0xFF) as f32 / 255.0,
            b: (hex & 0xFF) as f32 / 255.0,
            a,
        }
    }
    pub fn black(a: f32) -> Self {
        Self {
            r: 0.0,
            g: 0.0,
            b: 0.0,
            a,
        }
    }
    pub fn white(a: f32) -> Self {
        Self {
            r: 1.0,
            g: 1.0,
            b: 1.0,
            a,
        }
    }
    fn premul(self) -> [f32; 4] {
        [self.r * self.a, self.g * self.a, self.b * self.a, self.a]
    }
}

/// Where the colour of a fill comes from.
#[derive(Clone, Debug)]
pub enum Paint {
    Solid(Color),
    /// Along the line `from` to `to`; before `from` and after `to` the end colours continue.
    Linear {
        from: P,
        to: P,
        stops: Vec<(f32, Color)>,
    },
    /// From `center` out to `radius`; `y_squash` < 1 makes it an ellipse (0.42 = flattened).
    Radial {
        center: P,
        radius: f64,
        y_squash: f64,
        stops: Vec<(f32, Color)>,
    },
}

impl Paint {
    pub fn linear(from: P, to: P, a: Color, b: Color) -> Paint {
        Paint::Linear {
            from,
            to,
            stops: vec![(0.0, a), (1.0, b)],
        }
    }

    /// Like `NSGradient.draw(in:angle:)`: the gradient line crosses the rectangle `(x, y, w, h)`
    /// at `angle_degrees` (0 = left to right, 90 = top to bottom in y-down coordinates).
    pub fn linear_in_rect(
        rect: (f64, f64, f64, f64),
        angle_degrees: f64,
        stops: Vec<(f32, Color)>,
    ) -> Paint {
        let (x, y, w, h) = rect;
        let a = angle_degrees.to_radians();
        let (dx, dy) = (a.cos(), a.sin());
        let half = (w * dx.abs() + h * dy.abs()) / 2.0;
        let (cx, cy) = (x + w / 2.0, y + h / 2.0);
        Paint::Linear {
            from: (cx - dx * half, cy - dy * half),
            to: (cx + dx * half, cy + dy * half),
            stops,
        }
    }

    pub fn radial(center: P, radius: f64, a: Color, b: Color) -> Paint {
        Paint::Radial {
            center,
            radius,
            y_squash: 1.0,
            stops: vec![(0.0, a), (1.0, b)],
        }
    }

    /// Premultiplied colour at a point (in points).
    fn eval(&self, x: f64, y: f64) -> [f32; 4] {
        match self {
            Paint::Solid(c) => c.premul(),
            Paint::Linear { from, to, stops } => {
                let (dx, dy) = (to.0 - from.0, to.1 - from.1);
                let len2 = dx * dx + dy * dy;
                let t = if len2 == 0.0 {
                    0.0
                } else {
                    ((x - from.0) * dx + (y - from.1) * dy) / len2
                };
                sample_stops(stops, t.clamp(0.0, 1.0) as f32)
            }
            Paint::Radial {
                center,
                radius,
                y_squash,
                stops,
            } => {
                let (dx, dy) = (x - center.0, (y - center.1) / y_squash);
                let t = (dx * dx + dy * dy).sqrt() / radius;
                sample_stops(stops, t.clamp(0.0, 1.0) as f32)
            }
        }
    }
}

fn sample_stops(stops: &[(f32, Color)], t: f32) -> [f32; 4] {
    if t <= stops[0].0 {
        return stops[0].1.premul();
    }
    for w in stops.windows(2) {
        let ((t0, c0), (t1, c1)) = (w[0], w[1]);
        if t <= t1 {
            let u = if t1 > t0 { (t - t0) / (t1 - t0) } else { 1.0 };
            let (a, b) = (c0.premul(), c1.premul());
            return [
                a[0] + (b[0] - a[0]) * u,
                a[1] + (b[1] - a[1]) * u,
                a[2] + (b[2] - a[2]) * u,
                a[3] + (b[3] - a[3]) * u,
            ];
        }
    }
    stops[stops.len() - 1].1.premul()
}

#[derive(Clone, Copy, Debug)]
pub struct Shadow {
    /// Points the shadow is shifted (positive y = down).
    pub offset: P,
    /// Like `NSShadow.shadowBlurRadius`; the Gaussian sigma is half of it.
    pub blur: f64,
    pub color: Color,
}

// MARK: Paths

#[derive(Clone, Debug, Default)]
pub struct Path {
    subs: Vec<(Vec<P>, bool)>,
}

const CURVE_STEPS: usize = 14;

impl Path {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn move_to(&mut self, p: P) -> &mut Self {
        self.subs.push((vec![p], false));
        self
    }
    pub fn line_to(&mut self, p: P) -> &mut Self {
        if let Some((pts, _)) = self.subs.last_mut() {
            pts.push(p);
        } else {
            self.move_to(p);
        }
        self
    }
    pub fn cubic_to(&mut self, c1: P, c2: P, end: P) -> &mut Self {
        let start = self
            .subs
            .last()
            .and_then(|(p, _)| p.last().copied())
            .unwrap_or(end);
        for i in 1..=CURVE_STEPS {
            let t = i as f64 / CURVE_STEPS as f64;
            let u = 1.0 - t;
            let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
            self.line_to((
                a * start.0 + b * c1.0 + c * c2.0 + d * end.0,
                a * start.1 + b * c1.1 + c * c2.1 + d * end.1,
            ));
        }
        self
    }
    pub fn close(&mut self) -> &mut Self {
        if let Some((_, closed)) = self.subs.last_mut() {
            *closed = true;
        }
        self
    }

    pub fn polygon(points: &[P]) -> Path {
        let mut p = Path::new();
        for (i, pt) in points.iter().enumerate() {
            if i == 0 {
                p.move_to(*pt);
            } else {
                p.line_to(*pt);
            }
        }
        p.close();
        p
    }

    pub fn rect(x: f64, y: f64, w: f64, h: f64) -> Path {
        Path::polygon(&[(x, y), (x + w, y), (x + w, y + h), (x, y + h)])
    }

    pub fn rounded_rect(x: f64, y: f64, w: f64, h: f64, r: f64) -> Path {
        const K: f64 = 0.552_284_75;
        let r = r.min(w / 2.0).min(h / 2.0);
        let k = r * K;
        let mut p = Path::new();
        p.move_to((x + r, y));
        p.line_to((x + w - r, y));
        p.cubic_to((x + w - r + k, y), (x + w, y + r - k), (x + w, y + r));
        p.line_to((x + w, y + h - r));
        p.cubic_to(
            (x + w, y + h - r + k),
            (x + w - r + k, y + h),
            (x + w - r, y + h),
        );
        p.line_to((x + r, y + h));
        p.cubic_to((x + r - k, y + h), (x, y + h - r + k), (x, y + h - r));
        p.line_to((x, y + r));
        p.cubic_to((x, y + r - k), (x + r - k, y), (x + r, y));
        p.close();
        p
    }

    pub fn ellipse(x: f64, y: f64, w: f64, h: f64) -> Path {
        const N: usize = 24;
        let (cx, cy, rx, ry) = (x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0);
        let pts: Vec<P> = (0..N)
            .map(|i| {
                let a = i as f64 / N as f64 * std::f64::consts::TAU;
                (cx + rx * a.cos(), cy + ry * a.sin())
            })
            .collect();
        Path::polygon(&pts)
    }

    /// Bounding box `(min_x, min_y, max_x, max_y)` of all points.
    pub fn bounds(&self) -> (f64, f64, f64, f64) {
        let mut b = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        for (pts, _) in &self.subs {
            for p in pts {
                b = (b.0.min(p.0), b.1.min(p.1), b.2.max(p.0), b.3.max(p.1));
            }
        }
        b
    }

    /// Outline polygons that cover a line of `width` along this path (mitred joins, flat ends).
    fn stroke_outlines(&self, width: f64) -> Vec<Vec<P>> {
        let half = width / 2.0;
        let mut out = Vec::new();
        for (pts, closed) in &self.subs {
            let mut pts: Vec<P> = pts.clone();
            pts.dedup_by(|a, b| (a.0 - b.0).abs() < 1e-9 && (a.1 - b.1).abs() < 1e-9);
            if *closed && pts.len() > 1 && pts.first() == pts.last() {
                pts.pop();
            }
            let n = pts.len();
            if n < 2 {
                continue;
            }
            let segs = if *closed { n } else { n - 1 };
            let normal = |i: usize| {
                let (a, b) = (pts[i], pts[(i + 1) % n]);
                let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                let l = (dx * dx + dy * dy).sqrt().max(1e-12);
                (-dy / l, dx / l)
            };
            let offset = |i: usize| -> P {
                let prev = if i > 0 {
                    Some(normal(i - 1))
                } else if *closed {
                    Some(normal(segs - 1))
                } else {
                    None
                };
                let next = if i < segs { Some(normal(i)) } else { None };
                let (n1, n2) = match (prev, next) {
                    (Some(a), Some(b)) => (a, b),
                    (Some(a), None) => (a, a),
                    (None, Some(b)) => (b, b),
                    (None, None) => unreachable!(),
                };
                let (mx, my) = (n1.0 + n2.0, n1.1 + n2.1);
                let ml = (mx * mx + my * my).sqrt();
                if ml < 1e-9 {
                    return (n1.0 * half, n1.1 * half);
                }
                let (mx, my) = (mx / ml, my / ml);
                let k = 1.0 / (mx * n1.0 + my * n1.1).max(0.5);
                (mx * half * k, my * half * k)
            };
            let offs: Vec<P> = (0..n).map(offset).collect();
            let left: Vec<P> = (0..n)
                .map(|i| (pts[i].0 + offs[i].0, pts[i].1 + offs[i].1))
                .collect();
            let right: Vec<P> = (0..n)
                .map(|i| (pts[i].0 - offs[i].0, pts[i].1 - offs[i].1))
                .collect();
            if *closed {
                out.push(left);
                out.push(right.into_iter().rev().collect());
            } else {
                let mut ring = left;
                ring.extend(right.into_iter().rev());
                out.push(ring);
            }
        }
        out
    }
}

// MARK: Coverage

/// Anti-aliased coverage of a shape, in device pixels, over a bounding box that may reach
/// outside the canvas.
#[derive(Clone, Debug)]
struct Coverage {
    x0: i64,
    y0: i64,
    w: usize,
    h: usize,
    data: Vec<f32>,
}

/// Signed-area accumulation rasterizer (exact coverage for non-overlapping shapes).
fn rasterize(rings: &[Vec<P>], scale: f64) -> Option<Coverage> {
    let (mut minx, mut miny, mut maxx, mut maxy) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for ring in rings {
        for p in ring {
            minx = minx.min(p.0 * scale);
            maxx = maxx.max(p.0 * scale);
            miny = miny.min(p.1 * scale);
            maxy = maxy.max(p.1 * scale);
        }
    }
    if minx > maxx || miny > maxy {
        return None;
    }
    let x0 = minx.floor() as i64 - 1;
    let y0 = miny.floor() as i64;
    let w = (maxx.ceil() as i64 + 1 - x0) as usize;
    let h = (maxy.ceil() as i64 + 1 - y0) as usize;
    if w == 0 || h == 0 || w * h > 60_000_000 {
        return None;
    }
    let stride = w + 3;
    let mut acc = vec![0.0f32; stride * h];
    for ring in rings {
        let n = ring.len();
        if n < 2 {
            continue;
        }
        for i in 0..n {
            let a = (ring[i].0 * scale - x0 as f64, ring[i].1 * scale - y0 as f64);
            let b = (
                ring[(i + 1) % n].0 * scale - x0 as f64,
                ring[(i + 1) % n].1 * scale - y0 as f64,
            );
            accumulate_line(&mut acc, stride, h, a, b);
        }
    }
    let mut data = vec![0.0f32; w * h];
    for y in 0..h {
        let mut sum = 0.0f32;
        for x in 0..w {
            sum += acc[y * stride + x];
            data[y * w + x] = sum.abs().min(1.0);
        }
    }
    Some(Coverage { x0, y0, w, h, data })
}

fn accumulate_line(a: &mut [f32], stride: usize, h: usize, p0: P, p1: P) {
    if p0.1 == p1.1 {
        return;
    }
    let (dir, p0, p1) = if p0.1 < p1.1 {
        (1.0f64, p0, p1)
    } else {
        (-1.0f64, p1, p0)
    };
    let dxdy = (p1.0 - p0.0) / (p1.1 - p0.1);
    let mut x = p0.0;
    let y_start = p0.1.max(0.0) as usize;
    if p0.1 < 0.0 {
        x -= p0.1 * dxdy;
    }
    let y_end = h.min(p1.1.ceil() as usize);
    for y in y_start..y_end {
        let line = y * stride;
        let dy = ((y + 1) as f64).min(p1.1) - (y as f64).max(p0.1);
        let xnext = x + dxdy * dy;
        let d = dy * dir;
        let (x0, x1) = if x < xnext { (x, xnext) } else { (xnext, x) };
        let x0floor = x0.floor();
        let x0i = x0floor as i64;
        let x1ceil = x1.ceil();
        let x1i = x1ceil as i64;
        let mut add = |xi: i64, v: f64| {
            let idx = line + xi.max(0) as usize;
            if idx < a.len() {
                a[idx] += v as f32;
            }
        };
        if x1i <= x0i + 1 {
            let xmf = 0.5 * (x + xnext) - x0floor;
            add(x0i, d - d * xmf);
            add(x0i + 1, d * xmf);
        } else {
            let s = 1.0 / (x1 - x0);
            let x0f = x0 - x0floor;
            let a0 = 0.5 * s * (1.0 - x0f) * (1.0 - x0f);
            let x1f = x1 - x1ceil + 1.0;
            let am = 0.5 * s * x1f * x1f;
            add(x0i, d * a0);
            if x1i == x0i + 2 {
                add(x0i + 1, d * (1.0 - a0 - am));
            } else {
                let a1 = s * (1.5 - x0f);
                add(x0i + 1, d * (a1 - a0));
                for xi in x0i + 2..x1i - 1 {
                    add(xi, d * s);
                }
                let a2 = a1 + (x1i - x0i - 3) as f64 * s;
                add(x1i - 1, d * (1.0 - a2 - am));
            }
            add(x1i, d * am);
        }
        x = xnext;
    }
}

/// Gaussian-like blur from three box passes. `sigma` is in device pixels.
fn blur(cov: &Coverage, sigma: f64) -> Coverage {
    if sigma < 0.3 {
        return cov.clone();
    }
    let width = (12.0 * sigma * sigma / 3.0 + 1.0).sqrt();
    let r = (((width - 1.0) / 2.0).round() as usize).max(1);
    let pad = 3 * r + 1;
    let (w, h) = (cov.w + 2 * pad, cov.h + 2 * pad);
    let mut data = vec![0.0f32; w * h];
    for y in 0..cov.h {
        data[(y + pad) * w + pad..(y + pad) * w + pad + cov.w]
            .copy_from_slice(&cov.data[y * cov.w..(y + 1) * cov.w]);
    }
    for _ in 0..3 {
        box_blur(&mut data, w, h, r, true);
        box_blur(&mut data, w, h, r, false);
    }
    Coverage {
        x0: cov.x0 - pad as i64,
        y0: cov.y0 - pad as i64,
        w,
        h,
        data,
    }
}

#[allow(clippy::needless_range_loop)] // the index also drives the sliding window
fn box_blur(data: &mut [f32], w: usize, h: usize, r: usize, horizontal: bool) {
    let (lines, len, step, line_step) = if horizontal {
        (h, w, 1, w)
    } else {
        (w, h, w, 1)
    };
    let norm = 1.0 / (2 * r + 1) as f32;
    let mut tmp = vec![0.0f32; len];
    for l in 0..lines {
        let base = l * line_step;
        let at = |i: usize| data[base + i * step];
        let mut sum: f32 = (0..=r.min(len - 1)).map(at).sum();
        for i in 0..len {
            tmp[i] = sum * norm;
            if i + r + 1 < len {
                sum += at(i + r + 1);
            }
            if i >= r {
                sum -= at(i - r);
            }
        }
        for (i, v) in tmp.iter().enumerate() {
            data[base + i * step] = *v;
        }
    }
}

// MARK: Canvas

#[derive(Clone)]
pub struct Canvas {
    width: usize,
    height: usize,
    scale: f64,
    /// Premultiplied RGBA, four floats per pixel, top row first.
    data: Vec<f32>,
    clip: Option<Rc<Vec<f32>>>,
}

impl Canvas {
    /// A transparent canvas of `width_pt` x `height_pt` points at `scale` pixels per point.
    pub fn new(width_pt: f64, height_pt: f64, scale: f64) -> Self {
        let width = (width_pt * scale).round().max(1.0) as usize;
        let height = (height_pt * scale).round().max(1.0) as usize;
        Self {
            width,
            height,
            scale,
            data: vec![0.0; width * height * 4],
            clip: None,
        }
    }

    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
    pub fn scale(&self) -> f64 {
        self.scale
    }
    /// One device pixel, in points.
    pub fn px(&self) -> f64 {
        1.0 / self.scale
    }
    /// Premultiplied RGBA of one pixel.
    pub fn pixel(&self, x: usize, y: usize) -> [f32; 4] {
        let i = (y * self.width + x) * 4;
        [
            self.data[i],
            self.data[i + 1],
            self.data[i + 2],
            self.data[i + 3],
        ]
    }

    fn composite(&mut self, cov: &Coverage, paint: &Paint) {
        let solid = if let Paint::Solid(c) = paint {
            Some(c.premul())
        } else {
            None
        };
        for cy in 0..cov.h {
            let py = cov.y0 + cy as i64;
            if py < 0 || py >= self.height as i64 {
                continue;
            }
            for cx in 0..cov.w {
                let px = cov.x0 + cx as i64;
                if px < 0 || px >= self.width as i64 {
                    continue;
                }
                let mut c = cov.data[cy * cov.w + cx];
                if c < 0.0005 {
                    continue;
                }
                let idx = py as usize * self.width + px as usize;
                if let Some(clip) = &self.clip {
                    c *= clip[idx];
                    if c < 0.0005 {
                        continue;
                    }
                }
                let src = solid.unwrap_or_else(|| {
                    paint.eval(
                        (px as f64 + 0.5) / self.scale,
                        (py as f64 + 0.5) / self.scale,
                    )
                });
                let sa = src[3] * c;
                let d = &mut self.data[idx * 4..idx * 4 + 4];
                let inv = 1.0 - sa;
                d[0] = src[0] * c + d[0] * inv;
                d[1] = src[1] * c + d[1] * inv;
                d[2] = src[2] * c + d[2] * inv;
                d[3] = sa + d[3] * inv;
            }
        }
    }

    fn rings(path: &Path) -> Vec<Vec<P>> {
        path.subs.iter().map(|(p, _)| p.clone()).collect()
    }

    pub fn fill(&mut self, path: &Path, paint: &Paint) {
        if let Some(cov) = rasterize(&Self::rings(path), self.scale) {
            self.composite(&cov, paint);
        }
    }

    pub fn fill_rect(&mut self, x: f64, y: f64, w: f64, h: f64, paint: &Paint) {
        self.fill(&Path::rect(x, y, w, h), paint);
    }

    /// Fills the shape and, beneath it, its blurred shadow (like drawing with an `NSShadow` set).
    pub fn fill_shadowed(&mut self, path: &Path, paint: &Paint, shadow: Shadow) {
        if let Some(cov) = rasterize(&Self::rings(path), self.scale) {
            let mut s = blur(&cov, shadow.blur / 2.0 * self.scale);
            s.x0 += (shadow.offset.0 * self.scale).round() as i64;
            s.y0 += (shadow.offset.1 * self.scale).round() as i64;
            self.composite(&s, &Paint::Solid(shadow.color));
            self.composite(&cov, paint);
        }
    }

    pub fn stroke(&mut self, path: &Path, width: f64, paint: &Paint) {
        if let Some(cov) = rasterize(&path.stroke_outlines(width), self.scale) {
            self.composite(&cov, paint);
        }
    }

    pub fn stroke_line(&mut self, a: P, b: P, width: f64, paint: &Paint) {
        let mut p = Path::new();
        p.move_to(a).line_to(b);
        self.stroke(&p, width, paint);
    }

    /// Runs `f` with drawing limited to `path` (intersected with any clip already set).
    pub fn with_clip(&mut self, path: &Path, f: impl FnOnce(&mut Canvas)) {
        let mut mask = vec![0.0f32; self.width * self.height];
        if let Some(cov) = rasterize(&Self::rings(path), self.scale) {
            for cy in 0..cov.h {
                let py = cov.y0 + cy as i64;
                if py < 0 || py >= self.height as i64 {
                    continue;
                }
                for cx in 0..cov.w {
                    let px = cov.x0 + cx as i64;
                    if px >= 0 && px < self.width as i64 {
                        let i = py as usize * self.width + px as usize;
                        mask[i] =
                            cov.data[cy * cov.w + cx] * self.clip.as_ref().map_or(1.0, |c| c[i]);
                    }
                }
            }
        }
        let saved = self.clip.replace(Rc::new(mask));
        f(self);
        self.clip = saved;
    }

    /// Source-over blit of another canvas with its top-left corner at `(x, y)` points
    /// (rounded to whole pixels). Both canvases should use the same scale.
    pub fn draw_canvas(&mut self, src: &Canvas, x: f64, y: f64) {
        let (ox, oy) = (
            (x * self.scale).round() as i64,
            (y * self.scale).round() as i64,
        );
        for sy in 0..src.height {
            let py = oy + sy as i64;
            if py < 0 || py >= self.height as i64 {
                continue;
            }
            for sx in 0..src.width {
                let px = ox + sx as i64;
                if px < 0 || px >= self.width as i64 {
                    continue;
                }
                let s = &src.data[(sy * src.width + sx) * 4..(sy * src.width + sx) * 4 + 4];
                if s[3] <= 0.0 {
                    continue;
                }
                let idx = py as usize * self.width + px as usize;
                let c = self.clip.as_ref().map_or(1.0, |m| m[idx]);
                if c <= 0.0 {
                    continue;
                }
                let d = &mut self.data[idx * 4..idx * 4 + 4];
                let inv = 1.0 - s[3] * c;
                for k in 0..4 {
                    d[k] = s[k] * c + d[k] * inv;
                }
            }
        }
    }

    /// Adds seeded per-pixel luminance noise, so flat fills never look like vector art.
    /// `rng` yields values in `[0, 1)`. Meant for opaque canvases.
    pub fn add_noise(&mut self, amount: f64, mut rng: impl FnMut() -> f64) {
        for px in self.data.chunks_exact_mut(4) {
            let n = ((rng() - 0.5) * amount) as f32 * px[3];
            for c in &mut px[..3] {
                *c = (*c + n).clamp(0.0, 1.0);
            }
        }
    }

    /// Premultiplied BGRA, 8 bits per channel: what `UpdateLayeredWindow` wants.
    pub fn to_bgra8_premultiplied(&self) -> Vec<u8> {
        let q = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
        self.data
            .chunks_exact(4)
            .flat_map(|p| [q(p[2]), q(p[1]), q(p[0]), q(p[3])])
            .collect()
    }

    /// Straight RGBA, 8 bits per channel (for PNG files).
    pub fn to_rgba8(&self) -> Vec<u8> {
        let q = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
        self.data
            .chunks_exact(4)
            .flat_map(|p| {
                if p[3] <= 0.0 {
                    [0, 0, 0, 0]
                } else {
                    [q(p[0] / p[3]), q(p[1] / p[3]), q(p[2] / p[3]), q(p[3])]
                }
            })
            .collect()
    }

    pub fn to_png(&self) -> Vec<u8> {
        crate::png::encode_png(self.width, self.height, &self.to_rgba8())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alpha(c: &Canvas, x: usize, y: usize) -> f32 {
        c.pixel(x, y)[3]
    }

    #[test]
    fn a_pixel_aligned_rect_covers_exactly_its_pixels() {
        let mut c = Canvas::new(10.0, 10.0, 1.0);
        c.fill_rect(2.0, 3.0, 4.0, 2.0, &Paint::Solid(Color::black(1.0)));
        assert_eq!(alpha(&c, 2, 3), 1.0);
        assert_eq!(alpha(&c, 5, 4), 1.0);
        assert_eq!(alpha(&c, 6, 4), 0.0);
        assert_eq!(alpha(&c, 1, 3), 0.0);
        assert_eq!(alpha(&c, 3, 5), 0.0);
    }

    #[test]
    fn half_covered_pixels_get_half_alpha() {
        let mut c = Canvas::new(10.0, 10.0, 1.0);
        c.fill_rect(2.5, 2.0, 3.0, 4.0, &Paint::Solid(Color::black(1.0)));
        assert!((alpha(&c, 2, 3) - 0.5).abs() < 0.01);
        assert!((alpha(&c, 5, 3) - 0.5).abs() < 0.01);
        assert!((alpha(&c, 3, 3) - 1.0).abs() < 0.01);
    }

    #[test]
    fn scale_multiplies_points_into_pixels() {
        let mut c = Canvas::new(10.0, 10.0, 2.0);
        assert_eq!((c.width(), c.height()), (20, 20));
        c.fill_rect(1.0, 1.0, 2.0, 2.0, &Paint::Solid(Color::white(1.0)));
        assert_eq!(alpha(&c, 2, 2), 1.0);
        assert_eq!(alpha(&c, 5, 5), 1.0);
        assert_eq!(alpha(&c, 6, 6), 0.0);
    }

    #[test]
    fn a_circle_has_about_the_right_area() {
        let mut c = Canvas::new(40.0, 40.0, 1.0);
        c.fill(
            &Path::ellipse(5.0, 5.0, 30.0, 30.0),
            &Paint::Solid(Color::black(1.0)),
        );
        let area: f32 = (0..40)
            .flat_map(|y| (0..40).map(move |x| (x, y)))
            .map(|(x, y)| alpha(&c, x, y))
            .sum();
        let expect = std::f32::consts::PI * 15.0 * 15.0;
        assert!(
            (area - expect).abs() / expect < 0.02,
            "area {area} vs {expect}"
        );
    }

    #[test]
    fn shapes_hanging_off_the_canvas_are_cut_cleanly() {
        let mut c = Canvas::new(10.0, 10.0, 1.0);
        c.fill_rect(-20.0, -20.0, 100.0, 100.0, &Paint::Solid(Color::black(1.0)));
        assert_eq!(alpha(&c, 0, 0), 1.0);
        assert_eq!(alpha(&c, 9, 9), 1.0);
        c.fill(
            &Path::polygon(&[(-5.0, 5.0), (15.0, 2.0), (15.0, 8.0)]),
            &Paint::Solid(Color::white(1.0)),
        );
    }

    #[test]
    fn source_over_blends_premultiplied_colour() {
        let mut c = Canvas::new(2.0, 1.0, 1.0);
        c.fill_rect(0.0, 0.0, 1.0, 1.0, &Paint::Solid(Color::black(0.5)));
        c.fill_rect(0.0, 0.0, 1.0, 1.0, &Paint::Solid(Color::white(0.5)));
        let p = c.pixel(0, 0);
        assert!((p[3] - 0.75).abs() < 1e-5, "alpha {}", p[3]);
        assert!(
            (p[0] - 0.5).abs() < 1e-5,
            "premultiplied white 0.5 over black 0.5 is 0.5, got {}",
            p[0]
        );
    }

    #[test]
    fn linear_gradient_runs_between_its_end_points() {
        let mut c = Canvas::new(10.0, 1.0, 1.0);
        let g = Paint::linear(
            (0.0, 0.0),
            (10.0, 0.0),
            Color::black(1.0),
            Color::white(1.0),
        );
        c.fill_rect(0.0, 0.0, 10.0, 1.0, &g);
        assert!(c.pixel(0, 0)[0] < 0.1);
        assert!(c.pixel(9, 0)[0] > 0.9);
        assert!((c.pixel(4, 0)[0] - 0.45).abs() < 0.05);
    }

    #[test]
    fn angled_rect_gradient_spans_the_rect() {
        let p = Paint::linear_in_rect(
            (0.0, 0.0, 10.0, 20.0),
            90.0,
            vec![(0.0, Color::black(1.0)), (1.0, Color::white(1.0))],
        );
        assert!(p.eval(5.0, 0.0)[0] < 0.01);
        assert!(p.eval(5.0, 20.0)[0] > 0.99);
        assert!((p.eval(5.0, 10.0)[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn radial_gradient_fades_to_clear_at_its_radius() {
        let p = Paint::radial((0.0, 0.0), 10.0, Color::black(0.5), Color::CLEAR);
        assert!((p.eval(0.0, 0.0)[3] - 0.5).abs() < 1e-6);
        assert!(p.eval(10.0, 0.0)[3] < 1e-6);
        assert!(p.eval(50.0, 0.0)[3] < 1e-6);
        let squashed = Paint::Radial {
            center: (0.0, 0.0),
            radius: 10.0,
            y_squash: 0.5,
            stops: vec![(0.0, Color::black(1.0)), (1.0, Color::CLEAR)],
        };
        assert!(
            squashed.eval(0.0, 5.0)[3] < 1e-6,
            "half the radius vertically is already the edge"
        );
    }

    #[test]
    fn clip_limits_drawing() {
        let mut c = Canvas::new(10.0, 10.0, 1.0);
        c.with_clip(&Path::rect(0.0, 0.0, 5.0, 10.0), |c| {
            c.fill_rect(0.0, 0.0, 10.0, 10.0, &Paint::Solid(Color::black(1.0)));
        });
        assert_eq!(alpha(&c, 4, 5), 1.0);
        assert_eq!(alpha(&c, 5, 5), 0.0);
        c.fill_rect(5.0, 0.0, 5.0, 10.0, &Paint::Solid(Color::black(1.0)));
        assert_eq!(alpha(&c, 7, 5), 1.0, "the clip ends with the closure");
    }

    #[test]
    fn blur_spreads_but_keeps_the_total() {
        let mut c = Canvas::new(60.0, 60.0, 1.0);
        let shadow = Shadow {
            offset: (0.0, 0.0),
            blur: 12.0,
            color: Color::black(1.0),
        };
        c.fill_shadowed(
            &Path::rect(25.0, 25.0, 10.0, 10.0),
            &Paint::Solid(Color::CLEAR),
            shadow,
        );
        let total: f32 = (0..60)
            .flat_map(|y| (0..60).map(move |x| (x, y)))
            .map(|(x, y)| alpha(&c, x, y))
            .sum();
        assert!((total - 100.0).abs() < 3.0, "total {total}");
        assert!(alpha(&c, 30, 30) < 1.0 && alpha(&c, 30, 30) > 0.1);
        assert!(alpha(&c, 30, 22) > 0.0, "spread above the shape");
        assert!(alpha(&c, 0, 0) < 0.01);
    }

    #[test]
    fn shadow_offset_moves_it_down() {
        let mut c = Canvas::new(60.0, 60.0, 1.0);
        let shadow = Shadow {
            offset: (0.0, 10.0),
            blur: 4.0,
            color: Color::black(1.0),
        };
        c.fill_shadowed(
            &Path::rect(25.0, 15.0, 10.0, 10.0),
            &Paint::Solid(Color::CLEAR),
            shadow,
        );
        assert!(alpha(&c, 30, 40) > alpha(&c, 30, 8));
    }

    #[test]
    fn strokes_have_the_asked_width() {
        let mut c = Canvas::new(20.0, 10.0, 1.0);
        c.stroke_line(
            (2.0, 5.0),
            (18.0, 5.0),
            2.0,
            &Paint::Solid(Color::black(1.0)),
        );
        assert!((alpha(&c, 10, 4) - 1.0).abs() < 0.01 && (alpha(&c, 10, 5) - 1.0).abs() < 0.01);
        assert_eq!(alpha(&c, 10, 3), 0.0);
        assert_eq!(alpha(&c, 10, 6), 0.0);
    }

    #[test]
    fn a_closed_stroke_leaves_the_middle_empty() {
        let mut c = Canvas::new(30.0, 30.0, 1.0);
        let mut p = Path::rect(5.0, 5.0, 20.0, 20.0);
        p.close();
        c.stroke(&p, 2.0, &Paint::Solid(Color::black(1.0)));
        assert!(alpha(&c, 5, 15) > 0.9, "left edge");
        assert_eq!(alpha(&c, 15, 15), 0.0, "inside stays clear");
        assert_eq!(alpha(&c, 1, 15), 0.0, "outside stays clear");
    }

    #[test]
    fn rounded_rect_cuts_its_corners() {
        let mut c = Canvas::new(30.0, 30.0, 1.0);
        c.fill(
            &Path::rounded_rect(5.0, 5.0, 20.0, 20.0, 6.0),
            &Paint::Solid(Color::black(1.0)),
        );
        assert!(alpha(&c, 5, 5) < 0.2, "corner pixel is mostly empty");
        assert_eq!(alpha(&c, 15, 15), 1.0);
        assert!(alpha(&c, 5, 15) > 0.99);
    }

    #[test]
    fn output_formats() {
        let mut c = Canvas::new(2.0, 1.0, 1.0);
        c.fill_rect(
            0.0,
            0.0,
            1.0,
            1.0,
            &Paint::Solid(Color::rgba(1.0, 0.0, 0.0, 0.5)),
        );
        assert_eq!(&c.to_bgra8_premultiplied()[0..4], &[0, 0, 128, 128]);
        assert_eq!(&c.to_rgba8()[0..4], &[255, 0, 0, 128]);
        assert_eq!(&c.to_rgba8()[4..8], &[0, 0, 0, 0]);
        assert_eq!(&c.to_png()[1..4], b"PNG");
    }
}
