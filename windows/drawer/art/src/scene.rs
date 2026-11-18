//! The drawer artwork (port of `DrawerView.swift` drawing code, PORT-SPEC section 2).
//!
//! Two static layers, rendered once per scale and theme at the full 780 x 300 point size:
//! - `back`: the box, its walls and the felt floor (no items, no hint text).
//! - `front`: the front panel with its cup pull and the soft shadow it throws onto everything
//!   behind it. Transparent everywhere else.
//!
//! The app draws the items (and the empty-drawer hint) between the two, so only a cheap
//! recomposite is needed when the file list changes. The window then shows the top slice of
//! the result as the drawer slides.

use crate::canvas::{Canvas, Color, Paint, Path, Shadow};
use crate::material::{self, Wood};
use drawer_core::geometry::{
    BOX_RECT, FACE_RECT, FLOOR_BOTTOM, FLOOR_TOP, VIEW_HEIGHT, VIEW_WIDTH, WALL_TOP,
};
use drawer_core::SeededRandom;

/// Light mode: weathered oak front, birch box, green baize, brushed nickel cup pull.
/// Dark mode: old walnut front, walnut box, charcoal felt, aged brass cup pull.
#[derive(Clone, Copy, Debug)]
pub struct Theme {
    pub dark: bool,
    pub front: Wood,
    pub box_wood: Wood,
    pub felt: u32,
    /// Cylinder shading, top to bottom.
    pub metal: [u32; 5],
    pub dust: u32,
    /// Label text alpha (the app draws the labels).
    pub label_alpha: f32,
}

pub const LIGHT: Theme = Theme {
    dark: false,
    front: material::OAK,
    box_wood: material::BIRCH,
    felt: 0x2F4A3B,
    metal: [0x54585A, 0x8F9496, 0xF4F6F6, 0xB4B8BA, 0x4A4D4F],
    dust: 0xE6E0D3,
    label_alpha: 0.95,
};

pub const DARK: Theme = Theme {
    dark: true,
    front: material::WALNUT,
    box_wood: material::WALNUT_PLY,
    felt: 0x2A2A2D,
    metal: [0x4A3510, 0x9C7A34, 0xF3D892, 0xC09A4C, 0x3E2C0E],
    dust: 0xB9B1A2,
    label_alpha: 0.88,
};

/// Empty-drawer hint, drawn by the app: 13 pt semibold system font, black at 38% with a faint
/// white (9%) shadow one point below, centred on `EMPTY_HINT_CENTER_X`, top at `EMPTY_HINT_TOP`.
pub const EMPTY_HINT: &str = "Drop files and folders here";
pub const EMPTY_HINT_CENTER_X: f64 = FACE_RECT.x + FACE_RECT.w / 2.0;
pub const EMPTY_HINT_TOP: f64 = FLOOR_TOP + 92.0;

pub struct Layers {
    pub back: Canvas,
    pub front: Canvas,
}

pub fn render_layers(theme: &Theme, scale: f64) -> Layers {
    Layers {
        back: render_back(theme, scale),
        front: render_front(theme, scale),
    }
}

/// Back, then front, as one picture: what an empty drawer looks like fully open.
pub fn render_preview(theme: &Theme, scale: f64) -> Canvas {
    let mut c = render_back(theme, scale);
    c.draw_canvas(&render_front(theme, scale), 0.0, 0.0);
    c
}

fn col(hex: u32, a: f64) -> Color {
    Color::hex(hex, a as f32)
}
fn black(a: f64) -> Color {
    Color::black(a as f32)
}
fn white(a: f64) -> Color {
    Color::white(a as f32)
}
fn solid(c: Color) -> Paint {
    Paint::Solid(c)
}

// MARK: Cast shadow

