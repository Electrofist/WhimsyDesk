//! The compositor: static layers rendered once per scale and light mode, then per frame the
//! shadows, the body (cabinet, interior, frost, items), compartment light, divider, the two doors
//! in perspective, hinges and fog.
//!
//! Everything static is rendered straight into frame-aligned sprites, so nothing is resampled
//! except the doors, items, notes and fog.

use crate::canvas::{self, frame_transform, rect_path, rgba};
use crate::fog;
use crate::frost_bake;
use crate::notes::{self, NoteFont};
use crate::pixel::*;
use crate::recipes::{self, CONTACT_SHADOW_SIZE, HINGE_SIZE, LIFT_SHADOW_SIZE};
use crate::{Assets, Frame, ItemVisual, NoteVisual, SceneState};
use fridge_core::geometry::{
    DoorSpec, Rect, BIN_DEPTH, BIN_INSET, BODY_ORIGIN, BODY_SIZE, DOORS, DOOR_HALF_THICKNESS, EYE_DISTANCE, HINGE_PLATE_Y, OPENING,
    VANISHING, WINDOW_SIZE,
};
use fridge_core::geometry::smoothstep;
use fridge_core::{InteriorGeometry, ShelfLayout};
use std::collections::HashMap;
use std::sync::Arc;
use tiny_skia::{Pixmap, Transform};

/// Below this a door is drawn exactly shut (and the cached shut sprite is used).
const SHUT_EPS: f64 = 0.0005;
const DEG: f64 = std::f64::consts::PI / 180.0;
/// The door's lift off the cabinet plane (half thickness plus a hair).
const DOOR_LIFT: f64 = DOOR_HALF_THICKNESS + 0.5;
const HINGE_Z: f64 = DOOR_HALF_THICKNESS * 2.0 + 2.0;
const MAX_VISUAL_ANGLE: f64 = 105.2 * DEG;

struct Lighting {
    glow: (f32, f32, f32, f32),
    darkness_peak: f32,
    frost: f32,
}

fn lighting(dark: bool) -> Lighting {
    if dark {
        Lighting { glow: (0.08, 0.80, 1.0, 0.46), darkness_peak: 0.48, frost: 0.95 }
    } else {
        Lighting { glow: (0.55, 0.85, 0.96, 0.28), darkness_peak: 0.60, frost: 0.80 }
    }
}

struct Slice {
    /// Coverage of the slice rect, one byte per pixel, with its frame position.
    mask: Vec<u8>,
    glow: Sprite,
}

struct DoorArt {
    front: Bitmap,
    liner: Mips,
    edge: Mips,
    floor: Mips,
    lips: Vec<Mips>,
    cheeks: Vec<Mips>,
}

struct Static {
    lift_shadow: Sprite,
    contact_shadow: Sprite,
    body: Sprite,
    divider: Sprite,
    hinges: Vec<Sprite>,
    slices: Vec<Slice>,
    doors: Vec<DoorArt>,
    item_shadow: Bitmap,
}

#[derive(Clone, PartialEq)]
struct ItemKey {
    id: String,
    shelf: usize,
    slot: usize,
    jitter: u64,
    tilt: u64,
    bucket: i32,
    icon: usize,
    opacity: u32,
    lift: u32,
}

#[derive(Clone, PartialEq)]
struct NoteKey {
    id: String,
    photo: bool,
    x: u64,
    y: u64,
    tilt: u64,
    color: usize,
    text: String,
    icon: usize,
    hide: bool,
    scale: u32,
    opacity: u32,
    rot: u64,
    off: (u64, u64),
    lifted: u32,
}

struct ItemBake {
    bucket: i32,
    icon: usize,
    side: usize,
    bm: Bitmap,
}

struct NoteSprite {
    key: (String, usize, usize, bool, bool),
    bm: Bitmap,
    /// Size in points of the sprite and of its shadow-casting rect (print only for photos).
    size: (f64, f64),
    shadow_rect: (f64, f64),
}

struct FrontCache {
    key: Vec<NoteKey>,
    /// The texture's rect in door space (the door, grown to fit notes hanging over the edge).
    rect: Rect,
    mips: Mips,
}

pub struct Engine {
    assets: Arc<Assets>,
    font: Option<NoteFont>,
    pub scale: f32,
    pub dark: bool,
    w: usize,
    h: usize,
    st: Option<Static>,
    body_items: Option<(Vec<ItemKey>, Sprite)>,
    items: HashMap<String, ItemBake>,
    note_sprites: HashMap<String, NoteSprite>,
    fronts: [Option<FrontCache>; 2],
    shut: [Option<(Vec<NoteKey>, i32, Sprite)>; 2],
    fog_masks: HashMap<(usize, usize), ShadowMaskArc>,
    /// Alpha spans of fog frames (1x or 2x set, frame), kept for the life of the renderer.
    fog_spans: HashMap<(usize, usize), Arc<fog::Spans>>,
    pub frame: Frame,
    last: Option<SceneState>,
}

type ShadowMaskArc = Arc<fog::ShadowMask>;

fn fbits(v: f64) -> u64 {
    v.to_bits()
}

fn item_key(i: &ItemVisual) -> ItemKey {
    ItemKey {
        id: i.id.clone(),
        shelf: i.shelf,
        slot: i.slot,
        jitter: fbits(i.jitter_x),
        tilt: fbits(i.tilt),
        bucket: i.frost.bucket,
        icon: i.icon.as_ref().map(|a| Arc::as_ptr(a) as usize).unwrap_or(0),
        opacity: i.opacity.to_bits(),
        lift: i.lift.to_bits(),
    }
}

