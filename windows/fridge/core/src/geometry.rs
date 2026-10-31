//! Sizes, door specs and the door projection used for hit testing. Port of `Geometry.swift`.
//!
//! All sizes are points. Scene coordinates: origin at the bottom left of the cabinet body, y up.
//! View (window) coordinates: scene plus `BODY_ORIGIN`.

use crate::layout::InteriorGeometry;
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Pt {
    pub x: f64,
    pub y: f64,
}

impl Pt {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
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
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    pub fn contains(&self, p: Pt) -> bool {
        p.x >= self.x && p.x <= self.max_x() && p.y >= self.y && p.y <= self.max_y()
    }
    pub fn inset(&self, d: f64) -> Rect {
        Rect::new(self.x + d, self.y + d, self.w - 2.0 * d, self.h - 2.0 * d)
    }
    pub fn intersects(&self, o: &Rect) -> bool {
        self.x < o.max_x() && o.x < self.max_x() && self.y < o.max_y() && o.y < self.max_y()
    }
}

/// Window size. Larger than the fridge so the door can swing past the hinge and the fog can spill.
pub const WINDOW_SIZE: (f64, f64) = (520.0, 800.0);
pub const BODY_ORIGIN: Pt = Pt::new(190.0, 170.0);
pub const BODY_SIZE: (f64, f64) = (280.0, 563.0);
pub const DOOR_INSET: f64 = 4.0;
/// Where the freezer door meets the fridge door (scene y).
pub const DOOR_SPLIT_Y: f64 = 369.0;
/// Hinge plates on the cabinet (scene y of their bottom edge): top, middle, bottom.
pub const HINGE_PLATE_Y: [f64; 3] = [505.0, DOOR_SPLIT_Y - 20.0, 30.0];
pub const DOOR_HALF_THICKNESS: f64 = 9.0;
pub const DOOR_CORNER_RADIUS: f64 = 24.0;
pub const BIN_DEPTH: f64 = 22.0;
pub const BIN_LIP_HEIGHT: f64 = 22.0;
pub const BIN_INSET: f64 = 26.0;
/// The opening into the cabinet, scene coordinates.
pub const OPENING: Rect = Rect::new(14.0, 14.0, InteriorGeometry::OPENING_WIDTH, InteriorGeometry::OPENING_HEIGHT);
pub const EYE_DISTANCE: f64 = InteriorGeometry::EYE_DISTANCE;
/// Vanishing point of the scene: the interior's eye.
pub const VANISHING: Pt = Pt::new(14.0 + InteriorGeometry::VANISHING_X, 14.0 + InteriorGeometry::VANISHING_Y);

const DEG: f64 = PI / 180.0;
/// Items become usable past this angle (with hysteresis).
pub const INTERACTIVE_ON_ANGLE: f64 = 40.0 * DEG;
pub const INTERACTIVE_OFF_ANGLE: f64 = 36.0 * DEG;
/// Sound, fog and frost start when a door first passes this angle. Notes only work below it.
pub const OPENED_ANGLE: f64 = 8.0 * DEG;
/// Below this a door counts as sealed.
pub const SEALED_ANGLE: f64 = 0.6 * DEG;
/// Double-click swings a door to this angle.
pub const SWING_OPEN_ANGLE: f64 = 96.0 * DEG;

pub const FOG_FRAME_COUNT: usize = 40;
pub const FOG_DURATION: f64 = 1.7;
/// Floor plume (view coordinates).
pub const FOG_FRAME: Rect = Rect::new(90.0, -40.0, 480.0, 360.0);
/// Spill plume (view coordinates).
pub const FOG_SPILL_FRAME: Rect = Rect::new(120.0, 130.0, 420.0, 315.0);

/// Depth of a shut door's front face (lifted by half the thickness plus a hair, face forward again).
pub const FRONT_FACE_Z: f64 = DOOR_HALF_THICKNESS * 2.0 + 0.5;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DoorId {
    Fridge,
    Freezer,
}

impl DoorId {
    pub const ALL: [DoorId; 2] = [DoorId::Fridge, DoorId::Freezer];

    pub fn index(self) -> usize {
        match self {
            DoorId::Fridge => 0,
            DoorId::Freezer => 1,
        }
    }

