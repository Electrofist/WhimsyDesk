//! How long each render takes (release build): `cargo run --release -p drawer-art --example timing -- 1.5`
use drawer_art::{render_back, render_cast_shadow, render_front, DARK, LIGHT};
use std::time::Instant;

fn main() {
    let scale: f64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(1.0);
    let t = Instant::now();
    let _ = render_back(&LIGHT, scale);
    println!("back (box and floor): {:?}", t.elapsed());
    let t = Instant::now();
    let _ = render_front(&LIGHT, scale);
    println!("front (panel and pull): {:?}", t.elapsed());
    let t = Instant::now();
    let _ = render_back(&DARK, scale);
    println!("dark back: {:?}", t.elapsed());
    let t = Instant::now();
    let _ = render_cast_shadow(0.5, scale);
    println!("one cast shadow: {:?}", t.elapsed());
}
