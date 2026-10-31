//! Renders the fridge in a set of states to `target/snapshots/*.png` and times `render`.
//! Run: `cargo run --release -p fridge-art --example snapshots`

use fridge_art::*;
use fridge_core::{FrostModel, FrostState};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

const DEG: f64 = std::f64::consts::PI / 180.0;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
}

/// Straight RGBA PNG of a frame, laid over a desktop-like background (or transparent).
fn save(frame: &Frame, name: &str, background: bool) {
    let (w, h) = (frame.width as usize, frame.height as usize);
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            let (b, g, r, a) = (frame.data[i] as f32, frame.data[i + 1] as f32, frame.data[i + 2] as f32, frame.data[i + 3] as f32);
            if background {
                // Pale blue tiles, like the wallpaper in the Mac recordings.
                let tile = ((x / 40) + (y / 40)) % 2 == 0;
                let bg = if tile { [150.0, 196.0, 228.0] } else { [126.0, 178.0, 218.0] };
                let inv = 1.0 - a / 255.0;
                out[i] = (r + bg[0] * inv) as u8;
                out[i + 1] = (g + bg[1] * inv) as u8;
                out[i + 2] = (b + bg[2] * inv) as u8;
                out[i + 3] = 255;
            } else if a > 0.0 {
                out[i] = (r * 255.0 / a).min(255.0) as u8;
                out[i + 1] = (g * 255.0 / a).min(255.0) as u8;
                out[i + 2] = (b * 255.0 / a).min(255.0) as u8;
                out[i + 3] = a as u8;
            }
        }
    }
    let dir = root().join("target").join("snapshots");
    std::fs::create_dir_all(&dir).unwrap();
    let file = std::fs::File::create(dir.join(name)).unwrap();
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().unwrap().write_image_data(&out).unwrap();
    println!("wrote {name}");
}

/// A simple generated icon: a folder or a page with a coloured band.
fn icon(kind: usize) -> Arc<Image> {
    let n = 128u32;
    let mut pm = tiny_skia::Pixmap::new(n, n).unwrap();
    let mut paint = tiny_skia::Paint::default();
    paint.anti_alias = true;
    let rect = |x: f32, y: f32, w: f32, h: f32| tiny_skia::PathBuilder::from_rect(tiny_skia::Rect::from_xywh(x, y, w, h).unwrap());
    let t = tiny_skia::Transform::identity();
    if kind == 0 {
        paint.set_color_rgba8(70, 150, 225, 255);
        pm.fill_path(&rect(10.0, 28.0, 48.0, 20.0), &paint, tiny_skia::FillRule::Winding, t, None);
        paint.set_color_rgba8(95, 175, 240, 255);
        pm.fill_path(&rect(10.0, 38.0, 108.0, 72.0), &paint, tiny_skia::FillRule::Winding, t, None);
    } else {
        paint.set_color_rgba8(250, 250, 250, 255);
        pm.fill_path(&rect(24.0, 8.0, 80.0, 112.0), &paint, tiny_skia::FillRule::Winding, t, None);
        let colors = [(220, 60, 50), (40, 150, 80), (60, 110, 220), (230, 160, 30)];
        let (r, g, b) = colors[kind % 4];
        paint.set_color_rgba8(r, g, b, 255);
        pm.fill_path(&rect(24.0, 78.0, 80.0, 22.0), &paint, tiny_skia::FillRule::Winding, t, None);
        paint.set_color_rgba8(170, 175, 185, 255);
        for i in 0..4 {
            pm.fill_path(&rect(36.0, 24.0 + i as f32 * 12.0, 56.0, 4.0), &paint, tiny_skia::FillRule::Winding, t, None);
        }
    }
    Arc::new(Image { width: n, height: n, data: pm.take() })
}

