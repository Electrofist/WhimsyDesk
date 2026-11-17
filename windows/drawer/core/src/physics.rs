//! The sliding drawer (PORT-SPEC section 5). Port of the physics in `DrawerController.swift`.
//!
//! `position` runs from 0 (closed) to 1 (fully open); slightly negative means pressed into the
//! soft-close bumpers. `velocity` is in full travels per second. The model owns no clock and no
//! window: the app calls `advance(frame_time)` while `needs_motion()` is true and plays the
//! knocks it returns. At rest nothing needs to run.

use crate::geometry::{FACE_HEIGHT, INTERIOR_HEIGHT, TOP_PAD};
use crate::sound::KnockKind;

/// Items are usable and drops are accepted from this far open.
pub const INTERACTIVE_THRESHOLD: f64 = 0.6;
/// Below this an unattended drawer is pulled shut.
pub const DRIFT_ZONE: f64 = 0.16;
pub const DRIFT_ACCEL: f64 = 0.9;
/// Greased runners: velocity decay per second.
pub const VISCOUS: f64 = 3.0;
/// Dry wood-on-wood friction, travels per second squared.
pub const COULOMB: f64 = 1.2;
/// Felt bumpers at the back of the cabinet.
pub const BUMPER_STIFFNESS: f64 = 1500.0;
pub const BUMPER_DAMPING: f64 = 48.0;
pub const BUMPER_LIMIT: f64 = -0.05;
/// Rebound off the stop block at full extension.
pub const STOP_RESTITUTION: f64 = 0.22;
/// Hand to drawer coupling: it lags like something heavy.
pub const HAND_STIFFNESS: f64 = 240.0;
pub const HAND_DAMPING: f64 = 27.0;
/// Knocks closer together than this are dropped.
pub const MIN_KNOCK_GAP: f64 = 0.35;

/// Frame time limits and integration substeps per second (the bumpers are stiff).
const MIN_FRAME: f64 = 1.0 / 240.0;
const MAX_FRAME: f64 = 1.0 / 20.0;
const SUBSTEPS_PER_SECOND: f64 = 480.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Knock {
    pub kind: KnockKind,
    /// 0 to 1, applied by the player.
    pub volume: f32,
}

#[derive(Clone, Debug)]
pub struct DrawerPhysics {
    position: f64,
    velocity: f64,
    grabbed: bool,
    grab_target: f64,
    drag_in_progress: bool,
    battery_saver: bool,
    suspended: bool,
    /// Simulated seconds, used only to rate-limit knocks.
    clock: f64,
    last_knock: f64,
}

impl Default for DrawerPhysics {
    fn default() -> Self {
        Self::new()
    }
}