fn note_key(n: &NoteVisual) -> NoteKey {
    NoteKey {
        id: n.id.clone(),
        photo: n.is_photo,
        x: fbits(n.x),
        y: fbits(n.y),
        tilt: fbits(n.tilt),
        color: n.color,
        text: n.text.clone(),
        icon: n.photo.as_ref().map(|a| Arc::as_ptr(a) as usize).unwrap_or(0),
        hide: n.hide_text,
        scale: n.scale.to_bits(),
        opacity: n.opacity.to_bits(),
        rot: fbits(n.rotation_extra),
        off: (fbits(n.offset.0), fbits(n.offset.1)),
        lifted: n.lifted.to_bits(),
    }
}

fn same_state(a: &SceneState, b: &SceneState) -> bool {
    a.door_angles == b.door_angles
        && a.lift == b.lift
        && a.fog.map(|f| (f.elapsed, f.lite)) == b.fog.map(|f| (f.elapsed, f.lite))
        && a.items.len() == b.items.len()
        && a.notes.len() == b.notes.len()
        && a.items.iter().zip(&b.items).all(|(x, y)| item_key(x) == item_key(y))
        && a.notes.iter().zip(&b.notes).all(|(x, y)| note_key(x) == note_key(y) && x.door == y.door)
}

/// erf, Abramowitz and Stegun 7.1.26 (error below 1.5e-7).
fn erf(x: f64) -> f64 {
    let s = x.signum();
    let x = x.abs();
    let t = 1.0 / (1.0 + 0.327_591_1 * x);
    let y = 1.0 - (((((1.061_405_429 * t - 1.453_152_027) * t) + 1.421_413_741) * t - 0.284_496_736) * t + 0.254_829_592) * t * (-x * x).exp();
    s * y
}

impl Engine {
    pub fn new(assets: Arc<Assets>, scale: f32, dark: bool) -> Engine {
        let font = NoteFont::new(&assets.note_font);
        let mut e = Engine {
            assets,
            font,
            scale: scale.max(0.1),
            dark,
            w: 0,
            h: 0,
            st: None,
            body_items: None,
            items: HashMap::new(),
            note_sprites: HashMap::new(),
            fronts: [None, None],
            shut: [None, None],
            fog_masks: HashMap::new(),
            fog_spans: HashMap::new(),
            frame: Frame::default(),
            last: None,
        };
        e.rebuild();
        e
    }

    pub fn set_scale(&mut self, scale: f32) {
        let scale = scale.max(0.1);
        if scale != self.scale {
            self.scale = scale;
            self.items.clear();
            self.note_sprites.clear();
            self.rebuild();
        }
    }

    pub fn set_dark(&mut self, dark: bool) {
        if dark != self.dark {
            self.dark = dark;
            self.rebuild();
        }
    }

    pub fn size(&self) -> (u32, u32) {
        (self.w as u32, self.h as u32)
    }

    fn rebuild(&mut self) {
        let s = self.scale as f64;
        self.w = ((WINDOW_SIZE.0 * s).round() as usize).max(1);
        self.h = ((WINDOW_SIZE.1 * s).round() as usize).max(1);
        self.st = Some(self.render_static());
        self.body_items = None;
        self.fronts = [None, None];
        self.shut = [None, None];
        self.last = None;
    }

    // MARK: Frame space

    fn fh(&self) -> f32 {
        self.h as f32
    }

    /// Integer pixel box covering a view-space rect, plus a margin.
    fn region(&self, r: (f64, f64, f64, f64), margin: i32) -> (i32, i32, u32, u32) {
        let s = self.scale as f64;
        let fh = self.h as f64;
        let x0 = (r.0 * s).floor() as i32 - margin;
        let x1 = ((r.0 + r.2) * s).ceil() as i32 + margin;
        let y0 = (fh - (r.1 + r.3) * s).floor() as i32 - margin;
        let y1 = (fh - r.1 * s).ceil() as i32 + margin;
        (x0, y0, (x1 - x0).max(1) as u32, (y1 - y0).max(1) as u32)
    }

    /// A pixmap for a frame region and the transform from view points into it.
    fn region_canvas(&self, reg: (i32, i32, u32, u32)) -> (Pixmap, Transform) {
        let pm = Pixmap::new(reg.2, reg.3).unwrap();
        (pm, frame_transform(self.scale, self.fh(), reg.0, reg.1))
    }

    fn sprite(pm: Pixmap, reg: (i32, i32, u32, u32)) -> Sprite {
        Sprite { bm: Bitmap::from_pixmap(pm), x: reg.0, y: reg.1 }
    }