fn photo() -> Arc<Image> {
    let (w, h) = (400u32, 300u32);
    let mut data = vec![0u8; (w * h * 4) as usize];
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            let sky = y < 170;
            let (r, g, b) = if sky {
                (120 + (y / 3) as u8, 170 + (y / 4) as u8, 235)
            } else {
                (60 + (x / 10) as u8, 140, 70)
            };
            let sun = ((x as i32 - 290).pow(2) + (y as i32 - 70).pow(2)) < 900;
            let (r, g, b) = if sun { (255, 220, 90) } else { (r, g, b) };
            data[i..i + 4].copy_from_slice(&[r, g, b, 255]);
        }
    }
    Arc::new(Image { width: w, height: h, data })
}

fn item(id: usize, shelf: usize, slot: usize, days: f64, icon: Option<Arc<Image>>) -> ItemVisual {
    let seed = 0x1234_5678_9ABC_DEF0u64.wrapping_mul(id as u64 + 1);
    let mut rng = fridge_core::SeededRandom::new(seed);
    let jitter_x = rng.range(-3.0, 3.0);
    let tilt = rng.range(-0.045, 0.045);
    ItemVisual {
        id: format!("ITEM-{id}"),
        icon,
        shelf,
        slot,
        jitter_x,
        tilt,
        seed,
        frost: if days > 0.0 { FrostModel::state_for_elapsed(days * FrostModel::DAY) } else { FrostState::new(0.0, 0.0) },
        opacity: 1.0,
        lift: 0.0,
    }
}

fn note(id: &str, door: DoorId, x: f64, y: f64, tilt: f64, color: usize, text: &str) -> NoteVisual {
    NoteVisual {
        id: id.into(),
        door,
        is_photo: false,
        x,
        y,
        tilt,
        color,
        text: text.into(),
        photo: None,
        hide_text: false,
        scale: 1.0,
        opacity: 1.0,
        rotation_extra: 0.0,
        offset: (0.0, 0.0),
        lifted: 0.0,
    }
}

fn items() -> Vec<ItemVisual> {
    vec![
        item(1, 1, 0, 0.0, Some(icon(1))),
        item(2, 1, 1, 0.5, Some(icon(2))),
        item(3, 1, 2, 3.0, Some(icon(3))),
        item(4, 1, 5, 10.0, Some(icon(0))),
        item(5, 0, 1, 30.0, Some(icon(0))),
        item(6, 2, 2, 400.0, None),
    ]
}

fn notes_set() -> Vec<NoteVisual> {
    let mut v = vec![
        note("N1", DoorId::Fridge, 100.0, 250.0, 0.04, 0, "Buy milk and eggs before the weekend please"),
        note("N2", DoorId::Fridge, 175.0, 160.0, -0.05, 1, "hello there"),
        note("N3", DoorId::Freezer, 90.0, 100.0, 0.02, 2, "ice cream!"),
    ];
    let mut p = note("P1", DoorId::Fridge, 120.0, 90.0, -0.03, 1, "");
    p.is_photo = true;
    p.photo = Some(photo());
    v.push(p);
    v
}

fn state(fridge: f64, freezer: f64) -> SceneState {
    SceneState { door_angles: [fridge * DEG, freezer * DEG], ..Default::default() }
}

