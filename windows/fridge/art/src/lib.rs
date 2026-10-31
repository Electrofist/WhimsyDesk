//! Draws Desktop Fridge. Platform independent: turns the current state of the fridge into one
//! premultiplied BGRA frame that the Windows app hands to `UpdateLayeredWindow`.
//!
//! Every recipe follows `docs/PORT-SPEC.md` §2, §4, §5, §7 and §8 (ported from the Swift app).
//!
//! THIS FILE IS THE CONTRACT between the art crate and the app crate. Keep the public names and
//! signatures below stable; add to them rather than change them.
//!
//! Coordinates in the public API are design points with the origin at the bottom left of the
//! window and y up (the Mac convention, so numbers match the spec). `Frame` pixels are top-down.

use std::path::Path;
use std::sync::Arc;

mod canvas;
mod fog;
mod frost_bake;
mod notes;
mod pixel;
mod recipes;
mod scene;
mod thumb;

pub use fridge_core::geometry::DoorId;
pub use fridge_core::FrostState;

/// A straight-alpha or premultiplied RGBA bitmap, row-major, top row first.
#[derive(Clone, Debug)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    /// RGBA8, premultiplied alpha.
    pub data: Vec<u8>,
}

/// One finished frame for the window: `width x height` pixels, premultiplied BGRA, top row first.
/// Size is `round(520·scale) x round(800·scale)` where scale = dpi scale × user scale.
#[derive(Clone, Debug, Default)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl Frame {
    /// Alpha at a pixel (0 outside). The app uses it for hit testing transparent areas.
    pub fn alpha_at(&self, x: i32, y: i32) -> u8 {
        if x < 0 || y < 0 || x as u32 >= self.width || y as u32 >= self.height {
            return 0;
        }
        self.data[((y as u32 * self.width + x as u32) * 4 + 3) as usize]
    }
}

/// Bundled art: door fronts, fog frames, the note font.
pub struct Assets {
    pub door_fridge: Image,
    pub door_freezer: Image,
    /// 40 fog frames at 1x (256 x 192) and 2x (512 x 384).
    pub fog_1x: Vec<Image>,
    pub fog_2x: Vec<Image>,
    /// Handwriting font for sticky notes (TTF/OTF bytes).
    pub note_font: Vec<u8>,
}

impl Assets {
    /// Loads everything from the `assets` folder that ships beside the exe
    /// (`door/`, `fog/`, `fonts/`). See the folder layout in the repo.
    pub fn load(dir: &Path) -> Result<Assets, String> {
        let read = |p: std::path::PathBuf| std::fs::read(&p).map_err(|e| format!("{}: {e}", p.display()));
        let png = |p: std::path::PathBuf| -> Result<Image, String> {
            let bytes = read(p.clone())?;
            decode_png(&bytes).ok_or_else(|| format!("{}: not a readable PNG", p.display()))
        };
        let door_fridge = png(dir.join("door").join("door_fridge.png"))?;
        let door_freezer = png(dir.join("door").join("door_freezer.png"))?;
        let mut fog_1x = Vec::new();
        let mut fog_2x = Vec::new();
        for i in 0..fridge_core::geometry::FOG_FRAME_COUNT {
            fog_1x.push(png(dir.join("fog").join(format!("fog_{i:02}.png")))?);
            fog_2x.push(png(dir.join("fog").join(format!("fog_{i:02}@2x.png")))?);
        }
        let fonts = dir.join("fonts");
        let preferred = fonts.join(NOTE_FONT_FILE);
        let note_font = if preferred.exists() {
            read(preferred)?
        } else {
            // Any TTF or OTF in the folder will do.
            let mut found = None;
            if let Ok(entries) = std::fs::read_dir(&fonts) {
                let mut paths: Vec<_> = entries.flatten().map(|e| e.path()).collect();
                paths.sort();
                for p in paths {
                    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
                    if ext == "ttf" || ext == "otf" {
                        found = Some(read(p)?);
                        break;
                    }
                }
            }
            found.ok_or_else(|| format!("{}: no note font", fonts.display()))?
        };
        Ok(Assets { door_fridge, door_freezer, fog_1x, fog_2x, note_font })
    }
}

/// The sticky note font file in `assets/fonts/` (Caveat Bold, SIL Open Font License).
pub const NOTE_FONT_FILE: &str = "Caveat-Bold.ttf";

/// A file on a shelf.
#[derive(Clone, Debug)]
pub struct ItemVisual {
    /// Entry id; used to cache the frost bake.
    pub id: String,
    /// Shell icon of the file, square, premultiplied RGBA (any size; drawn at the slot size).
    /// None draws a plain document shape.
    pub icon: Option<Arc<Image>>,
    pub shelf: usize,
    pub slot: usize,
    /// From `FridgeEntry::jitter_and_tilt` and `stable_seed`.
    pub jitter_x: f64,
    pub tilt: f64,
    pub seed: u64,
    /// Current frost look. The renderer re-bakes only when `frost.bucket` changes for this id.
    pub frost: FrostState,
    /// 0…1 (add fade-in, remove fade-out, 0.25 while dragged out).
    pub opacity: f32,
    /// Points above the resting spot (add animation slides down from +28).
    pub lift: f32,
}

