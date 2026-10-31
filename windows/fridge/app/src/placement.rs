//! Where the window goes on screen. PORT-SPEC §1.
//!
//! All numbers here are physical pixels in Windows virtual screen coordinates (y down).
//! The window is drawn at `s = dpi scale × user scale` pixels per design point.

use fridge_core::geometry::{BODY_ORIGIN, BODY_SIZE, WINDOW_SIZE};

/// A screen rectangle, left/top inclusive, right/bottom exclusive, like a Win32 RECT.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RectPx {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl RectPx {
    pub fn new(left: i32, top: i32, right: i32, bottom: i32) -> Self {
        Self { left, top, right, bottom }
    }
    pub fn intersects(&self, o: &RectPx) -> bool {
        self.left < o.right && o.left < self.right && self.top < o.bottom && o.top < self.bottom
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Monitor {
    /// Whole monitor.
    pub bounds: RectPx,
    /// Without the taskbar.
    pub work: RectPx,
    /// 1.0 at 96 dpi.
    pub dpi_scale: f64,
    pub primary: bool,
}

/// The fridge's feet in view (design) coordinates, y up: bottom centre of the body.
pub const FEET: (f64, f64) = (BODY_ORIGIN.x + BODY_SIZE.0 / 2.0, BODY_ORIGIN.y);

/// The feet measured from the window's top-left, in design points, y down.
pub fn feet_from_top_left() -> (f64, f64) {
    (FEET.0, WINDOW_SIZE.1 - FEET.1)
}

/// Window size in pixels at a total scale.
pub fn window_size(scale: f64) -> (i32, i32) {
    ((WINDOW_SIZE.0 * scale).round().max(1.0) as i32, (WINDOW_SIZE.1 * scale).round().max(1.0) as i32)
}

/// Screen position of the feet for a window at `origin` drawn at `scale`.
pub fn feet_on_screen(origin: (i32, i32), scale: f64) -> (f64, f64) {
    let (fx, fy) = feet_from_top_left();
    (origin.0 as f64 + fx * scale, origin.1 as f64 + fy * scale)
}

/// Window origin that puts the feet on a screen point.
pub fn origin_for_feet(feet: (f64, f64), scale: f64) -> (i32, i32) {
    let (fx, fy) = feet_from_top_left();
    ((feet.0 - fx * scale).round() as i32, (feet.1 - fy * scale).round() as i32)
}

/// Resizing keeps the feet planted.
pub fn rescale_origin(origin: (i32, i32), old_scale: f64, new_scale: f64) -> (i32, i32) {
    origin_for_feet(feet_on_screen(origin, old_scale), new_scale)
}

/// The fridge body on screen.
pub fn body_rect(origin: (i32, i32), scale: f64) -> RectPx {
    let top_in_window = WINDOW_SIZE.1 - BODY_ORIGIN.y - BODY_SIZE.1;
    let left = origin.0 as f64 + BODY_ORIGIN.x * scale;
    let top = origin.1 as f64 + top_in_window * scale;
    RectPx::new(
        left.floor() as i32,
        top.floor() as i32,
        (left + BODY_SIZE.0 * scale).ceil() as i32,
        (top + BODY_SIZE.1 * scale).ceil() as i32,
    )
}

/// True when some of the body is on a monitor.
pub fn body_visible(origin: (i32, i32), scale: f64, monitors: &[Monitor]) -> bool {
    let body = body_rect(origin, scale);
    monitors.iter().any(|m| m.bounds.intersects(&body))
}

/// Default spot on a monitor's work area: the body's right edge 36 pt in from the right at design
/// size and the feet 24 pt above the bottom (the Mac places it at design size and then grows it
/// around the feet, so the feet sit 176 pt from the right whatever the size).
pub fn default_origin(monitor: &Monitor, user_scale: f64) -> (i32, i32) {
    let d = monitor.dpi_scale;
    let right_of_feet = WINDOW_SIZE.0 - (WINDOW_SIZE.0 - BODY_ORIGIN.x - BODY_SIZE.0) - FEET.0 + 36.0;
    // = 470 - 330 + 36 = 176 design points from the right edge of the work area.
    let feet = (monitor.work.right as f64 - right_of_feet * d, monitor.work.bottom as f64 - 24.0 * d);
    origin_for_feet(feet, d * user_scale)
}

pub fn primary(monitors: &[Monitor]) -> Option<&Monitor> {
    monitors.iter().find(|m| m.primary).or_else(|| monitors.first())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(dpi: f64) -> Monitor {
        Monitor {
            bounds: RectPx::new(0, 0, 1920, 1080),
            work: RectPx::new(0, 0, 1920, 1040),
            dpi_scale: dpi,
            primary: true,
        }
    }

    #[test]
    fn size_rounds() {
        assert_eq!(window_size(1.0), (520, 800));
        assert_eq!(window_size(1.25), (650, 1000));
        assert_eq!(window_size(0.45), (234, 360));
    }

    #[test]
    fn default_spot_matches_the_mac_numbers() {
        let m = monitor(1.0);
        let o = default_origin(&m, 1.0);
        // Body right edge 36 from the work area's right edge, feet 24 above its bottom.
        let body = body_rect(o, 1.0);
        assert_eq!(body.right, 1920 - 36);
        let feet = feet_on_screen(o, 1.0);
        assert!((feet.1 - (1040.0 - 24.0)).abs() < 0.5);
    }

    #[test]
    fn default_spot_scales_around_the_feet() {
        let m = monitor(1.5);
        let small = feet_on_screen(default_origin(&m, 0.5), 1.5 * 0.5);
        let big = feet_on_screen(default_origin(&m, 1.6), 1.5 * 1.6);
        assert!((small.0 - big.0).abs() <= 1.0 && (small.1 - big.1).abs() <= 1.0);
        assert!((small.0 - (1920.0 - 176.0 * 1.5)).abs() <= 1.0);
    }

    #[test]
    fn rescale_keeps_feet_planted() {
        let o = (300, 100);
        let f0 = feet_on_screen(o, 1.0);
        let o2 = rescale_origin(o, 1.0, 1.4);
        let f1 = feet_on_screen(o2, 1.4);
        assert!((f0.0 - f1.0).abs() <= 0.5 && (f0.1 - f1.1).abs() <= 0.5);
    }

    #[test]
    fn visibility() {
        let ms = [monitor(1.0)];
        assert!(body_visible((100, 100), 1.0, &ms));
        // Window hangs off the right but the body is still on screen.
        assert!(body_visible((1920 - 200, 100), 1.0, &ms));
        // Body fully off screen even though some window pixels are on it.
        assert!(!body_visible((1920 - 190, 100), 1.0, &ms));
        assert!(!body_visible((5000, 5000), 1.0, &ms));
    }
}