/// The soft shadow the drawer throws on the desktop around its visible outline: the front panel
/// plus the slot it slides out of. Only the shadow is drawn (the artwork covers the shape itself),
/// at the full 780 x 300 point size, for a slide `position` from 0 (closed) to 1 (open).
///
/// The shadow grows deeper and softer as the drawer comes out. It depends on the position, so the
/// app keeps a few of these, one per step of position, instead of blurring on every frame; the
/// slot is drawn long enough that cropping the top rows is right for any window height.
pub fn render_cast_shadow(position: f64, scale: f64) -> Canvas {
    let s = drawer_core::geometry::shadow_params(position);
    let f = FACE_RECT;
    let slot_left = drawer_core::geometry::MARGIN + drawer_core::geometry::BOX_INSET;
    let mut shape = Path::rounded_rect(f.x, f.y, f.w, f.h, 4.0);
    shape.extend(&Path::rect(
        slot_left,
        f.max_y() - 2.0,
        drawer_core::geometry::WIDTH - 2.0 * drawer_core::geometry::BOX_INSET,
        VIEW_HEIGHT + 60.0,
    ));
    let mut c = Canvas::new(VIEW_WIDTH, VIEW_HEIGHT, scale);
    c.fill_shadowed(
        &shape,
        &solid(Color::CLEAR),
        Shadow {
            offset: (0.0, s.offset_down),
            blur: s.radius,
            color: black(s.opacity),
        },
    );
    c
}

// MARK: Back: box and floor

pub fn render_back(theme: &Theme, scale: f64) -> Canvas {
    let mut c = Canvas::new(VIEW_WIDTH, VIEW_HEIGHT, scale);
    draw_box(&mut c, theme);
    draw_floor(&mut c, theme);
    c
}

fn draw_box(c: &mut Canvas, theme: &Theme) {
    let b = BOX_RECT;
    let t = WALL_TOP;
    let px = c.px();
    let tex = material::wood(&theme.box_wood, b.w, b.h, c.scale(), 3, false);
    c.draw_canvas(&tex, b.x, b.y);

    // Top edges of the boards catch the light.
    c.fill_rect(b.x, b.y, b.w, b.h, &solid(white(0.10)));

    // Inner faces of the walls: in shade, darker the deeper they go.
    let left = Path::polygon(&[
        (b.min_x() + t, b.min_y()),
        (b.min_x() + t + 9.0, b.min_y()),
        (b.min_x() + t + 5.0, FLOOR_BOTTOM),
        (b.min_x() + t, b.max_y() - t),
    ]);
    let right = Path::polygon(&[
        (b.max_x() - t, b.min_y()),
        (b.max_x() - t - 9.0, b.min_y()),
        (b.max_x() - t - 5.0, FLOOR_BOTTOM),
        (b.max_x() - t, b.max_y() - t),
    ]);
    let back = Path::polygon(&[
        (b.min_x() + t, b.max_y() - t),
        (b.max_x() - t, b.max_y() - t),
        (b.max_x() - t - 5.0, FLOOR_BOTTOM),
        (b.min_x() + t + 5.0, FLOOR_BOTTOM),
    ]);
    c.fill(&left, &solid(black(0.42)));
    c.fill(&right, &solid(black(0.30)));
    c.fill(&back, &solid(black(0.12)));

    // Arrises: a bright line where each board's top meets its inner face, a dark line on the outside.
    let mut arris = Path::new();
    arris
        .move_to((b.min_x() + t, b.min_y()))
        .line_to((b.min_x() + t, b.max_y() - t))
        .line_to((b.max_x() - t, b.max_y() - t))
        .line_to((b.max_x() - t, b.min_y()));
    c.stroke(&arris, px, &solid(white(0.28)));
    let outer = Path::rect(b.x + px / 2.0, b.y + px / 2.0, b.w - px, b.h - px);
    c.stroke(&outer, px, &solid(black(0.45)));
}

/// `(x, y, w, h)` of the floor's bounding box.
fn floor_bounds() -> (f64, f64, f64, f64) {
    let (b, t) = (BOX_RECT, WALL_TOP);
    (
        b.min_x() + t + 5.0,
        FLOOR_TOP,
        b.w - 2.0 * (t + 5.0),
        FLOOR_BOTTOM - FLOOR_TOP,
    )
}

fn floor_path() -> Path {
    let (b, t) = (BOX_RECT, WALL_TOP);
    // The felt floor, narrowing slightly towards the back so the side walls read with perspective.
    Path::polygon(&[
        (b.min_x() + t + 9.0, FLOOR_TOP),
        (b.max_x() - t - 9.0, FLOOR_TOP),
        (b.max_x() - t - 5.0, FLOOR_BOTTOM),
        (b.min_x() + t + 5.0, FLOOR_BOTTOM),
    ])
}

#[derive(Clone, Copy)]
enum Edge {
    MinX,
    MaxX,
    MinY,
    MaxY,
}