    pub fn spec(self) -> &'static DoorSpec {
        &DOORS[self.index()]
    }

    /// Name used in the notes file.
    pub fn name(self) -> &'static str {
        self.spec().name
    }

    pub fn from_name(name: &str) -> Option<DoorId> {
        DoorId::ALL.into_iter().find(|d| d.name() == name)
    }
}

/// One of the two doors.
#[derive(Clone, Debug)]
pub struct DoorSpec {
    pub name: &'static str,
    /// The door's rectangle in scene coordinates when shut. Hinged on its left edge.
    pub frame: Rect,
    /// Asset file name (without extension) for the door front.
    pub artwork: &'static str,
    /// Shelves behind this door, usable only while it is open.
    pub shelves: &'static [usize],
    /// Bottom edge of each door bin, door space.
    pub bin_y: &'static [f64],
    pub round_top: bool,
    pub round_bottom: bool,
}

pub static DOORS: [DoorSpec; 2] = [
    DoorSpec {
        name: "fridge",
        frame: Rect::new(4.0, 4.0, 272.0, DOOR_SPLIT_Y - 4.0),
        artwork: "door_fridge",
        shelves: &[0, 1],
        bin_y: &[36.0, 146.0, 256.0],
        round_top: false,
        round_bottom: true,
    },
    DoorSpec {
        name: "freezer",
        frame: Rect::new(4.0, DOOR_SPLIT_Y, 272.0, 559.0 - DOOR_SPLIT_Y),
        artwork: "door_freezer",
        shelves: &[2],
        bin_y: &[46.0],
        round_top: true,
        round_bottom: false,
    },
];

impl DoorSpec {
    pub fn width(&self) -> f64 {
        self.frame.w
    }
    pub fn height(&self) -> f64 {
        self.frame.h
    }

    /// The part of the opening behind this door, in opening coordinates.
    pub fn opening_slice(&self) -> Rect {
        let o = OPENING;
        let lo = self.frame.min_y().max(o.min_y());
        let hi = self.frame.max_y().min(o.max_y());
        Rect::new(0.0, lo - o.min_y(), o.w, hi - lo)
    }
}

/// Projects a point on a door (door space, origin bottom left) at `angle` into the scene.
/// Hit testing only: the face depth and lift are ignored, as in the Mac app.
pub fn project_door_point(p: Pt, angle: f64, door: &DoorSpec) -> Pt {
    let x = p.x * angle.cos();
    let z = p.x * angle.sin();
    let scene_x = door.frame.min_x() + x;
    let scene_y = door.frame.min_y() + p.y;
    let w = 1.0 - z / EYE_DISTANCE;
    Pt::new(VANISHING.x + (scene_x - VANISHING.x) / w, VANISHING.y + (scene_y - VANISHING.y) / w)
}

/// A whole door as a polygon in scene coordinates.
pub fn door_quad(angle: f64, door: &DoorSpec) -> [Pt; 4] {
    let (w, h) = (door.width(), door.height());
    [
        project_door_point(Pt::new(0.0, 0.0), angle, door),
        project_door_point(Pt::new(w, 0.0), angle, door),
        project_door_point(Pt::new(w, h), angle, door),
        project_door_point(Pt::new(0.0, h), angle, door),
    ]
}

/// Where a point `door_x` across a door, at mid height, appears horizontally.
pub fn scene_x_of_door_x(door_x: f64, angle: f64, door: &DoorSpec) -> f64 {
    project_door_point(Pt::new(door_x, door.height() / 2.0), angle, door).x
}

