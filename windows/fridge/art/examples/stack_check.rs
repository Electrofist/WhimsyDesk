//! Runs the start-up drawing inside a thread with Windows' default 1 MB stack, so a stack overflow
//! that only shows up on Windows can be caught on any OS. Usage: cargo run --example stack_check
use fridge_art::{Assets, Renderer, SceneState};
use std::sync::Arc;

fn main() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets");
    for (label, release_like) in [("1 MB stack", 1usize << 20)] {
        let dir = dir.clone();
        let r = std::thread::Builder::new()
            .stack_size(release_like / 4)
            .spawn(move || {
                let assets = Arc::new(Assets::load(&dir).expect("assets"));
                eprintln!("assets loaded");
                let dark = std::env::args().nth(1).as_deref() == Some("dark");
                let mut renderer = Renderer::new(assets, 1.25, dark);
                eprintln!("renderer made {:?}", renderer.size());
                let f = renderer.render(&SceneState::default());
                eprintln!("first frame {}x{}", f.width, f.height);
                let mut s = SceneState::default();
                s.door_angles = [1.6, 1.6];
                let f = renderer.render(&s);
                eprintln!("open frame {}x{}", f.width, f.height);
            })
            .unwrap()
            .join();
        eprintln!("{label}: {}", if r.is_ok() { "ok" } else { "FAILED" });
    }
}