fn edge_shade(c: &mut Canvas, r: (f64, f64, f64, f64), edge: Edge, depth: f64, alpha: f64) {
    let (x, y, w, h) = r;
    let (a, b) = match edge {
        Edge::MinX => ((x, 0.0), (x + depth, 0.0)),
        Edge::MaxX => ((x + w, 0.0), (x + w - depth, 0.0)),
        Edge::MinY => ((0.0, y), (0.0, y + depth)),
        Edge::MaxY => ((0.0, y + h), (0.0, y + h - depth)),
    };
    let paint = Paint::Linear {
        from: a,
        to: b,
        stops: vec![
            (0.0, black(alpha)),
            (0.4, black(alpha * 0.3)),
            (1.0, Color::CLEAR),
        ],
    };
    c.fill_rect(x, y, w, h, &paint);
}

fn draw_floor(c: &mut Canvas, theme: &Theme) {
    let fb = floor_bounds();
    let (fx, fy, fw, fh) = fb;
    let scale = c.scale();
    let clip = floor_path();
    c.with_clip(&clip, |c| {
        let felt = material::felt(theme.felt, fw, fh, scale);
        c.draw_canvas(&felt, fx, fy);

        // Soft pool of light from above the desk, falling off towards the walls.
        let light = Paint::radial(
            (fx + fw / 2.0, fy + fh / 2.0 + 10.0),
            fw * 0.55,
            white(if theme.dark { 0.07 } else { 0.09 }),
            Color::CLEAR,
        );
        c.fill_rect(fx, fy, fw, fh, &light);

        // Ambient occlusion along the walls and in the corners.
        edge_shade(c, fb, Edge::MinX, 22.0, 0.40);
        edge_shade(c, fb, Edge::MaxX, 22.0, 0.40);
        edge_shade(c, fb, Edge::MaxY, 18.0, 0.32);
        // The front panel overhangs the near end of the drawer, so that end is in deep shade.
        edge_shade(c, fb, Edge::MinY, 54.0, 0.75);
        for corner in [(fx, fy + fh), (fx + fw, fy + fh), (fx, fy), (fx + fw, fy)] {
            c.fill_rect(
                fx,
                fy,
                fw,
                fh,
                &Paint::radial(corner, 34.0, black(0.30), Color::CLEAR),
            );
        }
        draw_dust(c, fb, theme);
    });
}

fn draw_dust(c: &mut Canvas, fb: (f64, f64, f64, f64), theme: &Theme) {
    let (fx, fy, fw, fh) = fb;
    let (mid_x, mid_y) = (fx + fw / 2.0, fy + fh / 2.0);
    let mut rng = SeededRandom::new(41);
    let corners = [
        (fx, fy + fh),
        (fx + fw, fy + fh),
        (fx, fy + 30.0),
        (fx + fw, fy + 30.0),
    ];
    for corner in corners {
        // faint haze that collects in the corners
        c.fill_rect(
            fx,
            fy,
            fw,
            fh,
            &Paint::radial(corner, 26.0, col(theme.dust, 0.07), Color::CLEAR),
        );
    }
    for _ in 0..260 {
        // specks and lint, mostly near the walls
        let corner = corners[(rng.next_unit() * 4.0) as usize];
        let along = rng.next_unit() < 0.35;
        let dx = if along {
            rng.range(0.0, fw * 0.5)
        } else {
            rng.next_unit().powf(2.2) * 40.0
        };
        let dy = if along {
            rng.next_unit().powf(2.5) * 8.0
        } else {
            rng.next_unit().powf(2.2) * 34.0
        };
        let x = if corner.0 < mid_x {
            corner.0 + dx
        } else {
            corner.0 - dx
        };
        let y = if corner.1 > mid_y {
            corner.1 - dy
        } else {
            corner.1 + dy
        };
        let r = rng.range(0.3, 1.1);
        let alpha = rng.range(0.10, 0.38);
        let len = r * rng.range(1.0, 2.2);
        c.fill(&Path::ellipse(x, y, len, r), &solid(col(theme.dust, alpha)));
    }
    let fibre_paint = solid(col(theme.dust, 0.22)); // a couple of stray fibres
    for _ in 0..7 {
        let x = rng.range(fx + 30.0, fx + fw - 30.0);
        let y = rng.range(fy + 50.0, fy + fh - 8.0);
        let end = (x + rng.range(-9.0, 9.0), y + rng.range(-5.0, 5.0));
        let c1 = (x + rng.range(-6.0, 6.0), y + rng.range(-6.0, 6.0));
        let c2 = (x + rng.range(-6.0, 6.0), y + rng.range(-6.0, 6.0));
        let mut fibre = Path::new();
        fibre.move_to((x, y)).cubic_to(c1, c2, end);
        c.stroke(&fibre, 0.4, &fibre_paint);
    }
}