/// A sticky note or photo magnet on a door's front face.
#[derive(Clone, Debug)]
pub struct NoteVisual {
    pub id: String,
    pub door: DoorId,
    pub is_photo: bool,
    /// Centre in door space (origin at the door's bottom left), points.
    pub x: f64,
    pub y: f64,
    pub tilt: f64,
    /// Note paper colour or magnet colour, 0…3.
    pub color: usize,
    pub text: String,
    /// Photo magnets: the thumbnail, straight from `.magnets/*.png`.
    pub photo: Option<Arc<Image>>,
    /// Hide the text while the in-place editor covers it.
    pub hide_text: bool,
    /// Pop-in / peel animation.
    pub scale: f32,
    pub opacity: f32,
    pub rotation_extra: f64,
    pub offset: (f64, f64),
    /// 0 resting, 1 lifted (being dragged): drives the shadow.
    pub lifted: f32,
}

/// The fog plumes, if playing.
#[derive(Clone, Copy, Debug)]
pub struct FogState {
    /// Seconds since the fog started.
    pub elapsed: f64,
    /// Low power: every other frame, 1x, no shadow.
    pub lite: bool,
}

/// Everything that changes between frames.
#[derive(Clone, Debug, Default)]
pub struct SceneState {
    /// Visual angles in radians, [fridge, freezer].
    pub door_angles: [f64; 2],
    pub items: Vec<ItemVisual>,
    /// In z order, last on top.
    pub notes: Vec<NoteVisual>,
    pub fog: Option<FogState>,
    /// 0…1 while the fridge is being moved: lift shadow and +4 pt rise.
    pub lift: f32,
}

/// Draws the fridge. Static art is rendered in `new`, `set_scale` and `set_dark` (tens of ms);
/// `render` only composes. Calling `render` with an unchanged state returns the last frame.
pub struct Renderer {
    engine: scene::Engine,
}

impl Renderer {
    /// `scale` = dpi scale × user scale. `dark` = Windows dark app mode.
    pub fn new(assets: Arc<Assets>, scale: f32, dark: bool) -> Renderer {
        Renderer { engine: scene::Engine::new(assets, scale, dark) }
    }

    /// Re-renders the static layers at a new scale (resize release, dpi change).
    pub fn set_scale(&mut self, scale: f32) {
        self.engine.set_scale(scale);
    }

    pub fn set_dark(&mut self, dark: bool) {
        self.engine.set_dark(dark);
    }

    pub fn scale(&self) -> f32 {
        self.engine.scale
    }

    pub fn dark(&self) -> bool {
        self.engine.dark
    }

    /// Frame size in pixels for the current scale.
    pub fn size(&self) -> (u32, u32) {
        self.engine.size()
    }

    /// Draws one frame.
    pub fn render(&mut self, state: &SceneState) -> &Frame {
        self.engine.render(state);
        &self.engine.frame
    }
}

/// Lines a note's text is drawn in (wrapped, the last visible line truncated with "…"), for an
/// editor that wants to match. Empty if the font is missing.
pub fn note_text_lines(assets: &Assets, text: &str) -> Vec<String> {
    notes::NoteFont::new(&assets.note_font).map(|f| f.layout(text)).unwrap_or_default()
}

/// Note font size in points and line height in points (to size the in-place editor).
pub const NOTE_FONT_SIZE: f32 = notes::FONT_SIZE;
pub const NOTE_LINE_HEIGHT: f64 = notes::LINE_HEIGHT;

/// Sticky note size in points (70 x 70) and the rect the text sits in (x 7, y 6, w 56, h 51).
pub const NOTE_SIZE: f64 = 70.0;
pub const NOTE_TEXT_RECT: (f64, f64, f64, f64) = (7.0, 6.0, 56.0, 51.0);

/// Size in points of a photo magnet for a picture of `width x height` pixels (print plus magnet room).
pub fn photo_size(width: u32, height: u32) -> (f64, f64) {
    notes::photo_layer_size(width, height)
}

/// The print part of a photo magnet (no magnet headroom); hit tests may prefer it.
pub fn photo_print_size(width: u32, height: u32) -> (f64, f64) {
    notes::photo_print_size(width, height)
}

/// Makes a magnet thumbnail: EXIF-oriented, longest side at most 480 px, PNG bytes.
/// Returns None when the file is not a picture the app can read (PNG and JPEG are supported).
pub fn make_photo_thumbnail(path: &Path) -> Option<Vec<u8>> {
    let bytes = std::fs::read(path).ok()?;
    thumb::thumbnail(&bytes)
}

/// Decodes a PNG into an `Image` (premultiplied).
pub fn decode_png(bytes: &[u8]) -> Option<Image> {
    thumb::decode_png(bytes)
}

/// Makes an `Image` from straight-alpha RGBA (for example a shell icon after conversion).
pub fn image_from_straight_rgba(width: u32, height: u32, mut rgba: Vec<u8>) -> Image {
    thumb::premultiply(&mut rgba);
    Image { width, height, data: rgba }
}

/// Makes an `Image` from premultiplied BGRA, the layout Windows DIBs use.
pub fn image_from_premultiplied_bgra(width: u32, height: u32, mut bgra: Vec<u8>) -> Image {
    pixel::swap_rb(&mut bgra);
    Image { width, height, data: bgra }
}
