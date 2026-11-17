//! Renders the empty drawer (fully open) in both themes to PNG files, for comparing with the Mac app.
//!
//!     cargo run --release -p drawer-art --example snapshots -- <output folder> [scale]
//!
//! Writes `drawer-light.png` and `drawer-dark.png`, plus `drawer-light-closed.png` (just the
//! visible slice of a closed drawer).

use drawer_art::{render_preview, Canvas, DARK, LIGHT};
use drawer_core::geometry::{visible_height_px, VIEW_WIDTH};
use std::{env, fs, path::PathBuf};

fn main() {
    let mut args = env::args().skip(1);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| ".".into()));
    let scale: f64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(1.0);
    fs::create_dir_all(&dir).unwrap();

    for (name, theme) in [("light", &LIGHT), ("dark", &DARK)] {
        let started = std::time::Instant::now();
        let c = render_preview(theme, scale);
        fs::write(dir.join(format!("drawer-{name}.png")), c.to_png()).unwrap();
        println!(
            "{name}: {}x{} px in {:?}",
            c.width(),
            c.height(),
            started.elapsed()
        );
        if name == "light" {
            // The window shows only the top slice of the artwork when the drawer is closed.
            let rows = visible_height_px(0.0, scale) as usize;
            let rgba = c.to_rgba8();
            let w = c.width();
            let slice = Canvas::new(VIEW_WIDTH, rows as f64 / scale, scale);
            let png = drawer_art::png::encode_png(
                slice.width(),
                slice.height(),
                &rgba[..w * slice.height() * 4],
            );
            fs::write(dir.join("drawer-light-closed.png"), png).unwrap();
        }
    }
}
