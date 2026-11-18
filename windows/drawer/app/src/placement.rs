//! Where the window goes on screen (PORT-SPEC section 1).
//!
//! All numbers are physical pixels in Windows virtual-screen coordinates (y down). The drawer is
//! centred on the monitor and rises from the bottom of its work area (above the taskbar). Its
//! window is only as tall as the visible slice of the drawer.

use drawer_core::geometry::{sag, visible_height_px, VIEW_HEIGHT, VIEW_WIDTH};

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
        Self {
            left,
            top,
            right,
            bottom,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Monitor {
    /// The whole monitor.
    pub bounds: RectPx,
    /// Without the taskbar.
    pub work: RectPx,
    /// 1.0 at 96 dpi.
    pub dpi_scale: f64,
    pub primary: bool,
}

pub fn primary(monitors: &[Monitor]) -> Option<&Monitor> {
    monitors
        .iter()
        .find(|m| m.primary)
        .or_else(|| monitors.first())
}

/// The window rectangle for a slide position, plus how far the artwork is pushed down inside it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Placement {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    /// The artwork starts this many pixels below the window's top (a loaded drawer sags a little).
    pub sag_px: i32,
}

pub fn placement(monitor: &Monitor, position: f64, has_items: bool) -> Placement {
    let scale = monitor.dpi_scale;
    let w = (VIEW_WIDTH * scale).round() as i32;
    let h = visible_height_px(position, scale);
    let centre = (monitor.bounds.left + monitor.bounds.right) as f64 / 2.0;
    Placement {
        x: (centre - w as f64 / 2.0).round() as i32,
        y: monitor.work.bottom - h,
        w,
        h,
        sag_px: (sag(has_items) * scale).round() as i32,
    }
}

/// Height of the fully open drawer's window; the off-screen bitmap is allocated this tall once.
pub fn max_height_px(scale: f64) -> i32 {
    (VIEW_HEIGHT * scale).round() as i32
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
    fn closed_drawer_sits_centred_on_the_taskbar() {
        let p = placement(&monitor(1.0), 0.0, false);
        assert_eq!((p.w, p.h), (780, 76));
        assert_eq!(p.x, (1920 - 780) / 2);
        assert_eq!(
            p.y + p.h,
            1040,
            "bottom edge on the bottom of the work area"
        );
        assert_eq!(p.sag_px, 0);
    }

    #[test]
    fn open_drawer_grows_upwards_only() {
        let (closed, open) = (
            placement(&monitor(1.0), 0.0, false),
            placement(&monitor(1.0), 1.0, false),
        );
        assert_eq!(open.h, 300);
        assert_eq!(open.y + open.h, closed.y + closed.h);
        assert_eq!(open.x, closed.x);
    }

    #[test]
    fn scales_with_dpi_and_loaded_drawer_sags() {
        let p = placement(&monitor(1.5), 0.0, true);
        assert_eq!((p.w, p.h), (1170, 114));
        assert_eq!(p.sag_px, 2, "1.5 pt at 1.5x rounds to 2 px");
        assert_eq!(max_height_px(1.5), 450);
        assert_eq!(placement(&monitor(1.5), 1.0, true).h, 450);
    }

    #[test]
    fn centred_on_the_monitor_not_the_work_area() {
        let m = Monitor {
            bounds: RectPx::new(1920, 0, 3840, 1080),
            work: RectPx::new(1920, 0, 3700, 1080),
            dpi_scale: 1.0,
            primary: false,
        };
        let p = placement(&m, 0.0, false);
        assert_eq!(p.x, 1920 + (1920 - 780) / 2);
        assert_eq!(p.y, 1080 - 76);
    }

    #[test]
    fn pressed_into_the_bumpers_the_window_shrinks_but_stays_on_the_bottom() {
        let p = placement(&monitor(1.0), -0.05, false);
        assert!(p.h < 76 && p.h >= 24);
        assert_eq!(p.y + p.h, 1040);
    }

    #[test]
    fn primary_monitor_is_found() {
        let a = Monitor {
            primary: false,
            ..monitor(1.0)
        };
        let b = Monitor {
            primary: true,
            dpi_scale: 2.0,
            ..monitor(1.0)
        };
        assert_eq!(primary(&[a, b]).unwrap().dpi_scale, 2.0);
        assert_eq!(
            primary(&[a]).unwrap().dpi_scale,
            1.0,
            "falls back to the first"
        );
        assert!(primary(&[]).is_none());
    }
}
