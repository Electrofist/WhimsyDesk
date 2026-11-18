//! What mouse input means for the drawer (PORT-SPEC section 5, "Input"). No Windows calls: the
//! shell passes in screen pixels and gets the drawer's physics back to step.

use drawer_core::geometry::FACE_RECT;
use drawer_core::physics::grab_target_for_window_height;
use drawer_core::DrawerPhysics;

/// What a press on the window did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Press {
    /// Not on the front panel: nothing happens.
    Ignored,
    /// The hand has hold of the drawer: the shell should capture the mouse.
    Grabbed,
    /// Double-click: the drawer was sent sliding open or shut.
    Toggled,
}

pub struct Controller {
    pub physics: DrawerPhysics,
    /// Pixels per point on the monitor the drawer is on.
    scale: f64,
    /// Bottom of that monitor's work area, in screen pixels.
    work_bottom: f64,
    /// Distance from the window's top edge to the mouse when it was pressed, in pixels.
    grab_offset: f64,
}

impl Controller {
    pub fn new(scale: f64, work_bottom: i32) -> Self {
        Self {
            physics: DrawerPhysics::new(),
            scale,
            work_bottom: work_bottom as f64,
            grab_offset: 0.0,
        }
    }

    pub fn set_monitor(&mut self, scale: f64, work_bottom: i32) {
        self.scale = scale;
        self.work_bottom = work_bottom as f64;
    }

    /// Is a window-relative pixel (as in a mouse message) on the front panel? `sag_px` is how far
    /// the artwork is pushed down inside the window.
    pub fn face_hit(&self, client: (i32, i32), sag_px: i32) -> bool {
        let x = client.0 as f64 / self.scale;
        let y = (client.1 - sag_px) as f64 / self.scale;
        FACE_RECT.contains(x, y)
    }

    /// `clicks` is 1 for a press and 2 for the press that completes a double-click.
    /// `screen_y` is the mouse and `window_top` the window's top edge, both in screen pixels.
    pub fn mouse_down(
        &mut self,
        on_face: bool,
        clicks: u32,
        screen_y: f64,
        window_top: f64,
    ) -> Press {
        if !on_face {
            return Press::Ignored;
        }
        if clicks >= 2 {
            self.physics.toggle();
            return Press::Toggled;
        }
        self.physics.begin_grab();
        self.grab_offset = screen_y - window_top;
        Press::Grabbed
    }

    /// The window's top edge follows the mouse; the physics lags behind it like a heavy drawer.
    pub fn mouse_move(&mut self, screen_y: f64) {
        if !self.physics.is_grabbed() {
            return;
        }
        let height_above_bottom = (self.work_bottom - (screen_y - self.grab_offset)) / self.scale;
        self.physics
            .grab_to(grab_target_for_window_height(height_above_bottom));
    }

    /// Let go: the drawer keeps whatever momentum the hand gave it.
    pub fn mouse_up(&mut self) {
        if self.physics.is_grabbed() {
            self.physics.end_grab();
        }
    }

    /// The mouse capture was taken away (another window, a menu): same as letting go.
    pub fn cancel_grab(&mut self) {
        self.mouse_up();
    }