/// Which point across a door is under scene x at the current angle.
pub fn door_x_under_scene_x(x: f64, angle: f64, door: &DoorSpec) -> f64 {
    let mut lo = 0.0;
    let mut hi = door.width();
    let increasing = scene_x_of_door_x(hi, angle, door) >= scene_x_of_door_x(lo, angle, door);
    for _ in 0..24 {
        let mid = (lo + hi) / 2.0;
        if (scene_x_of_door_x(mid, angle, door) < x) == increasing {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    (lo + hi) / 2.0
}

/// The door angle that puts the grabbed point `door_x` under scene x.
pub fn angle_for_door_x(door_x: f64, scene_x: f64, max_angle: f64, door: &DoorSpec) -> f64 {
    let mut lo = 0.0;
    let mut hi = max_angle;
    if scene_x >= scene_x_of_door_x(door_x, lo, door) {
        return lo;
    }
    if scene_x <= scene_x_of_door_x(door_x, hi, door) {
        return hi;
    }
    for _ in 0..28 {
        let mid = (lo + hi) / 2.0;
        if scene_x_of_door_x(door_x, mid, door) > scene_x {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    (lo + hi) / 2.0
}

/// Where a point on a shut door's front face appears in the scene.
pub fn scene_front_point(p: Pt, door: &DoorSpec) -> Pt {
    let w = 1.0 - FRONT_FACE_Z / EYE_DISTANCE;
    Pt::new(
        VANISHING.x + (door.frame.min_x() + p.x - VANISHING.x) / w,
        VANISHING.y + (door.frame.min_y() + p.y - VANISHING.y) / w,
    )
}

/// The point on a shut door's front face under a scene point (door space).
pub fn door_point_under_scene(s: Pt, door: &DoorSpec) -> Pt {
    let w = 1.0 - FRONT_FACE_Z / EYE_DISTANCE;
    Pt::new(
        VANISHING.x + (s.x - VANISHING.x) * w - door.frame.min_x(),
        VANISHING.y + (s.y - VANISHING.y) * w - door.frame.min_y(),
    )
}

/// Convex polygon containment, either winding.
pub fn polygon_contains(polygon: &[Pt], point: Pt) -> bool {
    if polygon.len() < 3 {
        return false;
    }
    let mut sign = 0.0;
    for i in 0..polygon.len() {
        let a = polygon[i];
        let b = polygon[(i + 1) % polygon.len()];
        let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
        if cross.abs() < 1e-6 {
            continue;
        }
        if sign == 0.0 {
            sign = if cross > 0.0 { 1.0 } else { -1.0 };
        } else if (cross > 0.0) != (sign > 0.0) {
            return false;
        }
    }
    true
}

pub fn scene_from_view(p: Pt) -> Pt {
    Pt::new(p.x - BODY_ORIGIN.x, p.y - BODY_ORIGIN.y)
}

pub fn body_rect_in_view() -> Rect {
    Rect::new(BODY_ORIGIN.x, BODY_ORIGIN.y, BODY_SIZE.0, BODY_SIZE.1)
}

/// `smoothstep` as used for door lighting.
pub fn smoothstep(edge0: f64, edge1: f64, x: f64) -> f64 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shut_door_projects_onto_its_frame() {
        let door = DoorId::Fridge.spec();
        let q = door_quad(0.0, door);
        assert!((q[0].x - door.frame.x).abs() < 1e-9 && (q[0].y - door.frame.y).abs() < 1e-9);
        assert!((q[2].x - door.frame.max_x()).abs() < 1e-9);
    }

    #[test]
    fn grabbed_point_round_trips_through_angle() {
        let door = DoorId::Fridge.spec();
        for angle in [0.2, 0.7, 1.2, 1.6] {
            let x = scene_x_of_door_x(200.0, angle, door);
            let back = angle_for_door_x(200.0, x, 105.0 * DEG, door);
            assert!((back - angle).abs() < 1e-6, "{angle} -> {back}");
            let dx = door_x_under_scene_x(x, angle, door);
            assert!((dx - 200.0).abs() < 1e-3);
        }
    }

    #[test]
    fn front_face_round_trips() {
        let door = DoorId::Freezer.spec();
        let p = Pt::new(100.0, 50.0);
        let s = scene_front_point(p, door);
        let back = door_point_under_scene(s, door);
        assert!((back.x - p.x).abs() < 1e-9 && (back.y - p.y).abs() < 1e-9);
    }

    #[test]
    fn slices_split_the_opening() {
        assert_eq!(DoorId::Fridge.spec().opening_slice(), Rect::new(0.0, 0.0, 252.0, 355.0));
        assert_eq!(DoorId::Freezer.spec().opening_slice(), Rect::new(0.0, 355.0, 252.0, 180.0));
    }

    #[test]
    fn polygon_hit() {
        let q = door_quad(0.0, DoorId::Fridge.spec());
        assert!(polygon_contains(&q, Pt::new(100.0, 100.0)));
        assert!(!polygon_contains(&q, Pt::new(300.0, 100.0)));
    }
}