    fn render_static(&self) -> Static {
        let s = self.scale;
        let light = lighting(self.dark);
        let (bx, by) = (BODY_ORIGIN.x, BODY_ORIGIN.y);
        let scene_tf = |tf: Transform| tf.pre_translate(bx as f32, by as f32);

        // Shadows.
        let lift_rect = (bx + BODY_SIZE.0 / 2.0 - LIFT_SHADOW_SIZE.0 / 2.0, by - LIFT_SHADOW_SIZE.1 / 2.0 - 8.0, LIFT_SHADOW_SIZE.0, LIFT_SHADOW_SIZE.1);
        let reg = self.region(lift_rect, 1);
        let (mut pm, tf) = self.region_canvas(reg);
        recipes::lift_shadow(&mut pm, tf.pre_translate(lift_rect.0 as f32, lift_rect.1 as f32));
        let lift_shadow = Self::sprite(pm, reg);

        let contact_rect = (
            bx + BODY_SIZE.0 / 2.0 - CONTACT_SHADOW_SIZE.0 / 2.0,
            by - CONTACT_SHADOW_SIZE.1 / 2.0 + 3.0,
            CONTACT_SHADOW_SIZE.0,
            CONTACT_SHADOW_SIZE.1,
        );
        let reg = self.region(contact_rect, 1);
        let (mut pm, tf) = self.region_canvas(reg);
        recipes::contact_shadow(&mut pm, tf.pre_translate(contact_rect.0 as f32, contact_rect.1 as f32));
        let contact_shadow = Self::sprite(pm, reg);

        // Body: cabinet, interior, frost.
        let reg = self.region((bx, by, BODY_SIZE.0, BODY_SIZE.1), 2);
        let (mut pm, tf) = self.region_canvas(reg);
        let stf = scene_tf(tf);
        recipes::cabinet(&mut pm, stf);
        let otf = stf.pre_translate(OPENING.x as f32, OPENING.y as f32);
        let clip = canvas::mask(&pm, &rect_path(0.0, 0.0, OPENING.w, OPENING.h), otf);
        recipes::interior(&mut pm, otf, &clip, s);
        let mut frost = Pixmap::new(pm.width(), pm.height()).unwrap();
        recipes::interior_frost(&mut frost, otf, &clip);
        canvas::draw_layer(&mut pm, &frost, light.frost, None);
        let body = Self::sprite(pm, reg);

        // Divider.
        let d = recipes::DIVIDER;
        let reg = self.region((bx + d.0, by + d.1, d.2, d.3), 1);
        let (mut pm, tf) = self.region_canvas(reg);
        recipes::divider(&mut pm, scene_tf(tf));
        let divider = Self::sprite(pm, reg);

        // Hinges, in front of the doors (z 20), so slightly enlarged about the vanishing point.
        let hinge_x = recipes_hinge_x();
        let wz = 1.0 - HINGE_Z / EYE_DISTANCE;
        let mut hinges = Vec::new();
        for &y in HINGE_PLATE_Y.iter() {
            let px0 = VANISHING.x + (hinge_x - VANISHING.x) / wz;
            let py0 = VANISHING.y + (y - VANISHING.y) / wz;
            let r = (bx + px0, by + py0, HINGE_SIZE.0 / wz, HINGE_SIZE.1 / wz);
            let reg = self.region(r, 2);
            let (mut pm, tf) = self.region_canvas(reg);
            let htf = tf.pre_translate(r.0 as f32, r.1 as f32).pre_scale((1.0 / wz) as f32, (1.0 / wz) as f32);
            recipes::hinge(&mut pm, htf, s);
            hinges.push(Self::sprite(pm, reg));
        }

        // Compartment slices: darkness coverage and glow.
        let mut slices = Vec::new();
        for spec in DOORS.iter() {
            let sl = spec.opening_slice();
            let r = (bx + OPENING.x + sl.x, by + OPENING.y + sl.y, sl.w, sl.h);
            let reg = self.region(r, 1);
            let (mut pm, tf) = self.region_canvas(reg);
            canvas::fill(&mut pm, &rect_path(r.0, r.1, r.2, r.3), rgba(0.0, 0.0, 0.0, 1.0), tf, None);
            let mask: Vec<u8> = pm.data().chunks_exact(4).map(|p| p[3]).collect();
            let (mut gpm, gtf) = self.region_canvas(reg);
            recipes::glow(&mut gpm, gtf, r, light.glow);
            slices.push(Slice { mask, glow: Self::sprite(gpm, reg) });
        }

        // Doors.
        let mut doors = Vec::new();
        for (i, spec) in DOORS.iter().enumerate() {
            let art_img = if i == 0 { &self.assets.door_fridge } else { &self.assets.door_freezer };
            let pw = ((spec.width() as f32 * s).round() as u32).max(1);
            let ph = ((spec.height() as f32 * s).round() as u32).max(1);
            let art = if art_img.width > 0 {
                let data = resize(art_img.width as usize, art_img.height as usize, &art_img.data, pw as usize, ph as usize);
                Pixmap::from_vec(data, tiny_skia::IntSize::from_wh(pw, ph).unwrap())
            } else {
                None
            };
            let front = Bitmap::from_pixmap(recipes::door_front(spec, art.as_ref(), s));
            let liner = Mips::new(Bitmap::from_pixmap(recipes::door_back(spec, s)), 5);
            let edge = Mips::new(Bitmap::from_pixmap(recipes::door_edge(spec, s)), 4);
            let floor = Mips::new(Bitmap::from_pixmap(recipes::bin_floor(spec, s)), 5);
            let mut lips = Vec::new();
            let mut cheeks = Vec::new();
            for b in 0..spec.bin_y.len() {
                let lh = recipes::bin_lip_height(spec, b);
                lips.push(Mips::new(Bitmap::from_pixmap(recipes::bin_lip(spec, lh, s)), 5));
                cheeks.push(Mips::new(Bitmap::from_pixmap(recipes::bin_cheek(lh, s)), 4));
            }
            doors.push(DoorArt { front, liner, edge, floor, lips, cheeks });
        }

        let item_shadow = Bitmap::from_pixmap(recipes::item_shadow(s));

        Static { lift_shadow, contact_shadow, body, divider, hinges, slices, doors, item_shadow }
    }

    // MARK: Projection