// MARK: Front: panel, pull and shadow

pub fn render_front(theme: &Theme, scale: f64) -> Canvas {
    let mut c = Canvas::new(VIEW_WIDTH, VIEW_HEIGHT, scale);
    draw_face(&mut c, theme);
    c
}

fn draw_face(c: &mut Canvas, theme: &Theme) {
    let f = FACE_RECT;
    let edge = 5.0;
    let px = c.px();
    let scale = c.scale();
    let dark = theme.dark;
    let body = Path::rounded_rect(f.x, f.y, f.w, f.h, 4.0);

    // Weight: the panel throws a soft shadow down onto the box.
    c.fill_shadowed(
        &body,
        &solid(Color::black(1.0)),
        Shadow {
            offset: (0.0, 6.0),
            blur: 12.0,
            color: black(0.6),
        },
    );

    let front_rect = (f.x, f.y + edge, f.w, f.h - edge);
    c.with_clip(&body, |c| {
        let tex = material::wood(&theme.front, f.w, f.h, scale, 11, true);
        c.draw_canvas(&tex, f.x, f.y);

        // Top of the board: faces the light, so it reads brighter than the front.
        c.fill_rect(
            f.x,
            f.y,
            f.w,
            edge,
            &solid(white(if dark { 0.13 } else { 0.20 })),
        );
        let shade = vec![
            (0.0, white(0.06)),
            (0.35, Color::CLEAR),
            (1.0, black(if dark { 0.30 } else { 0.24 })),
        ];
        c.fill_rect(
            front_rect.0,
            front_rect.1,
            front_rect.2,
            front_rect.3,
            &Paint::linear_in_rect(front_rect, 90.0, shade),
        );

        // Arris between the top and the front.
        c.fill_rect(f.x, front_rect.1, f.w, px, &solid(black(0.30)));
        c.fill_rect(
            f.x,
            f.y,
            f.w,
            px,
            &solid(white(if dark { 0.18 } else { 0.30 })),
        );

        // A faint satin sheen across the varnish.
        let sheen = vec![
            (0.28, Color::CLEAR),
            (0.45, white(if dark { 0.06 } else { 0.08 })),
            (0.62, Color::CLEAR),
        ];
        c.fill_rect(
            front_rect.0,
            front_rect.1,
            front_rect.2,
            front_rect.3,
            &Paint::linear_in_rect(front_rect, -8.0, sheen),
        );

        // Eased edges: lit on the left, shaded on the right and underneath.
        c.fill_rect(
            f.x,
            f.y,
            f.w,
            f.h,
            &Paint::linear((f.x, 0.0), (f.x + 4.0, 0.0), white(0.16), Color::CLEAR),
        );
        c.fill_rect(
            f.x,
            f.y,
            f.w,
            f.h,
            &Paint::linear(
                (f.max_x(), 0.0),
                (f.max_x() - 4.0, 0.0),
                black(0.30),
                Color::CLEAR,
            ),
        );
        c.fill_rect(
            f.x,
            f.y,
            f.w,
            f.h,
            &Paint::linear(
                (0.0, f.max_y()),
                (0.0, f.max_y() - 4.0),
                black(0.55),
                Color::CLEAR,
            ),
        );

        // Years of hands have darkened the wood around the pull.
        let wear = Paint::Radial {
            center: (f.x + f.w / 2.0, front_rect.1 + 17.0),
            radius: 90.0,
            y_squash: 0.42,
            stops: vec![
                (0.0, black(if dark { 0.18 } else { 0.14 })),
                (1.0, Color::CLEAR),
            ],
        };
        c.fill_rect(f.x, f.y, f.w, f.h, &wear);
    });

    let rim = Path::rounded_rect(f.x + px / 2.0, f.y + px / 2.0, f.w - px, f.h - px, 4.0);
    c.stroke(&rim, px, &solid(black(0.5)));

    draw_cup_pull(c, (f.x + f.w / 2.0, front_rect.1 + 9.0), theme);
}

