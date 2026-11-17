//! Fixed measurements of the drawer artwork and window (PORT-SPEC sections 1 and 3).
//! Design points, origin top-left, y down.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }
    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    /// Left and top edges inclusive, right and bottom edges exclusive (like `NSRect.contains`).
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h
    }
    /// Shrinks the rectangle by `dx` / `dy` on each side (negative values grow it).
    pub fn inset_by(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(
            self.x + dx,
            self.y + dy,
            self.w - 2.0 * dx,
            self.h - 2.0 * dy,
        )
    }
}

pub const WIDTH: f64 = 720.0;
pub const FACE_HEIGHT: f64 = 60.0;
pub const INTERIOR_HEIGHT: f64 = 224.0;
pub const TOTAL_HEIGHT: f64 = FACE_HEIGHT + INTERIOR_HEIGHT;
/// Room around the drawer for its soft shadow.
pub const MARGIN: f64 = 30.0;
pub const TOP_PAD: f64 = 16.0;
/// The box is a little narrower than the front panel.
pub const BOX_INSET: f64 = 16.0;
pub const VIEW_WIDTH: f64 = WIDTH + MARGIN * 2.0;
pub const VIEW_HEIGHT: f64 = TOP_PAD + TOTAL_HEIGHT;

pub const FACE_RECT: Rect = Rect::new(MARGIN, TOP_PAD, WIDTH, FACE_HEIGHT);
pub const BOX_RECT: Rect = Rect::new(
    MARGIN + BOX_INSET,
    TOP_PAD + FACE_HEIGHT - 8.0,
    WIDTH - BOX_INSET * 2.0,
    INTERIOR_HEIGHT + 8.0,
);
/// Visible top edge of the side and back boards.
pub const WALL_TOP: f64 = 5.0;
pub const FLOOR_TOP: f64 = TOP_PAD + FACE_HEIGHT;
pub const FLOOR_BOTTOM: f64 = TOP_PAD + FACE_HEIGHT - 8.0 + INTERIOR_HEIGHT + 8.0 - WALL_TOP - 5.0;

/// A loaded drawer sits a touch lower on its runners.
pub const SAG_WHEN_LOADED: f64 = 1.5;

pub fn sag(has_items: bool) -> f64 {
    if has_items {
        SAG_WHEN_LOADED
    } else {
        0.0
    }
}

/// Height of the visible slice of the drawer, in points, for a slide position (0 closed, 1 open).
/// The window is this tall; the artwork is pinned to its top, `sag` points down.
pub fn visible_height(position: f64) -> f64 {
    (TOP_PAD + FACE_HEIGHT + position * INTERIOR_HEIGHT).max(TOP_PAD + 8.0)
}

/// Same, rounded to whole device pixels at `scale` (pixels per point), returned in pixels.
pub fn visible_height_px(position: f64, scale: f64) -> i32 {
    (visible_height(position) * scale).round() as i32
}

/// Distance from the bottom of the window up to the bottom of the front panel, in points.
/// Zero or negative when the panel's lower edge is at or below the window bottom.
pub fn face_bottom_above_window_bottom(window_height: f64, sag: f64) -> f64 {
    window_height - TOP_PAD - sag - FACE_HEIGHT
}

/// Soft contact shadow on the desktop, deeper and softer the further the drawer is pulled out.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShadowParams {
    pub radius: f64,
    pub opacity: f64,
    /// Pixels the shadow is shifted DOWN.
    pub offset_down: f64,
}

pub fn shadow_params(position: f64) -> ShadowParams {
    let p = position.clamp(0.0, 1.0);
    ShadowParams {
        radius: 7.0 + 9.0 * p,
        opacity: 0.34 + 0.16 * p,
        offset_down: 3.0 + 5.0 * p,
    }
}

/// Height of the dark gradient inside the cabinet slot, where the drawer disappears into it.
pub fn cabinet_shade_height(face_bottom: f64) -> f64 {
    face_bottom.clamp(0.0, 60.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_numbers() {
        assert_eq!(VIEW_WIDTH, 780.0);
        assert_eq!(VIEW_HEIGHT, 300.0);
        assert_eq!(FACE_RECT, Rect::new(30.0, 16.0, 720.0, 60.0));
        assert_eq!(BOX_RECT, Rect::new(46.0, 68.0, 688.0, 232.0));
        assert_eq!(FLOOR_TOP, 76.0);
        assert_eq!(FLOOR_BOTTOM, 290.0);
    }

    #[test]
    fn visible_height_runs_from_closed_to_open() {
        assert_eq!(visible_height(0.0), 76.0);
        assert_eq!(visible_height(1.0), 300.0);
        assert_eq!(visible_height(0.5), 188.0);
        // Pressed into the bumpers it never gets smaller than the top padding plus 8.
        assert_eq!(visible_height(-0.05), 76.0 - 11.2);
        assert_eq!(visible_height(-1.0), 24.0);
    }

    #[test]
    fn pixel_height_rounds() {
        assert_eq!(visible_height_px(0.0, 1.5), 114);
        assert_eq!(visible_height_px(1.0, 2.0), 600);
    }

    #[test]
    fn shadow_grows_with_position() {
        let closed = shadow_params(0.0);
        let open = shadow_params(1.0);
        assert_eq!((closed.radius, open.radius), (7.0, 16.0));
        assert!((closed.opacity - 0.34).abs() < 1e-12 && (open.opacity - 0.5).abs() < 1e-12);
        assert_eq!((closed.offset_down, open.offset_down), (3.0, 8.0));
        assert_eq!(
            shadow_params(-0.05),
            closed,
            "bumper overshoot does not change the shadow"
        );
    }

    #[test]
    fn rect_contains_is_half_open() {
        let r = Rect::new(10.0, 10.0, 5.0, 5.0);
        assert!(r.contains(10.0, 10.0));
        assert!(!r.contains(15.0, 12.0));
        assert!(r.inset_by(-4.0, -4.0).contains(6.0, 6.0));
    }

    #[test]
    fn face_bottom_follows_window_height() {
        assert_eq!(face_bottom_above_window_bottom(76.0, 0.0), 0.0);
        assert_eq!(
            face_bottom_above_window_bottom(300.0, 1.5),
            300.0 - 16.0 - 1.5 - 60.0
        );
        assert_eq!(cabinet_shade_height(500.0), 60.0);
        assert_eq!(cabinet_shade_height(-3.0), 0.0);
    }
}