    /// A point on a door (door space, `pz` toward the viewer) to frame pixels.
    fn project(&self, spec: &DoorSpec, angle: f64, px: f64, py: f64, pz: f64, rise: f64) -> (f64, f64, f64) {
        let (sa, ca) = angle.sin_cos();
        let x = spec.frame.x + px * ca - pz * sa;
        let y = spec.frame.y + py;
        let z = DOOR_LIFT + px * sa + pz * ca;
        let (fx, fy) = self.scene_to_px(x, y, z, rise);
        (fx, fy, z)
    }

    fn scene_to_px(&self, x: f64, y: f64, z: f64, rise: f64) -> (f64, f64) {
        let w = 1.0 - z / EYE_DISTANCE;
        let sx = VANISHING.x + (x - VANISHING.x) / w;
        let sy = VANISHING.y + (y - VANISHING.y) / w;
        let s = self.scale as f64;
        ((sx + BODY_ORIGIN.x) * s, self.h as f64 - (sy + BODY_ORIGIN.y + rise) * s)
    }

    /// Draws a door face given its four corners in door space (top left, top right, bottom right,
    /// bottom left of the texture). With `cull`, faces seen from behind are skipped. With
    /// `clip_z`, the part behind the cabinet plane is cut away.
    #[allow(clippy::too_many_arguments)]
    fn face(
        &self,
        dst: &mut Bitmap,
        tex: &Mips,
        spec: &DoorSpec,
        angle: f64,
        corners: [(f64, f64, f64); 4],
        tint: f32,
        cull: bool,
        clip_z: bool,
        rise: f64,
    ) -> bool {
        let p3: Vec<(f64, f64, f64)> = corners.iter().map(|c| self.project(spec, angle, c.0, c.1, c.2, rise)).collect();
        let quad = [(p3[0].0, p3[0].1), (p3[1].0, p3[1].1), (p3[2].0, p3[2].1), (p3[3].0, p3[3].1)];
        if cull && signed_area(&quad) <= 0.0 {
            return false;
        }
        let mut clip = None;
        if clip_z && p3.iter().any(|p| p.2 < 0.0) {
            if p3.iter().all(|p| p.2 < 0.0) {
                return false;
            }
            // Clip the face polygon (in door space) to z >= 0, then project.
            let (sa, ca) = angle.sin_cos();
            let zof = |c: &(f64, f64, f64)| DOOR_LIFT + c.0 * sa + c.2 * ca;
            let mut poly = Vec::new();
            for i in 0..4 {
                let a = corners[i];
                let b = corners[(i + 1) % 4];
                let (za, zb) = (zof(&a), zof(&b));
                if za >= 0.0 {
                    poly.push(a);
                }
                if (za >= 0.0) != (zb >= 0.0) {
                    let t = za / (za - zb);
                    poly.push((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t));
                }
            }
            if poly.len() < 3 {
                return false;
            }
            clip = Some(poly.iter().map(|c| {
                let p = self.project(spec, angle, c.0, c.1, c.2, rise);
                (p.0, p.1)
            }).collect::<Vec<_>>());
        }
        let base = tex.base();
        let Some(map) = texture_map(&quad, base.w as f64, base.h as f64) else { return false };
        warp(dst, &Warp { tex, map, quad, tint, clip });
        true
    }

    // MARK: Items

    fn bake_item(&mut self, it: &ItemVisual, points: f64) -> (usize, usize) {
        let icon_ptr = it.icon.as_ref().map(|a| Arc::as_ptr(a) as usize).unwrap_or(0);
        let side_expected = (((points * (1.0 + 2.0 * frost_bake::PAD_FRACTION)) * self.scale as f64).round() as usize).max(1);
        if let Some(b) = self.items.get(&it.id) {
            if b.bucket == it.frost.bucket && b.icon == icon_ptr && b.side == side_expected {
                return (b.side, 0);
            }
        }
        let (side, rgba_px) = frost_bake::rasterize(it.icon.as_deref(), points, self.scale);
        let baked = frost_bake::bake(&rgba_px, side, side, &it.frost, it.seed).unwrap_or(rgba_px);
        let bm = Bitmap::from_rgba(side, side, baked);
        self.items.insert(it.id.clone(), ItemBake { bucket: it.frost.bucket, icon: icon_ptr, side, bm });
        (side, 1)
    }