/// A classic bin (cup) pull: a mounting plate with two screws and a hooded cup below it.
fn draw_cup_pull(c: &mut Canvas, p: (f64, f64), theme: &Theme) {
    let px = c.px();
    let m: Vec<Color> = theme.metal.iter().map(|h| col(*h, 1.0)).collect();
    let plate = (p.0 - 56.0, p.1, 112.0, 9.0);
    let plate_path = Path::rounded_rect(plate.0, plate.1, plate.2, plate.3, 3.0);
    let (hood_w, hood_h) = (94.0, 21.0);
    let hood_top = plate.1 + plate.3 - 1.5;
    let mut lip = Path::new();
    lip.move_to((p.0 - hood_w / 2.0, hood_top)).cubic_to(
        (p.0 - hood_w / 2.0 + 3.0, hood_top + hood_h * 1.33),
        (p.0 + hood_w / 2.0 - 3.0, hood_top + hood_h * 1.33),
        (p.0 + hood_w / 2.0, hood_top),
    );
    let mut hood = lip.clone();
    hood.close();

    // Shadows on the wood: the cup stands proud of the panel, the plate sits nearly flush.
    c.fill_shadowed(
        &hood,
        &solid(Color::black(1.0)),
        Shadow {
            offset: (0.0, 7.0),
            blur: 6.0,
            color: black(0.6),
        },
    );
    c.fill_shadowed(
        &plate_path,
        &solid(Color::black(1.0)),
        Shadow {
            offset: (0.0, 1.5),
            blur: 2.0,
            color: black(0.55),
        },
    );

    // Cup: curved surface, dark just under the plate, a bright band, then the lip falls away.
    c.with_clip(&hood, |c| {
        let (x, y, w, h) = (
            p.0 - hood_w / 2.0 - 1.0,
            hood_top - 1.0,
            hood_w + 2.0,
            hood_h * 1.2,
        );
        let vertical = Paint::Linear {
            from: (0.0, hood_top),
            to: (0.0, hood_top + hood_h),
            stops: vec![
                (0.0, m[0]),
                (0.22, m[1]),
                (0.48, m[2]),
                (0.72, m[3]),
                (1.0, m[4]),
            ],
        };
        c.fill_rect(x, y, w, h, &vertical);
        let ends = Paint::Linear {
            from: (p.0 - hood_w / 2.0, 0.0),
            to: (p.0 + hood_w / 2.0, 0.0),
            stops: vec![
                (0.0, black(0.45)),
                (0.22, Color::CLEAR),
                (0.78, Color::CLEAR),
                (1.0, black(0.45)),
            ],
        };
        c.fill_rect(x, y, w, h, &ends);
        let mut rng = SeededRandom::new(17); // brushed finish
        let hair = solid(white(0.05));
        for _ in 0..26 {
            let yy = rng.range(hood_top, hood_top + hood_h);
            let dy = rng.range(-0.4, 0.4);
            c.stroke_line(
                (p.0 - hood_w / 2.0, yy),
                (p.0 + hood_w / 2.0, yy + dy),
                0.4,
                &hair,
            );
        }
    });
    c.stroke(&lip, 0.8, &solid(white(0.45))); // rolled lip catches the light
    c.stroke(&hood, px, &solid(black(0.4)));

    // Plate.
    c.with_clip(&plate_path, |c| {
        let g = Paint::Linear {
            from: (0.0, plate.1),
            to: (0.0, plate.1 + plate.3),
            stops: vec![(0.0, m[2]), (0.35, m[3]), (0.7, m[1]), (1.0, m[4])],
        };
        c.fill_rect(plate.0, plate.1, plate.2, plate.3, &g);
    });
    c.stroke(&plate_path, px, &solid(black(0.45)));

    // Screws, slots at different angles.
    for (x, angle) in [(plate.0 + 7.0, 0.6f64), (plate.0 + plate.2 - 7.0, -0.25)] {
        let (hx, hy) = (x - 2.7, plate.1 + plate.3 / 2.0 - 2.7);
        let head = Path::ellipse(hx, hy, 5.4, 5.4);
        c.fill(
            &head,
            &Paint::linear((0.0, hy), (0.0, hy + 5.4), m[2], m[4]),
        );
        c.stroke(&head, px, &solid(black(0.5)));
        let (cx, cy) = (hx + 2.7, hy + 2.7);
        c.stroke_line(
            (cx - angle.cos() * 2.2, cy - angle.sin() * 2.2),
            (cx + angle.cos() * 2.2, cy + angle.sin() * 2.2),
            0.8,
            &solid(black(0.65)),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn luma(p: [f32; 4]) -> f32 {
        (p[0] + p[1] + p[2]) / 3.0
    }

    #[test]
    fn layers_have_the_artwork_size() {
        let l = render_layers(&LIGHT, 1.0);
        assert_eq!((l.back.width(), l.back.height()), (780, 300));
        assert_eq!((l.front.width(), l.front.height()), (780, 300));
        let l2 = render_layers(&DARK, 1.5);
        assert_eq!((l2.back.width(), l2.back.height()), (1170, 450));
    }

    #[test]
    fn front_is_transparent_outside_and_opaque_on_the_panel() {
        let f = render_front(&LIGHT, 1.0);
        assert_eq!(f.pixel(2, 2)[3], 0.0, "far corner stays clear");
        assert!(f.pixel(390, 45)[3] > 0.999, "panel is opaque");
        assert!(
            f.pixel(390, 82)[3] > 0.05,
            "shadow falls on the box just below the panel"
        );
        assert!(f.pixel(390, 82)[3] < 0.7);
        assert!(
            f.pixel(390, 280)[3] < f.pixel(390, 82)[3],
            "shadow fades with distance"
        );
        assert!(
            f.pixel(f.width() - 3, 150)[3] < 0.01,
            "nothing at the far right edge"
        );
    }

    #[test]
    fn back_is_opaque_inside_the_box_and_clear_outside() {
        let b = render_back(&LIGHT, 1.0);
        assert!(b.pixel(300, 150)[3] > 0.999);
        assert_eq!(b.pixel(5, 150)[3], 0.0);
        assert_eq!(b.pixel(390, 5)[3], 0.0, "above the box");
    }

    #[test]
    fn floor_is_darker_under_the_front_panel_than_in_the_middle() {
        let b = render_back(&LIGHT, 1.0);
        let near = luma(b.pixel(390, 80));
        let middle = luma(b.pixel(390, 170));
        assert!(near < middle, "near end in deep shade: {near} vs {middle}");
    }

    #[test]
    fn dark_theme_is_darker_than_light() {
        let (l, d) = (render_preview(&LIGHT, 1.0), render_preview(&DARK, 1.0));
        assert!(
            luma(d.pixel(390, 45)) < luma(l.pixel(390, 45)),
            "walnut front vs oak front"
        );
        assert!(
            luma(d.pixel(300, 150)) < luma(l.pixel(300, 150)),
            "walnut box vs birch box"
        );
    }

    #[test]
    fn the_cup_pull_is_metal_on_the_wood() {
        let f = render_preview(&LIGHT, 1.0);
        // The bright band of the nickel cup sits a few points below the plate.
        let cx = 390;
        let plate_y = 16 + 5 + 9;
        let band = (plate_y..plate_y + 30)
            .map(|y| luma(f.pixel(cx, y)))
            .fold(0.0f32, f32::max);
        assert!(band > 0.7, "bright metal highlight, got {band}");
        let wood = luma(f.pixel(150, 40));
        assert!(
            wood < 0.75 && wood > 0.2,
            "wood well away from the pull, got {wood}"
        );
    }

    #[test]
    fn cast_shadow_is_soft_and_grows_with_the_slide() {
        let closed = render_cast_shadow(0.0, 1.0);
        let open = render_cast_shadow(1.0, 1.0);
        assert_eq!((closed.width(), closed.height()), (780, 300));
        // Beside the slot, at the height of the panel: a visible shadow, stronger when open.
        let (a0, a1) = (closed.pixel(26, 46)[3], open.pixel(26, 46)[3]);
        assert!(a0 > 0.02 && a0 < 0.5, "closed shadow {a0}");
        assert!(a1 > a0, "open shadow is stronger: {a1} vs {a0}");
        // Far from the drawer: nothing.
        assert!(closed.pixel(2, 150)[3] < 0.01);
        // Down the side of the slot the shadow carries on to the bottom of the artwork.
        assert!(open.pixel(40, 290)[3] > 0.02);
    }

    #[test]
    fn rendering_is_deterministic() {
        let a = render_front(&DARK, 1.0).to_rgba8();
        let b = render_front(&DARK, 1.0).to_rgba8();
        assert_eq!(a, b);
    }
}