    pub fn is_grabbed(&self) -> bool {
        self.physics.is_grabbed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: f64 = 1.0 / 60.0;

    fn settle(c: &mut Controller) {
        for _ in 0..600 {
            if !c.physics.needs_motion() {
                break;
            }
            c.physics.advance(FRAME);
        }
    }

    #[test]
    fn only_the_front_panel_responds() {
        let c = Controller::new(1.0, 1040);
        assert!(c.face_hit((390, 40), 0));
        assert!(
            !c.face_hit((390, 10), 0),
            "the shadow margin above the panel"
        );
        assert!(!c.face_hit((10, 40), 0), "the margin to the left");
        assert!(!c.face_hit((390, 100), 0), "the box below the panel");
        assert!(
            c.face_hit((390, 41), 1),
            "a sagging drawer shifts the panel down by a pixel"
        );
    }

    #[test]
    fn hit_testing_follows_the_dpi_scale() {
        let c = Controller::new(2.0, 1040);
        assert!(c.face_hit((780, 80), 0));
        assert!(!c.face_hit((780, 20), 0));
    }

    #[test]
    fn a_click_off_the_panel_is_ignored() {
        let mut c = Controller::new(1.0, 1040);
        assert_eq!(c.mouse_down(false, 1, 1000.0, 964.0), Press::Ignored);
        assert!(!c.is_grabbed());
    }

    #[test]
    fn double_click_toggles_open_then_shut() {
        let mut c = Controller::new(1.0, 1040);
        assert_eq!(c.mouse_down(true, 2, 1000.0, 964.0), Press::Toggled);
        assert!(!c.is_grabbed());
        settle(&mut c);
        assert!(
            c.physics.is_interactive(),
            "open at {}",
            c.physics.position()
        );
        assert_eq!(c.mouse_down(true, 2, 800.0, 740.0), Press::Toggled);
        settle(&mut c);
        assert_eq!(c.physics.position(), 0.0);
    }

    #[test]
    fn dragging_the_panel_up_pulls_the_drawer_out_and_it_stays_where_it_was_left() {
        let mut c = Controller::new(1.0, 1040);
        // Press the panel 30 px below the window's top edge (window top = 1040 - 76 = 964).
        assert_eq!(c.mouse_down(true, 1, 994.0, 964.0), Press::Grabbed);
        // Drag up by 112 px: the window grows from 76 to 188 px, which is position 0.5.
        c.mouse_move(994.0 - 112.0);
        for _ in 0..90 {
            c.physics.advance(FRAME);
        }
        assert!(
            (c.physics.position() - 0.5).abs() < 0.02,
            "at {}",
            c.physics.position()
        );
        c.mouse_up();
        assert!(!c.is_grabbed());
        settle(&mut c);
        assert!(
            (c.physics.position() - 0.5).abs() < 0.03,
            "stays put after release: {}",
            c.physics.position()
        );
    }

    #[test]
    fn dragging_down_pushes_it_shut() {
        let mut c = Controller::new(1.0, 1040);
        c.physics = DrawerPhysics::with_state(0.5, 0.0);
        // The window is 188 px tall, its top at 852; grab 20 px below the top and drag down.
        assert_eq!(c.mouse_down(true, 1, 872.0, 852.0), Press::Grabbed);
        c.mouse_move(872.0 + 400.0);
        for _ in 0..120 {
            c.physics.advance(FRAME);
        }
        assert!(
            c.physics.position() < 0.0,
            "pressed into the bumpers while held: {}",
            c.physics.position()
        );
        c.mouse_up();
        settle(&mut c);
        assert_eq!(c.physics.position(), 0.0);
    }

    #[test]
    fn a_fast_flick_carries_on_after_release() {
        let mut c = Controller::new(1.0, 1040);
        c.mouse_down(true, 1, 994.0, 964.0);
        let mut y = 994.0;
        for _ in 0..8 {
            y -= 25.0; // quick pull
            c.mouse_move(y);
            c.physics.advance(FRAME);
        }
        let held = c.physics.position();
        assert!(held < 0.9);
        c.mouse_up();
        assert!(c.physics.velocity() > 0.5);
        settle(&mut c);
        assert!(c.physics.position() > held, "coasted further after release");
    }

    #[test]
    fn losing_the_capture_lets_go() {
        let mut c = Controller::new(1.0, 1040);
        c.mouse_down(true, 1, 994.0, 964.0);
        c.cancel_grab();
        assert!(!c.is_grabbed());
        c.cancel_grab(); // harmless twice
    }

    #[test]
    fn mouse_moves_without_a_grab_do_nothing() {
        let mut c = Controller::new(1.0, 1040);
        c.mouse_move(500.0);
        assert!(!c.physics.needs_motion());
        assert_eq!(c.physics.position(), 0.0);
    }
}