    fn body_with_items(&mut self, items: &[ItemVisual]) {
        let key: Vec<ItemKey> = items.iter().map(item_key).collect();
        if let Some((k, _)) = &self.body_items {
            if *k == key {
                return;
            }
        }
        let mut order: Vec<&ItemVisual> = items.iter().collect();
        order.sort_by(|a, b| {
            let (ra, ca) = ShelfLayout::row_and_column(a.slot);
            let (rb, cb) = ShelfLayout::row_and_column(b.slot);
            a.shelf.cmp(&b.shelf).then(rb.cmp(&ra)).then(ca.cmp(&cb))
        });
        let points_of = |it: &ItemVisual| {
            let (row, col) = ShelfLayout::row_and_column(it.slot);
            let (ax, ay, sc) = InteriorGeometry::anchor(it.shelf, row, col);
            (ax + it.jitter_x, ay, InteriorGeometry::BASE_ICON_SIZE * sc)
        };
        for it in &order {
            let (_, _, p) = points_of(it);
            self.bake_item(it, p);
        }
        let live: std::collections::HashSet<&str> = items.iter().map(|i| i.id.as_str()).collect();
        self.items.retain(|k, _| live.contains(k.as_str()));

        let st = self.st.as_ref().unwrap();
        let mut sprite = st.body.clone();
        let s = self.scale as f64;
        let fh = self.h as f64;
        let ox = BODY_ORIGIN.x + OPENING.x;
        let oy = BODY_ORIGIN.y + OPENING.y;
        // Opening points to sprite pixels.
        let to_px = |x: f64, y: f64| ((x + ox) * s - sprite.x as f64, fh - (y + oy) * s - sprite.y as f64);
        for it in &order {
            let (ax, ay, p) = points_of(it);
            let op = it.opacity.clamp(0.0, 1.0);
            if op <= 0.0 {
                continue;
            }
            // Contact shadow, stretched to 0.95p x 0.26p round (ax, ay + 1).
            let sh = &st.item_shadow;
            let (sw, shh) = (p * 0.95, p * 0.26);
            let (l, t) = to_px(ax - sw / 2.0, ay + 1.0 + shh / 2.0);
            let fwd = [sw * s / sh.w as f64, 0.0, l, 0.0, shh * s / sh.h as f64, t];
            if let Some(inv) = affine_invert(fwd) {
                blit_affine(&mut sprite.bm, sh, inv, affine_bounds(&fwd, sh.w as f64, sh.h as f64), op);
            }
            // Icon: bottom centre (at the padding) on the anchor, tilted, lifted.
            let bake = &self.items[&it.id];
            let side = bake.side as f64;
            let pad = p * frost_bake::PAD_FRACTION;
            let total = p + 2.0 * pad;
            let k = total / side; // points per bitmap pixel
            let (c, sn) = (it.tilt.cos(), it.tilt.sin());
            // bitmap px (u, v) -> local points relative to the anchor (y up) -> rotate -> opening.
            // local = (u·k - total/2, total - v·k - pad)
            let (axp, ayp) = (ax, ay + it.lift as f64);
            let a = k * c;
            let b = k * sn; // coefficient of v (y local = -v·k)
            let cx = -total / 2.0;
            let cy = total - pad;
            // opening x = axp + c·lx - sn·ly ; opening y = ayp + sn·lx + c·ly
            // lx = k u + cx ; ly = -k v + cy
            let ox0 = axp + c * cx - sn * cy;
            let oy0 = ayp + sn * cx + c * cy;
            // To pixels: X = (x + ox)·s - sprite.x ; Y = fh - (y + oy)·s - sprite.y
            let fwd = [
                a * s,
                b * s,
                (ox0 + ox) * s - sprite.x as f64,
                -(k * sn) * s,
                k * c * s,
                fh - (oy0 + oy) * s - sprite.y as f64,
            ];
            if let Some(inv) = affine_invert(fwd) {
                blit_affine(&mut sprite.bm, &bake.bm, inv, affine_bounds(&fwd, side, side), op);
            }
        }
        self.body_items = Some((key, sprite));
    }

    // MARK: Notes

    fn note_sprite(&mut self, n: &NoteVisual) {
        let ptr = n.photo.as_ref().map(|a| Arc::as_ptr(a) as usize).unwrap_or(0);
        let text = if n.hide_text || n.is_photo { String::new() } else { n.text.clone() };
        let key = (text.clone(), n.color, ptr, n.is_photo, n.hide_text);
        if let Some(sp) = self.note_sprites.get(&n.id) {
            if sp.key == key {
                return;
            }
        }
        let s = self.scale;
        let (pm, size, shadow_rect) = if n.is_photo {
            let img = n.photo.as_deref();
            let (iw, ih) = img.map(|i| (i.width, i.height)).unwrap_or((4, 3));
            (notes::photo(img, n.color, s), notes::photo_layer_size(iw, ih), notes::photo_print_size(iw, ih))
        } else {
            let sz = (notes::NOTE_SIZE, notes::NOTE_SIZE);
            (notes::note(&text, n.color, self.font.as_ref(), s), sz, sz)
        };
        self.note_sprites.insert(n.id.clone(), NoteSprite { key, bm: Bitmap::from_pixmap(pm), size, shadow_rect });
    }