/// Initial speed that coasts exactly `d` travels under viscous plus dry friction (bisection on the
/// closed-form stopping distance of dv/dt = -k*v - c).
pub fn launch_speed(d: f64) -> f64 {
    let (mut lo, mut hi) = (0.0f64, 30.0f64);
    for _ in 0..40 {
        let mid = (lo + hi) / 2.0;
        if stopping_distance(mid) < d {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    hi
}

/// How far a drawer launched at speed `v` coasts before friction stops it.
pub fn stopping_distance(v: f64) -> f64 {
    let (k, c) = (VISCOUS, COULOMB);
    v / k - (c / (k * k)) * (1.0 + k * v / c).ln()
}

/// Slide position the hand asks for, given how far the window's top edge is above the bottom of
/// the work area (points). Clamped to -0.02 ... 1.
pub fn grab_target_for_window_height(height_above_bottom: f64) -> f64 {
    ((height_above_bottom - TOP_PAD - FACE_HEIGHT) / INTERIOR_HEIGHT).clamp(-0.02, 1.0)
}

impl DrawerPhysics {
    pub fn new() -> Self {
        Self {
            position: 0.0,
            velocity: 0.0,
            grabbed: false,
            grab_target: 0.0,
            drag_in_progress: false,
            battery_saver: false,
            suspended: false,
            clock: 0.0,
            last_knock: f64::NEG_INFINITY,
        }
    }

    /// For tests and for restoring a state.
    pub fn with_state(position: f64, velocity: f64) -> Self {
        Self {
            position,
            velocity,
            ..Self::new()
        }
    }

    pub fn position(&self) -> f64 {
        self.position
    }
    pub fn velocity(&self) -> f64 {
        self.velocity
    }
    pub fn is_grabbed(&self) -> bool {
        self.grabbed
    }
    pub fn is_suspended(&self) -> bool {
        self.suspended
    }

    /// Items usable and drops accepted.
    pub fn is_interactive(&self) -> bool {
        self.position >= INTERACTIVE_THRESHOLD
    }

    /// A barely-open drawer nobody is touching is pulled shut.
    pub fn drift_active(&self) -> bool {
        self.position > 0.0
            && self.position < DRIFT_ZONE
            && !self.drag_in_progress
            && !self.grabbed
            && !self.battery_saver
    }

    /// True while the frame clock must run. At rest this is false and nothing should be scheduled.
    pub fn needs_motion(&self) -> bool {
        if self.suspended {
            return false;
        }
        if self.grabbed {
            return (self.grab_target - self.position).abs() > 0.0005
                || self.velocity.abs() > 0.001;
        }
        self.velocity != 0.0 || self.drift_active() || self.position < 0.0
    }

    /// Speed that drives the slide rumble: zero for a parked drawer.
    pub fn slide_speed(&self) -> f64 {
        if self.grabbed || self.position > 0.0 {
            self.velocity.abs()
        } else {
            0.0
        }
    }

    // MARK: User input

    /// Catching a moving drawer: the hand takes over from where it is.
    pub fn begin_grab(&mut self) {
        self.grabbed = true;
        self.grab_target = self.position;
    }

    /// Where the hand wants the drawer (see `grab_target_for_window_height`).
    pub fn grab_to(&mut self, target: f64) {
        if self.grabbed {
            self.grab_target = target.clamp(-0.02, 1.0);
        }
    }

    /// The drawer keeps whatever momentum the hand gave it.
    pub fn end_grab(&mut self) {
        self.grabbed = false;
        self.velocity = self.velocity.clamp(-6.0, 6.0);
    }

    /// Double-click on the front panel.
    pub fn toggle(&mut self) {
        if self.suspended {
            return;
        }
        self.velocity = if self.position > 0.5 {
            -launch_speed(self.position + 0.05)
        } else {
            launch_speed(1.0 - self.position + 0.04)
        };
    }

    /// A file hovering over the closed drawer pulls it open (like a spring-loaded folder).
    pub fn open_for_drag(&mut self) {
        if self.position < INTERACTIVE_THRESHOLD {
            self.velocity = self.velocity.max(launch_speed(1.0 - self.position + 0.03));
        }
    }

    /// True while a file drag hovers over the drawer or is being pulled out of it.
    /// The drawer never moves toward closed while this is set.
    pub fn set_drag_in_progress(&mut self, on: bool) {
        self.drag_in_progress = on;
        if on && self.velocity < 0.0 {
            self.velocity = 0.0;
        }
    }

    /// Windows battery saver: no drift, and the app should pace frames at 30 fps.
    pub fn set_battery_saver(&mut self, on: bool) {
        self.battery_saver = on;
    }

    /// Screen locked, system asleep or display off: freeze exactly where it is, force nothing shut.
    pub fn set_suspended(&mut self, on: bool) {
        self.suspended = on;
        if on {
            self.velocity = 0.0;
            if self.position < 0.0 {
                self.position = 0.0;
            }
        }
    }

    /// A drop finished: a soft knock (subject to the same rate limit as the others).
    pub fn items_dropped(&mut self) -> Option<Knock> {
        let mut out = Vec::new();
        self.knock(KnockKind::Close, 0.25, &mut out);
        out.pop()
    }

    // MARK: Time

    /// Advances by one display frame of `frame_time` seconds and returns the knocks to play.
    pub fn advance(&mut self, frame_time: f64) -> Vec<Knock> {
        let mut knocks = Vec::new();
        if self.suspended {
            return knocks;
        }
        let dt = frame_time.clamp(MIN_FRAME, MAX_FRAME);
        let substeps = (dt * SUBSTEPS_PER_SECOND).ceil().max(1.0) as usize;
        let h = dt / substeps as f64;
        for _ in 0..substeps {
            self.step(h, &mut knocks);
        }
        knocks
    }

    fn knock(&mut self, kind: KnockKind, volume: f32, out: &mut Vec<Knock>) {
        if self.suspended {
            return;
        }
        if self.clock - self.last_knock > MIN_KNOCK_GAP {
            self.last_knock = self.clock;
            out.push(Knock { kind, volume });
        }
    }

    fn step(&mut self, dt: f64, knocks: &mut Vec<Knock>) {
        self.clock += dt;
        let was_out = self.position >= 0.0;

        if self.grabbed {
            self.velocity += (HAND_STIFFNESS * (self.grab_target - self.position)
                - HAND_DAMPING * self.velocity)
                * dt;
        } else {
            self.velocity *= (-VISCOUS * dt).exp();
            if self.drift_active() {
                self.velocity -= DRIFT_ACCEL * dt; // soft-close pull when left barely open
            } else if self.position > 0.0 && self.velocity != 0.0 {
                let dv = COULOMB * dt;
                self.velocity = if self.velocity.abs() <= dv {
                    0.0
                } else if self.velocity > 0.0 {
                    self.velocity - dv
                } else {
                    self.velocity + dv
                };
            }
            if self.drag_in_progress && self.velocity < 0.0 {
                self.velocity = 0.0; // never close during a drag
            }
        }
        if self.position < 0.0 {
            // pressed into the felt bumpers
            self.velocity +=
                (-BUMPER_STIFFNESS * self.position - BUMPER_DAMPING * self.velocity) * dt;
        }

        self.position += self.velocity * dt;

        if was_out && self.position < 0.0 && self.velocity < 0.0 {
            // front panel meets the cabinet
            let volume = (0.1 + -self.velocity * 0.16).min(0.6) as f32;
            self.knock(KnockKind::Close, volume, knocks);
        }
        if self.position < BUMPER_LIMIT {
            self.position = BUMPER_LIMIT;
            self.velocity = self.velocity.max(0.0);
        }
        if self.position >= 1.0 {
            // stop block at full extension: knock, small rebound
            self.position = 1.0;
            if self.velocity > 0.0 {
                if self.velocity > 0.12 {
                    let volume = (0.08 + self.velocity * 0.14).min(0.45) as f32;
                    self.knock(KnockKind::Open, volume, knocks);
                }
                self.velocity = if self.grabbed {
                    0.0
                } else {
                    -self.velocity * STOP_RESTITUTION
                };
            }
        }

        if self.grabbed {
            return;
        }
        if self.position.abs() < 0.002 && self.velocity.abs() < 0.05 {
            // settled shut
            self.position = 0.0;
            self.velocity = 0.0;
        } else if self.position > 0.0 && !self.drift_active() && self.velocity.abs() < 0.004 {
            self.velocity = 0.0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: f64 = 1.0 / 60.0;

    /// Runs frames until the drawer needs no more motion (or `max_seconds` pass).
    fn run_until_rest(p: &mut DrawerPhysics, max_seconds: f64) -> (Vec<Knock>, f64) {
        let mut knocks = Vec::new();
        let mut t = 0.0;
        while p.needs_motion() && t < max_seconds {
            knocks.extend(p.advance(FRAME));
            t += FRAME;
        }
        (knocks, t)
    }

    #[test]
    fn a_closed_drawer_needs_nothing() {
        let p = DrawerPhysics::new();
        assert!(!p.needs_motion());
        assert!(!p.is_interactive());
        assert_eq!(p.slide_speed(), 0.0);
    }

    #[test]
    fn launch_speed_coasts_the_asked_distance() {
        for d in [0.2, 0.5, 1.04, 1.05, 1.5] {
            let v = launch_speed(d);
            assert!((stopping_distance(v) - d).abs() < 1e-6, "d {d} v {v}");
        }
        assert!(launch_speed(1.04) > launch_speed(0.5));
    }

    #[test]
    fn toggle_opens_a_closed_drawer_and_parks_it_open() {
        let mut p = DrawerPhysics::new();
        p.toggle();
        assert!(p.needs_motion());
        let (knocks, t) = run_until_rest(&mut p, 10.0);
        assert!(t < 10.0, "it should come to rest");
        assert!(
            p.position() > 0.9 && p.position() <= 1.0,
            "parked open at {}",
            p.position()
        );
        assert_eq!(p.velocity(), 0.0);
        assert!(p.is_interactive());
        assert!(!p.needs_motion());
        assert!(
            knocks.iter().any(|k| k.kind == KnockKind::Open),
            "knock against the stop block"
        );
    }

    #[test]
    fn toggle_closes_an_open_drawer_with_a_close_knock() {
        let mut p = DrawerPhysics::with_state(1.0, 0.0);
        p.toggle();
        let (knocks, t) = run_until_rest(&mut p, 10.0);
        assert!(t < 10.0);
        assert_eq!(p.position(), 0.0);
        assert_eq!(p.velocity(), 0.0);
        assert!(knocks.iter().any(|k| k.kind == KnockKind::Close));
        assert!(knocks.iter().all(|k| (0.0..=0.6).contains(&k.volume)));
    }

    #[test]
    fn knocks_are_rate_limited() {
        let mut p = DrawerPhysics::new();
        assert!(p.items_dropped().is_some());
        assert!(
            p.items_dropped().is_none(),
            "second knock inside 0.35 s is dropped"
        );
        for _ in 0..30 {
            p.advance(FRAME); // half a second of simulated time passes
        }
        assert!(p.items_dropped().is_some());
    }

    #[test]
    fn a_barely_open_drawer_drifts_shut() {
        let mut p = DrawerPhysics::with_state(0.1, 0.0);
        assert!(p.drift_active() && p.needs_motion());
        let (_, t) = run_until_rest(&mut p, 10.0);
        assert!(t < 10.0);
        assert_eq!(p.position(), 0.0);
    }

    #[test]
    fn drift_is_off_in_battery_saver_and_during_a_file_drag() {
        let mut p = DrawerPhysics::with_state(0.1, 0.0);
        p.set_battery_saver(true);
        assert!(!p.drift_active() && !p.needs_motion());
        p.set_battery_saver(false);
        p.set_drag_in_progress(true);
        assert!(!p.drift_active() && !p.needs_motion());
        p.set_drag_in_progress(false);
        assert!(p.drift_active());
    }

    #[test]
    fn a_drawer_opened_past_the_drift_zone_stays_put() {
        let mut p = DrawerPhysics::with_state(0.3, 0.0);
        assert!(!p.drift_active() && !p.needs_motion());
        p.advance(FRAME);
        assert_eq!(p.position(), 0.3);
    }

    #[test]
    fn a_file_drag_stops_the_drawer_closing() {
        let mut p = DrawerPhysics::with_state(0.5, -2.0);
        p.set_drag_in_progress(true);
        assert_eq!(p.velocity(), 0.0, "closing velocity is cancelled");
        for _ in 0..120 {
            p.advance(FRAME);
        }
        assert_eq!(p.position(), 0.5);
    }

    #[test]
    fn a_hovering_file_opens_the_drawer() {
        let mut p = DrawerPhysics::new();
        p.open_for_drag();
        p.set_drag_in_progress(true);
        let (_, t) = run_until_rest(&mut p, 10.0);
        assert!(t < 10.0);
        assert!(
            p.is_interactive(),
            "open far enough to accept the drop, at {}",
            p.position()
        );
        // Already open: hovering again does nothing.
        let v = p.velocity();
        p.open_for_drag();
        assert_eq!(p.velocity(), v);
    }

    #[test]
    fn the_hand_drags_the_drawer_with_lag_and_it_keeps_momentum() {
        let mut p = DrawerPhysics::new();
        p.begin_grab();
        assert!(p.is_grabbed());
        p.grab_to(0.5);
        let mut early = 0.0;
        for i in 0..90 {
            p.advance(FRAME);
            if i == 2 {
                early = p.position();
            }
        }
        // A spring with stiffness 240 and damping 27 covers about a fifth of the way in 3 frames.
        assert!(
            early > 0.0 && early < 0.2,
            "lags behind the hand after 3 frames, at {early}"
        );
        assert!(
            (p.position() - 0.5).abs() < 0.02,
            "caught up at {}",
            p.position()
        );
        assert!(
            !p.needs_motion(),
            "hand is still, drawer settled on the target"
        );

        // Fling it open and let go: it keeps its momentum.
        p.grab_to(0.9);
        for _ in 0..8 {
            p.advance(FRAME);
        }
        let v = p.velocity();
        assert!(v > 0.5);
        p.end_grab();
        assert!(!p.is_grabbed());
        assert_eq!(p.velocity(), v.clamp(-6.0, 6.0));
        assert!(p.needs_motion());
    }

    #[test]
    fn the_hand_can_press_the_drawer_into_the_bumpers_but_not_further() {
        let mut p = DrawerPhysics::new();
        p.begin_grab();
        p.grab_to(-1.0); // clamped to -0.02
        for _ in 0..60 {
            p.advance(FRAME);
        }
        assert!(p.position() >= BUMPER_LIMIT);
        assert!(p.position() < 0.0);
        p.end_grab();
        let (_, t) = run_until_rest(&mut p, 5.0);
        assert!(t < 5.0);
        assert_eq!(p.position(), 0.0);
    }

    #[test]
    fn suspending_freezes_in_place() {
        let mut p = DrawerPhysics::with_state(0.1, -1.0);
        p.set_suspended(true);
        assert_eq!(p.velocity(), 0.0);
        assert!(!p.needs_motion());
        assert!(p.advance(FRAME).is_empty());
        assert_eq!(p.position(), 0.1, "nothing is forced shut");
        p.toggle();
        assert_eq!(p.velocity(), 0.0, "ignores input while suspended");
        p.set_suspended(false);
        assert!(p.drift_active() && p.needs_motion(), "drift resumes");

        let mut q = DrawerPhysics::with_state(-0.03, 0.0);
        q.set_suspended(true);
        assert_eq!(q.position(), 0.0, "never freezes inside the bumpers");
    }

    #[test]
    fn position_never_leaves_its_range() {
        for start in [0.0, 0.5, 1.0] {
            for v in [-8.0, -3.0, 3.0, 8.0] {
                let mut p = DrawerPhysics::with_state(start, v);
                for _ in 0..600 {
                    p.advance(FRAME);
                    assert!(
                        p.position() >= BUMPER_LIMIT && p.position() <= 1.0,
                        "{start} {v}: {}",
                        p.position()
                    );
                }
            }
        }
    }

    #[test]
    fn long_frames_are_clamped_and_substepped() {
        let mut a = DrawerPhysics::with_state(1.0, 0.0);
        a.toggle();
        let mut b = a.clone();
        a.advance(5.0); // a hiccup of five seconds counts as 1/20 s
        b.advance(1.0 / 20.0);
        assert_eq!(a.position(), b.position());
    }

    #[test]
    fn grab_target_maps_window_height_to_position() {
        assert_eq!(grab_target_for_window_height(76.0), 0.0);
        assert_eq!(grab_target_for_window_height(300.0), 1.0);
        assert_eq!(grab_target_for_window_height(188.0), 0.5);
        assert_eq!(grab_target_for_window_height(0.0), -0.02);
        assert_eq!(grab_target_for_window_height(900.0), 1.0);
    }
}