fn main() {
    let assets = Arc::new(Assets::load(&root().join("assets")).expect("assets"));
    let t = Instant::now();
    let mut r = Renderer::new(assets.clone(), 2.0, true);
    println!("static art at scale 2: {:.1} ms", t.elapsed().as_secs_f64() * 1000.0);
    println!("frame {:?}", r.size());

    save(r.render(&state(0.0, 0.0)), "shut_dark_s2.png", true);
    save(r.render(&state(0.0, 0.0)), "shut_dark_s2_alpha.png", false);
    for a in [10.0, 30.0, 60.0, 96.0] {
        save(r.render(&state(a, 0.0)), &format!("fridge_{a:.0}_dark_s2.png", a = a), true);
    }
    save(r.render(&state(0.0, 60.0)), "freezer_60_dark_s2.png", true);
    let mut s = state(96.0, 96.0);
    save(r.render(&s), "both_96_dark_s2.png", true);
    s.items = items();
    save(r.render(&s), "items_96_dark_s2.png", true);
    let mut s = state(0.0, 0.0);
    s.notes = notes_set();
    save(r.render(&s), "notes_shut_dark_s2.png", true);
    let mut s2 = s.clone();
    s2.door_angles = [40.0 * DEG, 0.0];
    save(r.render(&s2), "notes_fridge_40_dark_s2.png", true);
    for e in [0.3, 0.8, 1.4] {
        let mut s = state(30.0, 0.0);
        s.fog = Some(FogState { elapsed: e, lite: false });
        save(r.render(&s), &format!("fog_{:.0}ms_dark_s2.png", e * 1000.0), true);
    }
    let mut s = state(30.0, 0.0);
    s.fog = Some(FogState { elapsed: 0.8, lite: true });
    save(r.render(&s), "fog_800ms_lite_s2.png", true);
    let mut s = state(0.0, 0.0);
    s.lift = 1.0;
    save(r.render(&s), "lifted_s2.png", true);

    r.set_dark(false);
    let mut s = state(96.0, 96.0);
    s.items = items();
    save(r.render(&s), "items_96_light_s2.png", true);
    save(r.render(&state(30.0, 0.0)), "fridge_30_light_s2.png", true);

    let mut r1 = Renderer::new(assets.clone(), 1.0, true);
    let mut s = state(96.0, 0.0);
    s.items = items();
    s.notes = notes_set();
    save(r1.render(&s), "items_96_dark_s1.png", true);
    save(r1.render(&state(0.0, 0.0)), "shut_dark_s1.png", true);

    // Timing at scale 2: a door swinging (each frame different), with and without fog.
    let mut r = Renderer::new(assets, 2.0, true);
    let mut base = state(0.0, 0.0);
    base.items = items();
    base.notes = notes_set();
    r.render(&base);
    let bench = |r: &mut Renderer, label: &str, f: &dyn Fn(usize) -> SceneState| {
        let n = 120;
        let mut worst = 0.0f64;
        let t = Instant::now();
        for i in 0..n {
            let s = f(i);
            let t1 = Instant::now();
            r.render(&s);
            worst = worst.max(t1.elapsed().as_secs_f64());
        }
        println!("{label}: avg {:.2} ms, worst {:.2} ms", t.elapsed().as_secs_f64() * 1000.0 / n as f64, worst * 1000.0);
    };
    bench(&mut r, "fridge door swinging 0-105", &|i| {
        let mut s = base.clone();
        s.door_angles = [(i as f64 / 119.0) * 105.0 * DEG, 0.0];
        s
    });
    bench(&mut r, "both doors swinging", &|i| {
        let mut s = base.clone();
        s.door_angles = [(i as f64 / 119.0) * 105.0 * DEG, (1.0 - i as f64 / 119.0) * 100.0 * DEG];
        s
    });
    bench(&mut r, "door swinging with fog", &|i| {
        let mut s = base.clone();
        s.door_angles = [(i as f64 / 119.0) * 60.0 * DEG, 0.0];
        s.fog = Some(FogState { elapsed: i as f64 / 119.0 * 1.85, lite: false });
        s
    });
    bench(&mut r, "fog again (masks cached), door still at 40", &|i| {
        let mut s = base.clone();
        s.door_angles = [40.0 * DEG, 0.0];
        s.fog = Some(FogState { elapsed: i as f64 / 119.0 * 1.85, lite: false });
        s
    });
    bench(&mut r, "fog lite, door still at 40", &|i| {
        let mut s = base.clone();
        s.door_angles = [40.0 * DEG, 0.0];
        s.fog = Some(FogState { elapsed: i as f64 / 119.0 * 1.85, lite: true });
        s
    });
    bench(&mut r, "shut, a note dragged", &|i| {
        let mut s = base.clone();
        s.notes[1].x = 120.0 + i as f64 * 0.3;
        s.notes[1].lifted = 1.0;
        s
    });
    bench(&mut r, "unchanged state", &|_| base.clone());
}