    /// The door front with its notes, as a mip chain, rebuilt only when the notes change.
    fn front_texture(&mut self, door: usize, notes_all: &[NoteVisual]) {
        let mine: Vec<&NoteVisual> = notes_all.iter().filter(|n| n.door.index() == door).collect();
        let key: Vec<NoteKey> = mine.iter().map(|n| note_key(n)).collect();
        if let Some(f) = &self.fronts[door] {
            if f.key == key {
                return;
            }
        }
        for n in &mine {
            self.note_sprite(n);
        }
        let spec = &DOORS[door];
        let s = self.scale as f64;
        let st = self.st.as_ref().unwrap();
        let base = &st.doors[door].front;

        // Grow the texture to hold notes hanging over the edge (peeling, dragging).
        let (mut minx, mut miny, mut maxx, mut maxy) = (0.0f64, 0.0f64, spec.width(), spec.height());
        for n in &mine {
            let sp = &self.note_sprites[&n.id];
            let r = 0.5 * sp.size.0.hypot(sp.size.1) * (n.scale.max(0.0) as f64) + 12.0;
            let (cx, cy) = (n.x + n.offset.0, n.y + n.offset.1);
            minx = minx.min(cx - r);
            maxx = maxx.max(cx + r);
            miny = miny.min(cy - r);
            maxy = maxy.max(cy + r);
        }
        let lpx = ((-minx) * s).ceil().max(0.0) as usize;
        let rpx = ((maxx - spec.width()) * s).ceil().max(0.0) as usize;
        let bpx = ((-miny) * s).ceil().max(0.0) as usize;
        let tpx = ((maxy - spec.height()) * s).ceil().max(0.0) as usize;
        let (tw, th) = (base.w + lpx + rpx, base.h + tpx + bpx);
        let mut tex = Bitmap::new(tw, th);
        blit_copy(&mut tex, base, lpx as i32, tpx as i32);
        // Door space of the texture edges, using the base's own pixel scale.
        let kx = base.w as f64 / spec.width();
        let ky = base.h as f64 / spec.height();
        let rect = Rect::new(-(lpx as f64) / kx, -(bpx as f64) / ky, tw as f64 / kx, th as f64 / ky);
        // Door point -> texture pixel.
        let to_tex = |x: f64, y: f64| ((x - rect.x) * kx, (rect.y + rect.h - y) * ky);

        for n in &mine {
            let sp = &self.note_sprites[&n.id];
            let op = n.opacity.clamp(0.0, 1.0);
            let sc = n.scale as f64;
            if op <= 0.0 || sc <= 0.0 {
                continue;
            }
            let theta = n.tilt + n.rotation_extra;
            let (c, sn) = (theta.cos(), theta.sin());
            let (cx, cy) = (n.x + n.offset.0, n.y + n.offset.1);
            let lift = n.lifted.clamp(0.0, 1.0) as f64;
            // Shadow: rect in local points, analytic Gaussian blur.
            let sh_op = (0.32 + (0.45 - 0.32) * lift) * op as f64;
            let sigma = 1.6 + (4.0 - 1.6) * lift;
            let sh_off = (0.8 + (2.0 - 0.8) * lift, -1.6 + (-4.0 + 1.6) * lift);
            let (hw, hh) = (sp.size.0 / 2.0, sp.size.1 / 2.0);
            let (rx0, ry0, rx1, ry1) = (-hw, -hh, -hw + sp.shadow_rect.0, -hh + sp.shadow_rect.1);
            {
                let reach = 0.5 * sp.size.0.hypot(sp.size.1) * sc + 3.0 * sigma + 4.0;
                let (scx, scy) = (cx + sh_off.0, cy + sh_off.1);
                let (x0, y0) = to_tex(scx - reach, scy + reach);
                let (x1, y1) = to_tex(scx + reach, scy - reach);
                let k = 1.0 / (sigma / sc * std::f64::consts::SQRT_2);
                let (ix0, iy0) = (x0.floor().max(0.0) as usize, y0.floor().max(0.0) as usize);
                let (ix1, iy1) = ((x1.ceil() as usize).min(tw), (y1.ceil() as usize).min(th));
                for py in iy0..iy1 {
                    for px in ix0..ix1 {
                        // Texture pixel -> door point -> local note point.
                        let dx = rect.x + (px as f64 + 0.5) / kx - scx;
                        let dy = rect.y + rect.h - (py as f64 + 0.5) / ky - scy;
                        let lx = (c * dx + sn * dy) / sc;
                        let ly = (-sn * dx + c * dy) / sc;
                        let fx = 0.5 * (erf((rx1 - lx) * k) - erf((rx0 - lx) * k));
                        let fy = 0.5 * (erf((ry1 - ly) * k) - erf((ry0 - ly) * k));
                        let a = (fx * fy * sh_op) as f32;
                        if a <= 0.002 {
                            continue;
                        }
                        let i = (py * tw + px) * 4;
                        let d = &mut tex.data[i..i + 4];
                        let inv = 1.0 - a;
                        for ch in 0..3 {
                            d[ch] = (d[ch] as f32 * inv + 0.5) as u8;
                        }
                        d[3] = (a * 255.0 + d[3] as f32 * inv + 0.5).min(255.0) as u8;
                    }
                }
            }
            // The note itself.
            let bm = &sp.bm;
            let kpx = sp.size.0 / bm.w as f64; // points per sprite pixel
            let kpy = sp.size.1 / bm.h as f64;
            // sprite px (u, v) -> local (u·kpx - hw, hh - v·kpy) -> ·sc -> rotate -> + centre -> texture
            let a11 = c * kpx * sc;
            let a12 = sn * kpy * sc; // x gets -sn·ly, ly = -v·kpy...
            let a21 = sn * kpx * sc;
            let a22 = -c * kpy * sc;
            let lx0 = -hw * sc;
            let ly0 = hh * sc;
            let dx0 = cx + c * lx0 - sn * ly0;
            let dy0 = cy + sn * lx0 + c * ly0;
            // door (x, y) -> texture (X, Y) = ((x - rect.x)·kx, (rect.maxY - y)·ky)
            let fwd = [a11 * kx, a12 * kx, (dx0 - rect.x) * kx, -a21 * ky, -a22 * ky, (rect.y + rect.h - dy0) * ky];
            if let Some(inv) = affine_invert(fwd) {
                blit_affine(&mut tex, bm, inv, affine_bounds(&fwd, bm.w as f64, bm.h as f64), op);
            }
        }
        let live: std::collections::HashSet<&str> = notes_all.iter().map(|n| n.id.as_str()).collect();
        self.note_sprites.retain(|k, _| live.contains(k.as_str()));
        self.fronts[door] = Some(FrontCache { key, rect, mips: Mips::new(tex, 5) });
    }

    // MARK: Doors

