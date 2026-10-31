//! Everything the fridge does, without Windows: mouse gestures, the doors, items on the shelves,
//! file drops, sticky notes and photo magnets, menus, and the short animations. Port of
//! `FridgeView.swift`, `ItemsController.swift`, `NotesController.swift` and `FogPlayer.swift`.
//!
//! The Win32 layer feeds input in and carries out the returned [`Effect`]s. It never calls back
//! into the model while an effect runs, so modal loops (drag and drop, menus, dialogs) are safe.
//!
//! Coordinates: `view` points are design points with the origin at the window's bottom left and
//! y up, as in the spec. `screen` is physical pixels, y down.

use crate::anim::{pop_scale, Curve, Tween, POP_DURATION};
use crate::menu::{self, Command, Entry};
use crate::placement;
use crate::settings::{MAX_SCALE, MIN_SCALE};
use fridge_art::{FogState, Image, ItemVisual, NoteVisual, SceneState, NOTE_SIZE};
use fridge_core::geometry::{self as geo, DoorId, DoorSpec, Pt, Rect, BODY_ORIGIN, BODY_SIZE, OPENING};
use fridge_core::layout::{InteriorGeometry, ShelfLayout};
use fridge_core::physics::DoorDriver;
use fridge_core::{DoorNote, DoorNotesStore, FridgeEntry, FridgeError, FridgeStore, FrostModel, FrostState, NoteKind, SeededRandom};
use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const DEG: f64 = PI / 180.0;
/// Below this a press is a click, above it a drag (points).
const DRAG_SLOP: f64 = 3.0;
const ITEM_DRAG_SLOP: f64 = 4.0;
/// Grabbing right by the hinge would give absurd leverage; hold no closer than this.
const MIN_GRAB_X: f64 = 70.0;
const TOGGLE_CLOSE_ABOVE: f64 = 30.0 * DEG;
/// The floor plume starts this late and both play for `FOG_DURATION`.
const FOG_FLOOR_DELAY: f64 = 0.18;
const LIFT_DURATION: f64 = 0.15;
const ITEM_SLIDE: f64 = 28.0;
const ITEM_SLIDE_DURATION: f64 = 0.30;
const ITEM_FADE_IN: f64 = 0.2;
const ITEM_FADE_OUT: f64 = 0.18;
const ITEM_DRAG_OPACITY: f32 = 0.25;
const NOTE_LIFT_DURATION: f64 = 0.12;
const NOTE_SETTLE_DURATION: f64 = 0.15;
const PEEL_DURATION: f64 = 0.28;
const PICTURE_SPRING_DELAY: f64 = 0.8;
/// After a drag out, look again this long after the drop for the file to have left.
pub const GONE_CHECKS: [f64; 3] = [0.05, 1.0, 3.0];
/// Put Back: give Explorer a moment to see the file before moving its icon.
pub const RESTORE_POSITION_DELAY: f64 = 0.4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sound {
    Open,
    Seal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cursor {
    Arrow,
    OpenHand,
    ClosedHand,
    Resize,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Task {
    CheckGone(String),
    RestoreDesktopPosition { path: PathBuf, position: (f64, f64) },
    PictureSpring { door: usize, token: u64 },
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorRequest {
    pub id: String,
    /// Note centre in view points.
    pub center: Pt,
    pub tilt: f64,
    pub text: String,
    pub color: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Play(Sound),
    StopSounds,
    Beep,
    SetCursor(Cursor),
    Capture(bool),
    /// `window.origin` changed, same size.
    WindowMoved,
    /// `window.user_scale` (and origin) changed. `rerender` = draw the art at the new size now
    /// (on release); otherwise stretch the last frame.
    WindowResized { rerender: bool },
    SaveSettings,
    Open(PathBuf),
    ShowInExplorer(PathBuf),
    BeginItemDrag { id: String, path: PathBuf },
    /// Fetch the shell icon for an item and hand it to `set_icon`.
    NeedIcon { id: String, path: PathBuf },
    ConfirmMoveAll { title: String, message: String },
    Alert { title: String, message: String },
    BeginEditor(EditorRequest),
    EndEditor,
    Schedule { delay: f64, task: Task },
}

#[derive(Clone, Copy, Debug)]
pub struct Mouse {
    pub view: Pt,
    pub screen: (f64, f64),
    /// 2 for the second press of a double-click.
    pub clicks: u32,
    pub ctrl: bool,
    pub alt: bool,
}

/// Where the window is and how big it is drawn.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowGeom {
    pub origin: (i32, i32),
    pub dpi_scale: f64,
    pub user_scale: f64,
}

impl WindowGeom {
    pub fn scale(&self) -> f64 {
        self.dpi_scale * self.user_scale
    }
    pub fn size(&self) -> (i32, i32) {
        placement::window_size(self.scale())
    }
    /// Client pixel (y down) to view point (y up).
    pub fn view_point(&self, client: (f64, f64)) -> Pt {
        let s = self.scale();
        Pt::new(client.0 / s, geo::WINDOW_SIZE.1 - client.1 / s)
    }
    /// View point to screen pixel.
    pub fn screen_point(&self, view: Pt) -> (f64, f64) {
        let s = self.scale();
        (self.origin.0 as f64 + view.x * s, self.origin.1 as f64 + (geo::WINDOW_SIZE.1 - view.y) * s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PauseReason {
    Lock,
    Sleep,
    DisplayOff,
}

#[derive(Clone, Debug, Default)]
pub struct DragInfo {
    pub files: Vec<PathBuf>,
    /// Plain text, when the drag carries no files.
    pub text: Option<String>,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Allowed {
    pub copy: bool,
    pub move_: bool,
    pub link: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DropEffect {
    None,
    Copy,
    Move,
    Link,
}

#[derive(Clone, Debug, PartialEq)]
pub enum DropAction {
    Nothing,
    /// Move these files in. The caller reads Desktop icon positions first, then `store_files`.
    Store { shelf: usize, files: Vec<PathBuf> },
    StickPhotos { door: usize, point: Pt, files: Vec<PathBuf> },
    StickText { door: usize, point: Pt, text: String },
}

struct Door {
    driver: DoorDriver,
    has_opened: bool,
    interactive: bool,
}

impl Door {
    fn angle(&self) -> f64 {
        self.driver.physics.visual_angle()
    }
}

#[derive(Clone, Copy, Debug)]
enum Gesture {
    None,
    Resize,
    Move,
}

#[derive(Clone, Debug)]
enum Interaction {
    None,
    DoorPress { door: usize, door_x: f64, start: (f64, f64) },
    Door { door: usize, door_x: f64 },
    Resize { start: (f64, f64), start_scale: f64 },
    Window { start: (f64, f64), start_origin: (i32, i32) },
    Item { id: String, start: Pt },
    NotePress { id: String, door: usize, grab: Pt, start: (f64, f64), moved: bool },
}

#[derive(Clone, Debug)]
struct ItemState {
    frost: FrostState,
    /// Seconds since it was added, while the drop-in runs.
    added: Option<f64>,
}

#[derive(Clone, Debug)]
struct NoteAnim {
    pop: Option<f64>,
    lifted: Tween,
    /// Settling back inside the door after a drag: from this point to the stored one.
    settle: Option<(Pt, Tween)>,
}

impl Default for NoteAnim {
    fn default() -> Self {
        NoteAnim { pop: None, lifted: Tween::at(0.0), settle: None }
    }
}

impl NoteAnim {
    fn active(&self) -> bool {
        self.pop.is_some() || !self.lifted.done() || self.settle.is_some()
    }
}

struct Peeling {
    visual: NoteVisual,
    elapsed: f64,
}

pub struct Model {
    pub store: FridgeStore,
    pub notes: DoorNotesStore,
    pub window: WindowGeom,
    pub time_scale: f64,
    /// Kept up to date by the Win32 layer (Settings > Accessibility > Animation effects).
    pub reduce_motion: bool,
    /// Battery saver.
    pub low_power: bool,
    doors: [Door; 2],
    items: HashMap<String, ItemState>,
    fading_items: Vec<(ItemVisual, Tween)>,
    icons: HashMap<String, Arc<Image>>,
    dragging_item: Option<String>,
    photos: HashMap<String, Arc<Image>>,
    note_anims: HashMap<String, NoteAnim>,
    peeling: Vec<Peeling>,
    pending_move: Option<DoorNote>,
    editing: Option<(String, bool)>,
    fog: Option<f64>,
    fog_lite: bool,
    lift: Tween,
    interaction: Interaction,
    pause: HashSet<PauseReason>,
    picture_spring: Option<(usize, u64)>,
    spring_token: u64,
    rng: SeededRandom,
    dirty: bool,
}

impl Model {
    pub fn new(store: FridgeStore, notes: DoorNotesStore, window: WindowGeom, time_scale: f64, seed: u64) -> Model {
        let items = store
            .entries()
            .iter()
            .map(|e| (e.id.clone(), ItemState { frost: FrostState::new(0.0, 0.0), added: None }))
            .collect();
        let mut photos = HashMap::new();
        for n in notes.notes() {
            if n.kind != NoteKind::Photo {
                continue;
            }
            if let Some(image) = notes.photo_path(n).and_then(|p| std::fs::read(p).ok()).and_then(|b| fridge_art::decode_png(&b)) {
                photos.insert(n.id.clone(), Arc::new(image));
            }
        }
        let door = || {
            // A door made at exactly 0° still has the magnet pulling it onto the seal. Settle it
            // now, silently, so the frame loop does not start at launch.
            let mut driver = DoorDriver::default();
            for _ in 0..(240 * 5) {
                if driver.physics.is_at_rest() {
                    break;
                }
                driver.physics.step_once();
            }
            Door { driver, has_opened: false, interactive: false }
        };
        Model {
            store,
            notes,
            window,
            time_scale,
            reduce_motion: false,
            low_power: false,
            doors: [door(), door()],
            items,
            fading_items: Vec::new(),
            icons: HashMap::new(),
            dragging_item: None,
            photos,
            note_anims: HashMap::new(),
            peeling: Vec::new(),
            pending_move: None,
            editing: None,
            fog: None,
            fog_lite: false,
            lift: Tween::at(0.0),
            interaction: Interaction::None,
            pause: HashSet::new(),
            picture_spring: None,
            spring_token: 0,
            rng: SeededRandom::new(seed),
            dirty: true,
        }
    }

    // MARK: Frame loop

    pub fn is_paused(&self) -> bool {
        !self.pause.is_empty()
    }

    /// True while anything moves; the frame loop stops when this turns false.
    pub fn is_animating(&self) -> bool {
        if self.is_paused() {
            return false;
        }
        self.doors.iter().any(|d| !d.driver.is_at_rest())
            || self.fog.is_some()
            || !self.lift.done()
            || self.items.values().any(|s| s.added.is_some())
            || !self.fading_items.is_empty()
            || self.note_anims.values().any(NoteAnim::active)
            || !self.peeling.is_empty()
    }

    /// 120 Hz while a door is held or moving fast, else 60 Hz.
    pub fn wants_high_rate(&self) -> bool {
        self.doors.iter().any(|d| !d.driver.is_at_rest() && d.driver.wants_high_rate())
    }

    /// A redraw is due even if nothing animates (a note changed colour, an item arrived...).
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    pub fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Advances everything by one frame. `now` is wall-clock seconds since the epoch (for frost).
    pub fn tick(&mut self, dt: f64, now: f64) -> Vec<Effect> {
        let mut out = Vec::new();
        if self.is_paused() {
            return out;
        }
        let dt = if dt <= 0.0 || dt > 0.1 { 1.0 / 60.0 } else { dt };
        for i in 0..2 {
            if !self.doors[i].driver.is_at_rest() {
                self.doors[i].driver.tick(dt);
                self.after_door_frame(i, now, &mut out);
                self.dirty = true;
            }
        }
        if let Some(t) = self.fog.as_mut() {
            *t += dt;
            if *t >= FOG_FLOOR_DELAY + geo::FOG_DURATION {
                self.fog = None;
            }
            self.dirty = true;
        }
        if !self.lift.done() {
            self.lift.advance(dt);
            self.dirty = true;
        }
        for state in self.items.values_mut() {
            if let Some(t) = state.added.as_mut() {
                *t += dt;
                if *t >= ITEM_SLIDE_DURATION.max(ITEM_FADE_IN) {
                    state.added = None;
                }
                self.dirty = true;
            }
        }
        if !self.fading_items.is_empty() {
            for (_, tween) in self.fading_items.iter_mut() {
                tween.advance(dt);
            }
            self.fading_items.retain(|(_, t)| !t.done());
            self.dirty = true;
        }
        for anim in self.note_anims.values_mut() {
            if !anim.active() {
                continue;
            }
            if let Some(t) = anim.pop.as_mut() {
                *t += dt;
                if *t >= POP_DURATION {
                    anim.pop = None;
                }
            }
            anim.lifted.advance(dt);
            if let Some((_, tween)) = anim.settle.as_mut() {
                tween.advance(dt);
                if tween.done() {
                    anim.settle = None;
                }
            }
            self.dirty = true;
        }
        self.note_anims.retain(|_, a| a.active());
        if !self.peeling.is_empty() {
            for p in self.peeling.iter_mut() {
                p.elapsed += dt;
            }
            self.peeling.retain(|p| p.elapsed < PEEL_DURATION);
            self.dirty = true;
        }
        out
    }

    fn after_door_frame(&mut self, i: usize, now: f64, out: &mut Vec<Effect>) {
        let angle = self.doors[i].angle();
        if !self.doors[i].has_opened && angle > geo::OPENED_ANGLE {
            self.doors[i].has_opened = true;
            self.door_opened(now, out);
        } else if self.doors[i].has_opened && angle < geo::SEALED_ANGLE {
            self.doors[i].has_opened = false;
            out.push(Effect::Play(Sound::Seal));
        }
        let door = &mut self.doors[i];
        if !door.interactive && angle >= geo::INTERACTIVE_ON_ANGLE {
            door.interactive = true;
        } else if door.interactive && angle < geo::INTERACTIVE_OFF_ANGLE {
            door.interactive = false;
        }
    }

    fn door_opened(&mut self, now: f64, out: &mut Vec<Effect>) {
        out.push(Effect::Play(Sound::Open));
        self.apply_frost(now);
        // Reduce motion turns the plume off; battery saver plays a lighter one.
        if !self.reduce_motion && self.fog.is_none() {
            self.fog = Some(0.0);
            self.fog_lite = self.low_power;
        }
    }

    /// Works out every item's frost from its timestamp. The renderer re-bakes only the items whose
    /// bucket changed.
    fn apply_frost(&mut self, now: f64) {
        for e in self.store.entries() {
            if let Some(state) = self.items.get_mut(&e.id) {
                state.frost = FrostModel::state(e.placed_at, now, self.time_scale);
            }
        }
        self.dirty = true;
    }

    /// The art was redrawn at a new scale: items look unfrosted until the next opening (as on the Mac).
    pub fn art_scale_changed(&mut self) {
        for state in self.items.values_mut() {
            state.frost = FrostState::new(0.0, 0.0);
        }
        self.dirty = true;
    }

    // MARK: Pause (lock, sleep, display off)

    /// Freezes doors, cancels the fog and stops sounds. The Win32 layer closes the note editor first.
    pub fn set_paused(&mut self, reason: PauseReason, on: bool) -> Vec<Effect> {
        let mut out = Vec::new();
        if on {
            self.pause.insert(reason);
            self.fog = None;
            self.dirty = true;
            out.push(Effect::StopSounds);
        } else {
            self.pause.remove(&reason);
        }
        out
    }

    /// Development aid: `FRIDGE_DEBUG_ANGLE` pins a door open at an angle.
    pub fn debug_pin(&mut self, door: usize, angle: f64) {
        if let Some(d) = self.doors.get_mut(door) {
            d.driver.physics.reset(angle, 0.0);
            d.driver.physics.hand_target = Some(angle);
            d.has_opened = angle > geo::OPENED_ANGLE;
            d.interactive = angle >= geo::INTERACTIVE_ON_ANGLE;
            self.dirty = true;
        }
    }

    // MARK: Scene

    pub fn door_angles(&self) -> [f64; 2] {
        [self.doors[0].angle(), self.doors[1].angle()]
    }

    pub fn scene(&self) -> SceneState {
        let mut entries: Vec<&FridgeEntry> = self.store.entries().iter().collect();
        sort_draw_order(&mut entries);
        let mut items: Vec<ItemVisual> = entries.into_iter().map(|e| self.item_visual(e)).collect();
        for (visual, tween) in &self.fading_items {
            let mut v = visual.clone();
            v.opacity = (visual.opacity as f64 * tween.value()) as f32;
            items.push(v);
        }
        let mut notes: Vec<NoteVisual> = self.notes.notes().iter().filter_map(|n| self.note_visual(n)).collect();
        for p in &self.peeling {
            let t = Curve::EaseIn.apply(p.elapsed / PEEL_DURATION);
            let mut v = p.visual.clone();
            // Tips from its tilt to 0.5 rad, drops (10, −26) in door space and fades.
            v.rotation_extra = (0.5 - v.tilt) * t;
            v.offset = (10.0 * t, -26.0 * t);
            v.opacity = (1.0 - t) as f32;
            notes.push(v);
        }
        SceneState {
            door_angles: self.door_angles(),
            items,
            notes,
            fog: self.fog.map(|elapsed| FogState { elapsed, lite: self.fog_lite }),
            lift: self.lift.value() as f32,
        }
    }

    fn item_visual(&self, e: &FridgeEntry) -> ItemVisual {
        let (jitter_x, tilt) = e.jitter_and_tilt();
        let state = self.items.get(&e.id);
        let (mut opacity, mut lift) = (1.0f32, 0.0f32);
        if let Some(t) = state.and_then(|s| s.added) {
            opacity = (t / ITEM_FADE_IN).clamp(0.0, 1.0) as f32;
            lift = (ITEM_SLIDE * (1.0 - Curve::EaseOut.apply(t / ITEM_SLIDE_DURATION))) as f32;
        }
        if self.dragging_item.as_deref() == Some(e.id.as_str()) {
            opacity = ITEM_DRAG_OPACITY;
        }
        ItemVisual {
            id: e.id.clone(),
            icon: self.icons.get(&e.id).cloned(),
            shelf: e.shelf,
            slot: e.slot,
            jitter_x,
            tilt,
            seed: e.stable_seed(),
            frost: state.map(|s| s.frost).unwrap_or(FrostState::new(0.0, 0.0)),
            opacity,
            lift,
        }
    }

    fn note_visual(&self, n: &DoorNote) -> Option<NoteVisual> {
        let door = DoorId::from_name(&n.door)?;
        let anim = self.note_anims.get(&n.id);
        let mut pos = Pt::new(n.x, n.y);
        if let Some(p) = self.pending_move.as_ref().filter(|p| p.id == n.id) {
            pos = Pt::new(p.x, p.y);
        }
        if let Some((from, tween)) = anim.and_then(|a| a.settle.as_ref()) {
            let t = tween.value();
            pos = Pt::new(from.x + (pos.x - from.x) * t, from.y + (pos.y - from.y) * t);
        }
        Some(NoteVisual {
            id: n.id.clone(),
            door,
            is_photo: n.kind == NoteKind::Photo,
            x: pos.x,
            y: pos.y,
            tilt: n.tilt,
            color: n.color,
            text: n.text.clone(),
            photo: self.photos.get(&n.id).cloned(),
            hide_text: self.editing.as_ref().map(|e| e.0 == n.id).unwrap_or(false),
            scale: anim.and_then(|a| a.pop).map(pop_scale).unwrap_or(1.0) as f32,
            opacity: 1.0,
            rotation_extra: 0.0,
            offset: (0.0, 0.0),
            lifted: anim.map(|a| a.lifted.value()).unwrap_or(0.0) as f32,
        })
    }

    // MARK: Hit testing

    /// The door under a scene point. An open door stands in front of the other, so it wins.
    fn door_at(&self, s: Pt) -> Option<usize> {
        (0..2)
            .filter(|&i| geo::polygon_contains(&geo::door_quad(self.doors[i].angle(), DoorId::ALL[i].spec()), s))
            .max_by(|&a, &b| self.doors[a].angle().total_cmp(&self.doors[b].angle()))
    }

    fn is_on_fridge(&self, s: Pt) -> bool {
        self.door_at(s).is_some() || Rect::new(0.0, 0.0, BODY_SIZE.0, BODY_SIZE.1).contains(s)
    }

    /// A shut door under a scene point. Notes live on the front face, which faces the user only
    /// while the door is (nearly) closed.
    fn shut_door(&self, s: Pt) -> Option<usize> {
        let i = self.door_at(s)?;
        (self.doors[i].angle() < geo::OPENED_ANGLE).then_some(i)
    }

    fn open_shelves(&self) -> HashSet<usize> {
        (0..2).filter(|&i| self.doors[i].interactive).flat_map(|i| DoorId::ALL[i].spec().shelves.iter().copied()).collect()
    }

    /// Front-most item under a point in opening coordinates, on open shelves only.
    fn item_at(&self, p: Pt) -> Option<String> {
        let open = self.open_shelves();
        let mut entries: Vec<&FridgeEntry> = self.store.entries().iter().collect();
        sort_draw_order(&mut entries);
        entries
            .into_iter()
            .rev()
            .find(|e| open.contains(&e.shelf) && item_rect(e).contains(p))
            .map(|e| e.id.clone())
    }

    fn note_size(&self, n: &DoorNote) -> (f64, f64) {
        if n.kind == NoteKind::Photo {
            if let Some(img) = self.photos.get(&n.id) {
                return fridge_art::photo_size(img.width, img.height);
            }
        }
        (NOTE_SIZE, NOTE_SIZE)
    }

    /// Top-most note under a door-space point.
    fn note_at(&self, door: usize, p: Pt) -> Option<DoorNote> {
        let name = DoorId::ALL[door].name();
        self.notes
            .notes()
            .iter()
            .rev()
            .filter(|n| n.door == name)
            .find(|n| {
                let (w, h) = self.note_size(n);
                let (dx, dy) = (p.x - n.x, p.y - n.y);
                let (c, s) = ((-n.tilt).cos(), (-n.tilt).sin());
                let local = (dx * c - dy * s, dx * s + dy * c);
                local.0.abs() <= w / 2.0 && local.1.abs() <= h / 2.0
            })
            .cloned()
    }

    fn note_under(&self, s: Pt) -> Option<(usize, DoorNote)> {
        let i = self.shut_door(s)?;
        let p = geo::door_point_under_scene(s, DoorId::ALL[i].spec());
        self.note_at(i, p).map(|n| (i, n))
    }

    // MARK: Mouse

    fn gesture(m: &Mouse) -> Gesture {
        match (m.ctrl, m.alt) {
            (true, true) => Gesture::Move,
            (false, true) => Gesture::Resize,
            _ => Gesture::None,
        }
    }

    fn screen_distance_pt(&self, a: (f64, f64), b: (f64, f64)) -> f64 {
        (a.0 - b.0).hypot(a.1 - b.1) / self.window.dpi_scale
    }

    /// Cursor for the pointer at `m`.
    pub fn hover_cursor(&self, m: &Mouse) -> Cursor {
        match self.interaction {
            Interaction::None => {}
            Interaction::Resize { .. } => return Cursor::Resize,
            Interaction::Item { .. } => return Cursor::Arrow,
            _ => return Cursor::ClosedHand,
        }
        let s = geo::scene_from_view(m.view);
        match Self::gesture(m) {
            Gesture::Move if self.is_on_fridge(s) => Cursor::OpenHand,
            Gesture::Resize if self.is_on_fridge(s) => Cursor::Resize,
            _ if self.door_at(s).is_some() => Cursor::OpenHand,
            _ => Cursor::Arrow,
        }
    }

    pub fn is_interacting(&self) -> bool {
        !matches!(self.interaction, Interaction::None)
    }

    pub fn mouse_down(&mut self, m: &Mouse) -> Vec<Effect> {
        let mut out = Vec::new();
        let s = geo::scene_from_view(m.view);
        match Self::gesture(m) {
            Gesture::Move if self.is_on_fridge(s) => {
                self.interaction = Interaction::Window { start: m.screen, start_origin: self.window.origin };
                self.set_lifted(true);
                out.push(Effect::SetCursor(Cursor::ClosedHand));
                out.push(Effect::Capture(true));
                return out;
            }
            Gesture::Resize if self.is_on_fridge(s) => {
                self.interaction = Interaction::Resize { start: m.screen, start_scale: self.window.user_scale };
                out.push(Effect::SetCursor(Cursor::Resize));
                out.push(Effect::Capture(true));
                return out;
            }
            _ => {}
        }

        if self.notes_mouse_down(m, s, &mut out) {
            return out;
        }

        if let Some(i) = self.door_at(s) {
            if m.clicks >= 2 {
                self.toggle_door(i);
                self.interaction = Interaction::None;
                return out;
            }
            let spec = DoorId::ALL[i].spec();
            let door_x = geo::door_x_under_scene_x(s.x, self.doors[i].angle(), spec).max(MIN_GRAB_X);
            self.interaction = Interaction::DoorPress { door: i, door_x, start: m.screen };
            out.push(Effect::SetCursor(Cursor::ClosedHand));
            out.push(Effect::Capture(true));
            return out;
        }
        if let Some(id) = self.item_at(opening_point(s)) {
            if m.clicks >= 2 {
                // Double-click opens it. Taking it out is Put Back in the right-click menu.
                if let Some(e) = self.store.entry(&id) {
                    out.push(Effect::Open(self.store.path_for(e)));
                }
                self.interaction = Interaction::None;
            } else {
                self.interaction = Interaction::Item { id, start: m.view };
                out.push(Effect::Capture(true));
            }
        }
        out
    }

    pub fn mouse_move(&mut self, m: &Mouse) -> Vec<Effect> {
        let mut out = Vec::new();
        let s = geo::scene_from_view(m.view);
        match self.interaction.clone() {
            Interaction::None => out.push(Effect::SetCursor(self.hover_cursor(m))),
            Interaction::DoorPress { door, door_x, start } => {
                if self.screen_distance_pt(m.screen, start) > DRAG_SLOP {
                    self.interaction = Interaction::Door { door, door_x };
                    let angle = self.doors[door].angle();
                    self.doors[door].driver.hold(angle);
                    self.hold_door_under(door, door_x, s);
                }
            }
            Interaction::Door { door, door_x } => self.hold_door_under(door, door_x, s),
            Interaction::Resize { start, start_scale } => {
                // Drag up or right to grow, down or left to shrink. The feet stay planted.
                let d = self.window.dpi_scale;
                let delta = (start.1 - m.screen.1) / d + (m.screen.0 - start.0) / d * 0.5;
                self.set_user_scale(start_scale * (delta / 320.0).exp(), false, &mut out);
            }
            Interaction::Window { start, start_origin } => {
                let origin = (
                    start_origin.0 + (m.screen.0 - start.0).round() as i32,
                    start_origin.1 + (m.screen.1 - start.1).round() as i32,
                );
                if origin != self.window.origin {
                    self.window.origin = origin;
                    out.push(Effect::WindowMoved);
                }
            }
            Interaction::Item { id, start } => {
                if (m.view.x - start.x).hypot(m.view.y - start.y) > ITEM_DRAG_SLOP {
                    self.interaction = Interaction::None;
                    out.push(Effect::Capture(false));
                    if let Some(e) = self.store.entry(&id) {
                        let path = self.store.path_for(e);
                        if std::fs::symlink_metadata(&path).is_ok() {
                            out.push(Effect::BeginItemDrag { id, path });
                        }
                    }
                }
            }
            Interaction::NotePress { id, door, grab, start, moved } => {
                if !moved {
                    if self.screen_distance_pt(m.screen, start) <= DRAG_SLOP {
                        return out;
                    }
                    self.lift_note(&id);
                    self.interaction = Interaction::NotePress { id: id.clone(), door, grab, start, moved: true };
                }
                let p = geo::door_point_under_scene(s, DoorId::ALL[door].spec());
                self.move_note(&id, Pt::new(p.x - grab.x, p.y - grab.y));
            }
        }
        out
    }

    /// The window moved under a held gesture (DPI change): restart the move from here.
    pub fn rebase_window_drag(&mut self, screen: (f64, f64)) {
        if let Interaction::Window { start, start_origin } = &mut self.interaction {
            *start = screen;
            *start_origin = self.window.origin;
        }
    }

    fn hold_door_under(&mut self, door: usize, door_x: f64, s: Pt) {
        let max = self.doors[door].driver.physics.parameters.max_angle;
        let target = geo::angle_for_door_x(door_x, s.x, max, DoorId::ALL[door].spec());
        self.doors[door].driver.hold(target);
    }

    pub fn mouse_up(&mut self, m: &Mouse) -> Vec<Effect> {
        let mut out = Vec::new();
        let interaction = std::mem::replace(&mut self.interaction, Interaction::None);
        match interaction {
            Interaction::None => return out,
            Interaction::Door { door, .. } => {
                // The door keeps the momentum the hand gave it.
                self.doors[door].driver.release();
            }
            Interaction::DoorPress { .. } => {}
            Interaction::Resize { .. } => {
                let s = self.window.user_scale;
                self.set_user_scale(s, true, &mut out);
                out.push(Effect::SaveSettings);
            }
            Interaction::NotePress { id, door, moved, .. } => {
                if moved {
                    self.finish_note_move(&id, door, &mut out);
                } else {
                    self.cycle_color(&id);
                }
            }
            Interaction::Window { .. } => {
                self.set_lifted(false);
                out.push(Effect::SaveSettings);
            }
            Interaction::Item { .. } => {}
        }
        out.push(Effect::Capture(false));
        out.push(Effect::SetCursor(self.hover_cursor(m)));
        out
    }

    /// The mouse capture was taken away mid-gesture: finish it where it is.
    pub fn cancel_interaction(&mut self) -> Vec<Effect> {
        let mut out = Vec::new();
        match std::mem::replace(&mut self.interaction, Interaction::None) {
            Interaction::Door { door, .. } => self.doors[door].driver.release(),
            Interaction::Resize { .. } => {
                let s = self.window.user_scale;
                self.set_user_scale(s, true, &mut out);
                out.push(Effect::SaveSettings);
            }
            Interaction::Window { .. } => {
                self.set_lifted(false);
                out.push(Effect::SaveSettings);
            }
            Interaction::NotePress { id, door, moved: true, .. } => self.finish_note_move(&id, door, &mut out),
            _ => {}
        }
        out
    }

    fn toggle_door(&mut self, i: usize) {
        let target = if self.doors[i].angle() > TOGGLE_CLOSE_ABOVE { 0.0 } else { geo::SWING_OPEN_ANGLE };
        self.doors[i].driver.swing_to(target);
    }

    fn set_lifted(&mut self, lifted: bool) {
        self.lift.retarget(if lifted { 1.0 } else { 0.0 }, LIFT_DURATION, Curve::Default);
        self.dirty = true;
    }

    fn set_user_scale(&mut self, scale: f64, rerender: bool, out: &mut Vec<Effect>) {
        let old = self.window.scale();
        let s = scale.clamp(MIN_SCALE, MAX_SCALE);
        self.window.user_scale = s;
        self.window.origin = placement::rescale_origin(self.window.origin, old, self.window.scale());
        out.push(Effect::WindowResized { rerender });
        self.dirty = true;
    }

    // MARK: Taking items out

    fn snapshot_item(&self, id: &str) -> Option<ItemVisual> {
        self.store.entry(id).map(|e| self.item_visual(e))
    }

    /// The item has left the store: fade its picture out.
    fn fade_out(&mut self, snapshot: Option<ItemVisual>) {
        if let Some(v) = snapshot {
            self.items.remove(&v.id);
            self.icons.remove(&v.id);
            self.fading_items.push((v, Tween::new(1.0, 0.0, ITEM_FADE_OUT, Curve::Default)));
            self.dirty = true;
        }
    }

    /// Called by the Win32 layer right before its shell drag starts.
    pub fn item_drag_started(&mut self, id: &str) {
        self.dragging_item = Some(id.to_string());
        // The open doors now refuse to close on the user's hand.
        self.set_item_drag(true, None);
        self.dirty = true;
    }

    /// The shell drag finished. Explorer may move the file a little later, so look a few times.
    /// (A shell move often reports "no effect" to the source, so the checks run whatever it said.)
    pub fn item_drag_ended(&mut self, id: &str) -> Vec<Effect> {
        self.set_item_drag(false, None);
        self.dragging_item = None;
        self.dirty = true;
        GONE_CHECKS.iter().map(|&delay| Effect::Schedule { delay, task: Task::CheckGone(id.to_string()) }).collect()
    }

    fn forget_if_gone(&mut self, id: &str) {
        if self.store.entry(id).is_some() && self.store.is_gone(id) {
            let snap = self.snapshot_item(id);
            self.store.remove_entry(id);
            self.fade_out(snap);
        }
    }

    fn put_back(&mut self, id: &str, out: &mut Vec<Effect>) {
        let snap = self.snapshot_item(id);
        match self.store.restore(id) {
            Ok(result) => {
                self.fade_out(snap);
                if let Some(position) = result.desktop_position {
                    out.push(Effect::Schedule {
                        delay: RESTORE_POSITION_DELAY,
                        task: Task::RestoreDesktopPosition { path: result.destination, position },
                    });
                }
            }
            // Already gone from the folder; the store has forgotten it.
            Err(FridgeError::NotFound) => self.fade_out(snap),
            // Could not be moved: it stays in the fridge and keeps its spot.
            Err(_) => out.push(Effect::Beep),
        }
    }

    /// Asks first (`ConfirmMoveAll`); the Win32 layer calls `move_everything_to_desktop` on yes.
    fn confirm_move_everything(&self, out: &mut Vec<Effect>) {
        let count = self.store.entries().len();
        if count == 0 {
            return;
        }
        let message = if count == 1 {
            "The file in the fridge goes back onto your Desktop.".to_string()
        } else {
            format!("All {count} files in the fridge go back onto your Desktop.")
        };
        out.push(Effect::ConfirmMoveAll { title: "Move everything to your Desktop?".into(), message });
    }

    pub fn move_everything_to_desktop(&mut self) -> Vec<Effect> {
        let mut out = Vec::new();
        let mut failed = 0;
        let ids: Vec<String> = self.store.entries().iter().map(|e| e.id.clone()).collect();
        for id in ids {
            let snap = self.snapshot_item(&id);
            match self.store.move_to_desktop(&id) {
                Ok(result) => {
                    self.fade_out(snap);
                    if let Some(position) = result.desktop_position {
                        out.push(Effect::Schedule {
                            delay: RESTORE_POSITION_DELAY,
                            task: Task::RestoreDesktopPosition { path: result.destination, position },
                        });
                    }
                }
                Err(FridgeError::NotFound) => self.fade_out(snap),
                // The file stays in the fridge and keeps its spot.
                Err(_) => failed += 1,
            }
        }
        if failed > 0 {
            out.push(Effect::Alert {
                title: if failed == 1 { "1 file could not be moved.".into() } else { format!("{failed} files could not be moved.") },
                message: if failed == 1 { "It is still in the fridge.".into() } else { "They are still in the fridge.".into() },
            });
        }
        out
    }

    // MARK: Putting items in

    /// While a file is dragged in or out, no open door may close on the user's hand. Shut doors
    /// are left alone; `also` covers a door that is only now swinging open for a hovering file.
    fn set_item_drag(&mut self, active: bool, also: Option<usize>) {
        for i in 0..2 {
            if !active {
                self.doors[i].driver.set_item_drag(false);
            } else if self.doors[i].has_opened || Some(i) == also {
                self.doors[i].driver.set_item_drag(true);
            }
        }
    }

    /// Which door's compartment a scene point is in, by height. Outside the cabinet it is the door under it.
    fn compartment(&self, s: Pt) -> Option<usize> {
        if OPENING.contains(s) {
            return (0..2).find(|&i| {
                let f = DoorId::ALL[i].spec().frame;
                f.min_y() <= s.y && s.y < f.max_y()
            });
        }
        self.door_at(s)
    }

    fn drop_shelf(&self, s: Pt) -> Option<usize> {
        if self.store.is_full() || !OPENING.contains(s) {
            return None;
        }
        let i = self.compartment(s)?;
        if !self.doors[i].interactive {
            return None;
        }
        // The nearest shelf behind the open door at that height.
        let y = s.y - OPENING.min_y();
        DoorId::ALL[i].spec().shelves.iter().copied().min_by(|&a, &b| {
            let da = (InteriorGeometry::SHELF_FRONT_Y[a] - y).abs();
            let db = (InteriorGeometry::SHELF_FRONT_Y[b] - y).abs();
            da.total_cmp(&db)
        })
    }

    /// Like a spring-loaded folder: a file hovering over a shut door swings it open, and it will
    /// not close on the user's hand while the file is over it.
    fn spring_open(&mut self, s: Pt, info: &DragInfo) {
        if info.files.is_empty() || self.store.is_full() {
            return;
        }
        let Some(i) = self.compartment(s) else { return };
        if !self.doors[i].interactive && !self.doors[i].driver.is_held() {
            self.doors[i].driver.swing_to(geo::SWING_OPEN_ANGLE);
        }
        self.set_item_drag(true, Some(i));
    }

    /// Pictures (only pictures) and text dragged onto a shut door get stuck on it.
    fn stick_target(&self, s: Pt, info: &DragInfo) -> Option<(usize, Pt)> {
        let i = self.shut_door(s)?;
        let spec = DoorId::ALL[i].spec();
        if self.notes.is_full(spec.name) {
            return None;
        }
        let has_image = !info.files.is_empty() && info.files.iter().all(|f| is_image(f));
        let has_text = info.files.is_empty() && info.text.as_deref().map(|t| !t.trim().is_empty()).unwrap_or(false);
        if !(has_image || has_text) {
            return None;
        }
        Some((i, geo::door_point_under_scene(s, spec)))
    }

    fn stick_effect(allowed: Allowed) -> DropEffect {
        // Only a thumbnail is made and the original is never touched, so prefer Copy: with Move,
        // the source would delete the original.
        if allowed.copy {
            DropEffect::Copy
        } else if allowed.link {
            DropEffect::Link
        } else if allowed.move_ {
            DropEffect::Move
        } else {
            DropEffect::None
        }
    }

    /// A drag from elsewhere entered or moved over the fridge.
    pub fn drag_over(&mut self, view: Pt, info: &DragInfo, allowed: Allowed) -> (DropEffect, Vec<Effect>) {
        let mut out = Vec::new();
        let s = geo::scene_from_view(view);
        if let Some((door, _)) = self.stick_target(s, info) {
            let is_picture = !info.files.is_empty();
            if is_picture && self.picture_spring.map(|p| p.0) != Some(door) && !self.store.is_full() {
                self.spring_token += 1;
                self.picture_spring = Some((door, self.spring_token));
                out.push(Effect::Schedule { delay: PICTURE_SPRING_DELAY, task: Task::PictureSpring { door, token: self.spring_token } });
            }
            return (Self::stick_effect(allowed), out);
        }
        self.picture_spring = None;
        self.spring_open(s, info);
        let effect = if self.drop_shelf(s).is_some() && !info.files.is_empty() && allowed.move_ {
            DropEffect::Move
        } else {
            DropEffect::None
        };
        (effect, out)
    }

    pub fn drag_leave(&mut self) {
        self.picture_spring = None;
        self.set_item_drag(false, None);
    }

    /// The drop itself. Nothing is moved here: the caller defers the work until the drag has
    /// fully ended (the source's drag loop is waiting on us).
    pub fn drop(&mut self, view: Pt, info: &DragInfo, allowed: Allowed) -> (DropEffect, DropAction) {
        let s = geo::scene_from_view(view);
        self.picture_spring = None;
        let result = if let Some((door, point)) = self.stick_target(s, info) {
            if !info.files.is_empty() {
                let files = info.files.iter().filter(|f| is_image(f)).cloned().collect();
                (Self::stick_effect(allowed), DropAction::StickPhotos { door, point, files })
            } else {
                let text = info.text.clone().unwrap_or_default().trim().to_string();
                (Self::stick_effect(allowed), DropAction::StickText { door, point, text })
            }
        } else if let (Some(shelf), false, true) = (self.drop_shelf(s), info.files.is_empty(), allowed.move_) {
            (DropEffect::Move, DropAction::Store { shelf, files: info.files.clone() })
        } else {
            (DropEffect::None, DropAction::Nothing)
        };
        self.set_item_drag(false, None);
        result
    }

    /// Moves dropped files in. `files` carries each file's Desktop icon position, if it had one.
    pub fn store_files(&mut self, files: Vec<(PathBuf, Option<(f64, f64)>)>, shelf: usize, now: f64) -> Vec<Effect> {
        let mut out = Vec::new();
        for (path, position) in files {
            match self.store.store(&path, position, shelf as i64, now) {
                Ok(entry) => {
                    self.items.insert(entry.id.clone(), ItemState { frost: FrostState::new(0.0, 0.0), added: Some(0.0) });
                    out.push(Effect::NeedIcon { id: entry.id.clone(), path: self.store.path_for(&entry) });
                    self.dirty = true;
                }
                Err(_) => out.push(Effect::Beep),
            }
        }
        out
    }

    pub fn set_icon(&mut self, id: &str, icon: Option<Arc<Image>>) {
        if self.store.entry(id).is_none() {
            return;
        }
        match icon {
            Some(i) => {
                self.icons.insert(id.to_string(), i);
            }
            None => {
                self.icons.remove(id);
            }
        }
        self.dirty = true;
    }

    /// Items that need an icon at launch.
    pub fn icon_requests(&self) -> Vec<(String, PathBuf)> {
        self.store.entries().iter().map(|e| (e.id.clone(), self.store.path_for(e))).collect()
    }

    pub fn run_task(&mut self, task: Task) -> Vec<Effect> {
        match task {
            Task::CheckGone(id) => self.forget_if_gone(&id),
            Task::PictureSpring { door, token } => {
                if self.picture_spring == Some((door, token)) {
                    self.picture_spring = None;
                    self.doors[door].driver.swing_to(geo::SWING_OPEN_ANGLE);
                    self.set_item_drag(true, Some(door));
                }
            }
            // Carried out by the Win32 layer.
            Task::RestoreDesktopPosition { .. } => {}
        }
        Vec::new()
    }

    // MARK: Menu

    pub fn context_menu(&self, view: Pt, start_with_windows: bool) -> Vec<Entry> {
        let s = geo::scene_from_view(view);
        let target = if let Some((_, note)) = self.note_under(s) {
            match note.kind {
                NoteKind::Note => menu::Target::Note { id: note.id, color: note.color },
                NoteKind::Photo => menu::Target::Photo {
                    id: note.id,
                    original: note.original_path.map(PathBuf::from).filter(|p| p.exists()),
                },
            }
        } else if let Some(id) = self.item_at(opening_point(s)) {
            menu::Target::Item { id }
        } else {
            menu::Target::Nothing
        };
        menu::build(target, self.store.entries().is_empty(), start_with_windows)
    }

    /// Runs a menu command. Start with Windows and Quit are handled by the Win32 layer.
    pub fn run_command(&mut self, command: Command) -> Vec<Effect> {
        let mut out = Vec::new();
        match command {
            Command::EditNote(id) => self.begin_editing(&id, false, &mut out),
            Command::SetNoteColor(id, c) => self.set_color(&id, c),
            Command::PeelNote(id) | Command::TakePhotoDown(id) => self.remove_note(&id, &mut out),
            Command::OpenOriginal(path) => out.push(Effect::Open(path)),
            Command::OpenItem(id) => {
                if let Some(e) = self.store.entry(&id) {
                    out.push(Effect::Open(self.store.path_for(e)));
                }
            }
            Command::PutBack(id) => self.put_back(&id, &mut out),
            Command::ShowInExplorer(id) => {
                if let Some(e) = self.store.entry(&id) {
                    out.push(Effect::ShowInExplorer(self.store.path_for(e)));
                }
            }
            Command::OpenFridgeFolder => out.push(Effect::Open(self.store.root.clone())),
            Command::MoveEverythingToDesktop => self.confirm_move_everything(&mut out),
            Command::ToggleStartWithWindows | Command::Quit => {}
        }
        out
    }

    // MARK: Sticky notes and photo magnets (Ctrl)

    /// Ctrl-click a shut door for a new note, Ctrl-click a note to change its colour, Ctrl-drag to
    /// move it, double-click a note to write on it. True when the click was about notes.
    fn notes_mouse_down(&mut self, m: &Mouse, s: Pt, out: &mut Vec<Effect>) -> bool {
        let Some(i) = self.shut_door(s) else { return false };
        let spec = DoorId::ALL[i].spec();
        let p = geo::door_point_under_scene(s, spec);
        let stick = m.ctrl && !m.alt;
        if let Some(note) = self.note_at(i, p) {
            if stick {
                let grab = Pt::new(p.x - note.x, p.y - note.y);
                self.interaction = Interaction::NotePress { id: note.id, door: i, grab, start: m.screen, moved: false };
                out.push(Effect::SetCursor(Cursor::ClosedHand));
                out.push(Effect::Capture(true));
                return true;
            }
            if m.clicks >= 2 && note.kind == NoteKind::Note {
                self.begin_editing(&note.id, false, out);
                self.interaction = Interaction::None;
                return true;
            }
            // A plain grab on a note still works the door; a double-click on a photo toggles it.
            return false;
        }
        if stick && m.clicks == 1 {
            self.add_note(i, p, String::new(), true, out);
            self.interaction = Interaction::None;
            return true;
        }
        false
    }

    fn random_tilt(&mut self) -> f64 {
        self.rng.range(-0.07, 0.07)
    }

    fn add_note(&mut self, door: usize, p: Pt, text: String, edit: bool, out: &mut Vec<Effect>) {
        let spec = DoorId::ALL[door].spec();
        if self.notes.is_full(spec.name) {
            out.push(Effect::Beep);
            return;
        }
        // The next colour in the palette, so a few notes in a row come out different.
        let color = self.notes.next_note_color();
        let p = clamp_note(p, spec, (NOTE_SIZE, NOTE_SIZE));
        let tilt = self.random_tilt();
        let mut note = DoorNote::new_note(spec.name, p.x, p.y, color, tilt);
        note.text = text;
        let id = note.id.clone();
        self.notes.add(note);
        self.note_anims.insert(id.clone(), NoteAnim { pop: Some(0.0), ..NoteAnim::default() });
        self.dirty = true;
        if edit {
            self.begin_editing(&id, true, out);
        }
    }

    fn add_photo(&mut self, door: usize, path: &Path, p: Pt, out: &mut Vec<Effect>) -> bool {
        let spec = DoorId::ALL[door].spec();
        if self.notes.is_full(spec.name) {
            out.push(Effect::Beep);
            return false;
        }
        let Some(png) = fridge_art::make_photo_thumbnail(path) else { return false };
        let Some(image) = fridge_art::decode_png(&png) else { return false };
        let Ok(name) = self.notes.save_photo(&png) else { return false };
        let size = fridge_art::photo_size(image.width, image.height);
        let p = clamp_note(p, spec, size);
        let color = (self.rng.next_u64() % 4) as usize;
        let tilt = self.random_tilt() * 0.7;
        let mut note = DoorNote::new_note(spec.name, p.x, p.y, color, tilt);
        note.kind = NoteKind::Photo;
        note.photo_name = Some(name);
        note.original_path = Some(path.to_string_lossy().into_owned());
        let id = note.id.clone();
        self.notes.add(note);
        self.photos.insert(id.clone(), Arc::new(image));
        self.note_anims.insert(id, NoteAnim { pop: Some(0.0), ..NoteAnim::default() });
        self.dirty = true;
        true
    }

    /// Pictures dropped on a shut door: up to four, fanned out a little.
    pub fn stick_photos(&mut self, door: usize, point: Pt, files: &[PathBuf]) -> Vec<Effect> {
        let mut out = Vec::new();
        let mut placed = false;
        for (offset, file) in files.iter().take(4).enumerate() {
            let p = Pt::new(point.x + offset as f64 * 14.0, point.y - offset as f64 * 10.0);
            placed = self.add_photo(door, file, p, &mut out) || placed;
        }
        if !placed && !out.contains(&Effect::Beep) {
            out.push(Effect::Beep);
        }
        out
    }

    pub fn stick_text(&mut self, door: usize, point: Pt, text: &str) -> Vec<Effect> {
        let mut out = Vec::new();
        let text = fridge_core::notes::truncate_utf16(text.trim(), DoorNotesStore::MAX_TEXT_LENGTH);
        if !text.is_empty() {
            self.add_note(door, point, text, false, &mut out);
        }
        out
    }

    fn lift_note(&mut self, id: &str) {
        let Some(note) = self.notes.note(id).cloned() else { return };
        self.notes.update(note, true);
        self.note_anims.entry(id.to_string()).or_default().lifted.retarget(1.0, NOTE_LIFT_DURATION, Curve::Default);
        self.dirty = true;
    }

    /// Follows the pointer; saved on release without writing to disk on every move.
    fn move_note(&mut self, id: &str, p: Pt) {
        let current = self.pending_move.take().filter(|n| n.id == id).or_else(|| self.notes.note(id).cloned());
        let Some(mut note) = current else { return };
        note.x = p.x;
        note.y = p.y;
        self.pending_move = Some(note);
        self.dirty = true;
    }

    /// Drops a dragged note. Let go off the door and it peels away.
    fn finish_note_move(&mut self, id: &str, door: usize, out: &mut Vec<Effect>) {
        self.note_anims.entry(id.to_string()).or_default().lifted.retarget(0.0, NOTE_LIFT_DURATION, Curve::Default);
        let pending = self.pending_move.take().filter(|n| n.id == id);
        let Some(mut note) = pending.or_else(|| self.notes.note(id).cloned()) else { return };
        let spec = DoorId::ALL[door].spec();
        let p = Pt::new(note.x, note.y);
        let inside = Rect::new(0.0, 0.0, spec.width(), spec.height()).inset(-4.0).contains(p);
        if !inside {
            // Peel from where it was let go (the store copy still has the old spot).
            self.notes.update(note, false);
            self.remove_note(id, out);
            return;
        }
        let size = self.note_size(&note);
        let clamped = clamp_note(p, spec, size);
        note.x = clamped.x;
        note.y = clamped.y;
        self.notes.update(note, false);
        if (clamped.x - p.x).abs() > 1e-9 || (clamped.y - p.y).abs() > 1e-9 {
            self.note_anims.entry(id.to_string()).or_default().settle =
                Some((p, Tween::new(0.0, 1.0, NOTE_SETTLE_DURATION, Curve::Default)));
        }
        self.dirty = true;
    }

    fn set_color(&mut self, id: &str, color: usize) {
        let Some(mut note) = self.notes.note(id).cloned() else { return };
        note.color = color % menu::NOTE_COLOR_NAMES.len();
        self.notes.update(note, false);
        self.dirty = true;
    }

    fn cycle_color(&mut self, id: &str) {
        if let Some(note) = self.notes.note(id) {
            let next = (note.color + 1) % menu::NOTE_COLOR_NAMES.len();
            self.set_color(id, next);
        }
    }

    /// Peels the note off: it tips, drops and fades, then it is gone (a photo's PNG too).
    fn remove_note(&mut self, id: &str, out: &mut Vec<Effect>) {
        if self.editing.as_ref().map(|e| e.0 == id).unwrap_or(false) {
            self.editing = None;
            out.push(Effect::EndEditor);
        }
        if self.pending_move.as_ref().map(|p| p.id == id).unwrap_or(false) {
            self.pending_move = None;
        }
        self.note_anims.remove(id);
        let visual = self.notes.note(id).and_then(|n| self.note_visual(n));
        self.notes.remove(id);
        self.photos.remove(id);
        if let Some(v) = visual {
            self.peeling.push(Peeling { visual: v, elapsed: 0.0 });
        }
        self.dirty = true;
    }

    // MARK: Writing on a note

    pub fn editing_id(&self) -> Option<&str> {
        self.editing.as_ref().map(|e| e.0.as_str())
    }

    fn begin_editing(&mut self, id: &str, is_new: bool, out: &mut Vec<Effect>) {
        if self.editing.take().is_some() {
            out.push(Effect::EndEditor);
        }
        let Some(note) = self.notes.note(id).cloned() else { return };
        if note.kind != NoteKind::Note {
            return;
        }
        let Some(door) = DoorId::from_name(&note.door) else { return };
        let s = geo::scene_front_point(Pt::new(note.x, note.y), door.spec());
        let center = Pt::new(s.x + BODY_ORIGIN.x, s.y + BODY_ORIGIN.y);
        self.editing = Some((id.to_string(), is_new));
        out.push(Effect::BeginEditor(EditorRequest { id: id.to_string(), center, tilt: note.tilt, text: note.text, color: note.color }));
        self.dirty = true;
    }

    /// The editor closed. `Some(text)` saves (Enter, click elsewhere), `None` cancels (Esc).
    /// A new note left empty is thrown away; an existing one emptied stays blank.
    pub fn finish_editing(&mut self, text: Option<String>) -> Vec<Effect> {
        let mut out = Vec::new();
        let Some((id, is_new)) = self.editing.take() else { return out };
        out.push(Effect::EndEditor);
        self.dirty = true;
        match text {
            None => {
                if is_new {
                    self.remove_note(&id, &mut out);
                }
            }
            Some(text) => {
                let text = text.trim().to_string();
                if text.is_empty() && is_new {
                    self.remove_note(&id, &mut out);
                } else if let Some(mut note) = self.notes.note(&id).cloned() {
                    note.text = fridge_core::notes::truncate_utf16(&text, DoorNotesStore::MAX_TEXT_LENGTH);
                    self.notes.update(note, false);
                }
            }
        }
        out
    }
}

/// Shelf ascending, back row first, column ascending.
fn sort_draw_order(entries: &mut [&FridgeEntry]) {
    entries.sort_by(|a, b| {
        let (ra, ca) = ShelfLayout::row_and_column(a.slot);
        let (rb, cb) = ShelfLayout::row_and_column(b.slot);
        a.shelf.cmp(&b.shelf).then(rb.cmp(&ra)).then(ca.cmp(&cb))
    });
}

/// An item's click rectangle in opening coordinates.
fn item_rect(e: &FridgeEntry) -> Rect {
    let (row, column) = ShelfLayout::row_and_column(e.slot);
    let (x, y, s) = InteriorGeometry::anchor(e.shelf, row, column);
    let (jitter, _) = e.jitter_and_tilt();
    let p = InteriorGeometry::BASE_ICON_SIZE * s;
    Rect::new(x + jitter - p / 2.0, y, p, p)
}

fn opening_point(s: Pt) -> Pt {
    Pt::new(s.x - OPENING.min_x(), s.y - OPENING.min_y())
}

/// Keeps a note's centre far enough inside the door that it never hangs off the edge.
fn clamp_note(p: Pt, door: &DoorSpec, size: (f64, f64)) -> Pt {
    let mx = (size.0 / 2.0 + 6.0).min(door.width() / 2.0);
    let my = (size.1 / 2.0 + 6.0).min(door.height() / 2.0);
    Pt::new(p.x.clamp(mx, door.width() - mx), p.y.clamp(my, door.height() - my))
}

/// Picture files that can become photo magnets.
pub fn is_image(path: &Path) -> bool {
    const EXT: [&str; 11] = ["png", "jpg", "jpeg", "jfif", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"];
    path.extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .map(|e| EXT.contains(&e.as_str()))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests;