    fn draw_door(&self, dst: &mut Bitmap, door: usize, angle: f64, rise: f64) {
        let spec = &DOORS[door];
        let art = &self.st.as_ref().unwrap().doors[door];
        let front = self.fronts[door].as_ref().unwrap();
        let (w, h) = (spec.width(), spec.height());
        let t = DOOR_HALF_THICKNESS;
        let ca = angle.cos();
        let front_tint = 1.0 - ((1.0 - ca).max(0.0) * 0.40) as f32;
        let back_tint = 1.0 - ((1.0 + ca).max(0.0) * 0.12) as f32;
        let r = front.rect;
        let front_corners = [(r.x, r.y + r.h, t), (r.x + r.w, r.y + r.h, t), (r.x + r.w, r.y, t), (r.x, r.y, t)];
        let liner_corners = [(w, h, -t), (0.0, h, -t), (0.0, 0.0, -t), (w, 0.0, -t)];
        let (eb, et, _) = recipes::edge_span(spec);
        let ex = w - 2.0;
        let edge_corners = [(ex, h - et, t), (ex, h - et, -t), (ex, eb, -t), (ex, eb, t)];

        let fq: Vec<(f64, f64)> = [(0.0, h), (w, h), (w, 0.0)]
            .iter()
            .map(|c| {
                let p = self.project(spec, angle, c.0, c.1, t, rise);
                (p.0, p.1)
            })
            .collect();
        let front_visible = signed_area(&fq) > 0.0;
        let open = angle > 0.5 * DEG;

        if front_visible {
            if open {
                self.draw_bins(dst, spec, art, angle, rise, true);
            }
            if open {
                self.face(dst, &art.edge, spec, angle, edge_corners, 1.0, true, false, rise);
            }
            self.face(dst, &front.mips, spec, angle, front_corners, front_tint, false, false, rise);
        } else {
            if open {
                self.face(dst, &art.edge, spec, angle, edge_corners, 1.0, true, false, rise);
            }
            self.face(dst, &art.liner, spec, angle, liner_corners, back_tint, false, false, rise);
            if open {
                self.draw_bins(dst, spec, art, angle, rise, false);
            }
        }
    }

    /// Door bins: floor, cheeks and lip for each, painted back to front for the current side.
    fn draw_bins(&self, dst: &mut Bitmap, spec: &DoorSpec, art: &DoorArt, angle: f64, rise: f64, from_front: bool) {
        let t = DOOR_HALF_THICKNESS;
        let (x0, x1) = (BIN_INSET, spec.width() - BIN_INSET);
        let (zin, zout) = (-t, -t - BIN_DEPTH);
        for (b, &y) in spec.bin_y.iter().enumerate() {
            let lh = recipes::bin_lip_height(spec, b);
            let floor = [(x0, y, zin), (x1, y, zin), (x1, y, zout), (x0, y, zout)];
            let lip = [(x1, y + lh, zout), (x0, y + lh, zout), (x0, y, zout), (x1, y, zout)];
            let cheek = |x: f64| [(x, y + lh, zin), (x, y + lh, zout), (x, y, zout), (x, y, zin)];
            let mut parts: Vec<(&Mips, [(f64, f64, f64); 4])> =
                vec![(&art.floor, floor), (&art.cheeks[b], cheek(x0)), (&art.cheeks[b], cheek(x1)), (&art.lips[b], lip)];
            if from_front {
                parts.reverse();
            }
            for (tex, corners) in parts {
                self.face(dst, tex, spec, angle, corners, 1.0, false, true, rise);
            }
        }
    }

    /// A shut door, rendered once per notes change (and rise) into a sprite.
    fn shut_sprite(&mut self, door: usize, rise_px: i32) {
        let key = self.fronts[door].as_ref().unwrap().key.clone();
        if let Some((k, r, _)) = &self.shut[door] {
            if *k == key && *r == rise_px {
                return;
            }
        }
        let spec = &DOORS[door];
        let rise = rise_px as f64 / self.scale as f64;
        let rect = self.fronts[door].as_ref().unwrap().rect;
        let t = DOOR_HALF_THICKNESS;
        let pts: Vec<(f64, f64, f64)> = [(rect.x, rect.y), (rect.x + rect.w, rect.y + rect.h)]
            .iter()
            .map(|c| self.project(spec, 0.0, c.0, c.1, t, rise))
            .collect();
        let x0 = pts[0].0.min(pts[1].0).floor() as i32 - 2;
        let x1 = pts[0].0.max(pts[1].0).ceil() as i32 + 2;
        let y0 = pts[0].1.min(pts[1].1).floor() as i32 - 2;
        let y1 = pts[0].1.max(pts[1].1).ceil() as i32 + 2;
        // Draw into a frame-sized view of just this box by offsetting the projection.
        let mut bm = Bitmap::new((x1 - x0).max(1) as usize, (y1 - y0).max(1) as usize);
        let front = self.fronts[door].as_ref().unwrap();
        let r = front.rect;
        let corners = [(r.x, r.y + r.h, t), (r.x + r.w, r.y + r.h, t), (r.x + r.w, r.y, t), (r.x, r.y, t)];
        let quad: Vec<(f64, f64)> = corners
            .iter()
            .map(|c| {
                let p = self.project(spec, 0.0, c.0, c.1, c.2, rise);
                (p.0 - x0 as f64, p.1 - y0 as f64)
            })
            .collect();
        let quad = [quad[0], quad[1], quad[2], quad[3]];
        let base = front.mips.base();
        if let Some(map) = texture_map(&quad, base.w as f64, base.h as f64) {
            warp(&mut bm, &Warp { tex: &front.mips, map, quad, tint: 1.0, clip: None });
        }
        self.shut[door] = Some((key, rise_px, Sprite { bm, x: x0, y: y0 }));
    }

    // MARK: Frame

    pub fn render(&mut self, state: &SceneState) {
        if let Some(last) = &self.last {
            if same_state(last, state) && self.frame.data.len() == self.w * self.h * 4 {
                return;
            }
        }
        let s = self.scale as f64;
        let lift = state.lift.clamp(0.0, 1.0) as f64;
        let rise_px = (4.0 * lift * s).round() as i32;
        let rise = rise_px as f64 / s;
        let light = lighting(self.dark);
        let angles = [0, 1].map(|i| {
            let a = state.door_angles[i];
            if a.is_finite() {
                a.clamp(0.0, MAX_VISUAL_ANGLE)
            } else {
                0.0
            }
        });

        self.body_with_items(&state.items);
        for d in 0..2 {
            self.front_texture(d, &state.notes);
            if angles[d] < SHUT_EPS {
                self.shut_sprite(d, rise_px);
            }
        }
        if state.fog.is_none() && !self.fog_masks.is_empty() {
            self.fog_masks.clear();
        }

        let mut frame = Bitmap { w: self.w, h: self.h, data: std::mem::take(&mut self.frame.data) };
        frame.data.clear();
        frame.data.resize(self.w * self.h * 4, 0);
        {
            let st = self.st.as_ref().unwrap();
            if lift > 0.0 {
                blit_over(&mut frame, &st.lift_shadow.bm, st.lift_shadow.x, st.lift_shadow.y, lift as f32);
            }
            blit_over(&mut frame, &st.contact_shadow.bm, st.contact_shadow.x, st.contact_shadow.y, 1.0);
            let body = &self.body_items.as_ref().unwrap().1;
            blit_over(&mut frame, &body.bm, body.x, body.y - rise_px, 1.0);

            // Darkness and glow of each compartment, skipped when its door covers it.
            for d in 0..2 {
                if angles[d] < SHUT_EPS {
                    continue;
                }
                let lt = smoothstep(3.0 * DEG, 28.0 * DEG, angles[d]);
                let dark = light.darkness_peak * (1.0 - lt as f32);
                let sl = &st.slices[d];
                let (gx, gy) = (sl.glow.x, sl.glow.y - rise_px);
                if dark > 0.0 {
                    let gw = sl.glow.bm.w;
                    for yy in 0..sl.glow.bm.h {
                        let fy = gy + yy as i32;
                        if fy < 0 || fy >= frame.h as i32 {
                            continue;
                        }
                        for xx in 0..gw {
                            let fx = gx + xx as i32;
                            if fx < 0 || fx >= frame.w as i32 {
                                continue;
                            }
                            let m = sl.mask[yy * gw + xx] as f32 / 255.0 * dark;
                            if m <= 0.0 {
                                continue;
                            }
                            let i = (fy as usize * frame.w + fx as usize) * 4;
                            let p = &mut frame.data[i..i + 4];
                            let inv = 1.0 - m;
                            p[0] = (p[0] as f32 * inv + 0.5) as u8;
                            p[1] = (p[1] as f32 * inv + 0.5) as u8;
                            p[2] = (p[2] as f32 * inv + 0.5) as u8;
                            p[3] = (m * 255.0 + p[3] as f32 * inv + 0.5).min(255.0) as u8;
                        }
                    }
                }
                if lt > 0.0 {
                    blit_over(&mut frame, &sl.glow.bm, gx, gy, lt as f32);
                }
            }
            blit_over(&mut frame, &st.divider.bm, st.divider.x, st.divider.y - rise_px, 1.0);
        }

        // Doors: the less open one first; the more open one swings out in front.
        let order = if angles[0] <= angles[1] { [0, 1] } else { [1, 0] };
        for d in order {
            if angles[d] < SHUT_EPS {
                let sp = &self.shut[d].as_ref().unwrap().2;
                blit_over(&mut frame, &sp.bm, sp.x, sp.y, 1.0);
            } else {
                self.draw_door(&mut frame, d, angles[d], rise);
            }
        }

        {
            let st = self.st.as_ref().unwrap();
            for hsp in &st.hinges {
                blit_over(&mut frame, &hsp.bm, hsp.x, hsp.y - rise_px, 1.0);
            }
        }

        if let Some(f) = state.fog {
            let use_1x = f.lite || self.scale <= 1.0;
            for plume in fog::plumes(f.elapsed, f.lite) {
                let set = if use_1x { &self.assets.fog_1x } else { &self.assets.fog_2x };
                let Some(img) = set.get(plume.frame).or_else(|| self.assets.fog_1x.get(plume.frame)) else { continue };
                let mask = if f.lite {
                    None
                } else {
                    let key = (plume.id, plume.frame);
                    if !self.fog_masks.contains_key(&key) {
                        if let Some(small) = self.assets.fog_1x.get(plume.frame) {
                            self.fog_masks.insert(key, Arc::new(fog::shadow_mask(small, plume.rect.w)));
                        }
                    }
                    self.fog_masks.get(&key).cloned()
                };
                let skey = (if use_1x { 0 } else { 1 }, plume.frame);
                let spans = self.fog_spans.entry(skey).or_insert_with(|| Arc::new(fog::image_spans(img))).clone();
                fog::draw_plume(&mut frame, img, &spans, mask.as_deref(), &plume, s);
            }
        }

        self.frame = Frame { width: self.w as u32, height: self.h as u32, data: frame.data };
        self.last = Some(state.clone());
    }
}

fn recipes_hinge_x() -> f64 {
    fridge_core::geometry::DOOR_INSET - HINGE_SIZE.0 * 0.4
}
