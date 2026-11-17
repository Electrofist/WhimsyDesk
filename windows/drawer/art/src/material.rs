//! Procedural materials (port of `Material.swift`). Each is rendered once into its own bitmap;
//! nothing here runs while the drawer slides.
//!
//! The textures are seeded, so they come out the same on every launch. The Mac draws them in a
//! y-up bitmap; here they are y-down like everything else, which only mirrors the grain.

use crate::canvas::{Canvas, Color, Paint, Path};
use drawer_core::SeededRandom;

#[derive(Clone, Copy, Debug)]
pub struct Wood {
    pub base: u32,
    pub dark: u32,
    pub light: u32,
    pub worn: u32,
}

pub const OAK: Wood = Wood {
    base: 0xB48659,
    dark: 0x6E4B2C,
    light: 0xD3AE80,
    worn: 0xE4CCA6,
};
pub const BIRCH: Wood = Wood {
    base: 0xCDAE84,
    dark: 0x8F6E48,
    light: 0xE3CBA5,
    worn: 0xEEDDC0,
};
pub const WALNUT: Wood = Wood {
    base: 0x53331F,
    dark: 0x24140B,
    light: 0x775036,
    worn: 0x9C7656,
};
pub const WALNUT_PLY: Wood = Wood {
    base: 0x6E4C34,
    dark: 0x3B2516,
    light: 0x8B6649,
    worn: 0xA88768,
};

fn solid(hex: u32, alpha: f64) -> Paint {
    Paint::Solid(Color::hex(hex, alpha as f32))
}

/// Long-grain wood: tonal bands, fine grain lines and pores; optionally scratches, dings and
/// finish rubbed away along the edges. `w` and `h` are in points.
pub fn wood(wd: &Wood, w: f64, h: f64, scale: f64, seed: u64, worn: bool) -> Canvas {
    let mut c = Canvas::new(w, h, scale);
    let mut rng = SeededRandom::new(seed);
    c.fill_rect(0.0, 0.0, w, h, &solid(wd.base, 1.0));

    let p1 = rng.range(0.0, 6.0);
    let p2 = rng.range(0.0, 6.0);
    let p3 = rng.range(0.0, 6.0);
    let warp = move |x: f64, y: f64| {
        (x * 0.0042 + y * 0.035 + p1).sin() * 4.5
            + (x * 0.012 + y * 0.013 + p2).sin() * 1.6
            + (x * 0.031 + p3).sin() * 0.5
    };
    let strand = |c: &mut Canvas, y0: f64, width: f64, paint: &Paint| {
        let mut path = Path::new();
        let mut x = -6.0;
        path.move_to((x, y0 + warp(x, y0)));
        while x < w + 6.0 {
            x += 5.0;
            path.line_to((x, y0 + warp(x, y0)));
        }
        c.stroke(&path, width, paint);
    };

    for _ in 0..4.max((h / 2.5) as usize) {
        // broad tonal bands
        let dark = rng.next_unit() < 0.55;
        let y = rng.range(-12.0, h + 12.0);
        let width = rng.range(2.0, 10.0);
        let alpha = rng.range(0.05, 0.14);
        strand(
            &mut c,
            y,
            width,
            &solid(if dark { wd.dark } else { wd.light }, alpha),
        );
    }
    for _ in 0..(h * 1.5) as usize {
        // fine grain
        let dark = rng.next_unit() < 0.8;
        let y = rng.range(-12.0, h + 12.0);
        let width = rng.range(0.25, 1.1);
        let alpha = rng.range(0.05, if dark { 0.3 } else { 0.14 });
        strand(
            &mut c,
            y,
            width,
            &solid(if dark { wd.dark } else { wd.light }, alpha),
        );
    }
    let pore = solid(wd.dark, 0.28); // open pores
    for _ in 0..(w * h / 45.0) as usize {
        let x = rng.range(0.0, w);
        let y = rng.range(0.0, h);
        let pw = rng.range(1.0, 5.0);
        c.fill_rect(x, y, pw, 0.5, &pore);
    }

    if worn {
        for _ in 0..(w / 7.0) as usize {
            // light scratches through the finish
            let x = rng.range(0.0, w);
            let y = rng.range(0.0, h);
            let len = rng.next_unit().powf(1.6) * 40.0 + 2.0;
            let a = rng.range(-0.5, 0.5) + if rng.next_unit() < 0.15 { 1.2 } else { 0.0 };
            let alpha = rng.range(0.06, 0.24);
            let width = rng.range(0.25, 0.7);
            c.stroke_line(
                (x, y),
                (x + a.cos() * len, y + a.sin() * len),
                width,
                &solid(wd.worn, alpha),
            );
        }
        for _ in 0..(w / 30.0) as usize {
            // small dings
            let r = rng.range(0.5, 1.6);
            let alpha = rng.range(0.15, 0.35);
            let x = rng.range(0.0, w);
            let y = rng.range(0.0, h);
            c.fill(&Path::ellipse(x, y, r * 1.6, r), &solid(wd.dark, alpha));
        }
        for _ in 0..((w + h) * 4.0) as usize {
            // finish rubbed off at the edges
            let d = rng.next_unit().powf(2.4) * 6.0;
            let corner = rng.next_unit() < 0.25;
            let (x, y);
            match (rng.next_unit() * 4.0) as usize {
                0 => {
                    x = if corner {
                        rng.next_unit().powi(3) * 30.0
                    } else {
                        rng.range(0.0, w)
                    };
                    y = d;
                }
                1 => {
                    x = if corner {
                        w - rng.next_unit().powi(3) * 30.0
                    } else {
                        rng.range(0.0, w)
                    };
                    y = h - d;
                }
                2 => {
                    x = d;
                    y = if corner {
                        rng.next_unit().powi(3) * 20.0
                    } else {
                        rng.range(0.0, h)
                    };
                }
                _ => {
                    x = w - d;
                    y = if corner {
                        h - rng.next_unit().powi(3) * 20.0
                    } else {
                        rng.range(0.0, h)
                    };
                }
            }
            let r = rng.range(0.3, 1.4);
            let alpha = rng.range(0.06, 0.32) * (1.0 - d / 7.0);
            let len = r * rng.range(1.5, 4.0);
            c.fill(
                &Path::ellipse(x - r, y - r / 2.0, len, r),
                &solid(wd.worn, alpha),
            );
        }
    }
    let mut noise = SeededRandom::new(seed.wrapping_add(7));
    c.add_noise(0.035, || noise.next_unit());
    c
}

/// Felt liner: a fibrous nap of short light and dark hairs over the base colour.
pub fn felt(color: u32, w: f64, h: f64, scale: f64) -> Canvas {
    let mut c = Canvas::new(w, h, scale);
    let mut rng = SeededRandom::new(99);
    c.fill_rect(0.0, 0.0, w, h, &solid(color, 1.0));
    for _ in 0..(w * h / 12.0) as usize {
        let x = rng.range(0.0, w);
        let y = rng.range(0.0, h);
        let a = rng.range(0.0, std::f64::consts::TAU);
        let l = rng.range(0.8, 3.2);
        let light = rng.next_unit() < 0.5;
        let paint = if light {
            Paint::Solid(Color::white(rng.range(0.03, 0.09) as f32))
        } else {
            Paint::Solid(Color::black(rng.range(0.05, 0.12) as f32))
        };
        c.stroke_line((x, y), (x + a.cos() * l, y + a.sin() * l), 0.35, &paint);
    }
    let mut noise = SeededRandom::new(5);
    c.add_noise(0.07, || noise.next_unit());
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mean_rgb(c: &Canvas) -> [f64; 3] {
        let (mut s, n) = ([0.0f64; 3], (c.width() * c.height()) as f64);
        for y in 0..c.height() {
            for x in 0..c.width() {
                let p = c.pixel(x, y);
                for k in 0..3 {
                    s[k] += p[k] as f64;
                }
            }
        }
        [s[0] / n, s[1] / n, s[2] / n]
    }

    #[test]
    fn wood_is_opaque_and_close_to_its_base_colour() {
        let c = wood(&OAK, 200.0, 40.0, 1.0, 11, true);
        for (x, y) in [(0, 0), (199, 39), (100, 20), (3, 37)] {
            assert!((c.pixel(x, y)[3] - 1.0).abs() < 1e-4);
        }
        let m = mean_rgb(&c);
        let base = [
            0xB4 as f64 / 255.0,
            0x86 as f64 / 255.0,
            0x59 as f64 / 255.0,
        ];
        for k in 0..3 {
            assert!(
                (m[k] - base[k]).abs() < 0.12,
                "channel {k}: mean {} vs base {}",
                m[k],
                base[k]
            );
        }
    }

    #[test]
    fn wood_has_grain_not_a_flat_fill() {
        let c = wood(&BIRCH, 200.0, 40.0, 1.0, 3, false);
        let vals: Vec<f32> = (0..c.height())
            .flat_map(|y| (0..c.width()).map(move |x| (x, y)))
            .map(|(x, y)| c.pixel(x, y)[0])
            .collect();
        let mean = vals.iter().sum::<f32>() / vals.len() as f32;
        let var = vals.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / vals.len() as f32;
        assert!(var.sqrt() > 0.015, "std dev {}", var.sqrt());
    }

    #[test]
    fn textures_are_deterministic_and_seed_dependent() {
        let a = wood(&OAK, 120.0, 30.0, 1.0, 11, true).to_rgba8();
        let b = wood(&OAK, 120.0, 30.0, 1.0, 11, true).to_rgba8();
        let c = wood(&OAK, 120.0, 30.0, 1.0, 12, true).to_rgba8();
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn worn_edges_are_lighter_than_the_middle() {
        let c = wood(&WALNUT, 400.0, 60.0, 1.0, 11, true);
        let row =
            |y: usize| (0..c.width()).map(|x| c.pixel(x, y)[0]).sum::<f32>() / c.width() as f32;
        let edge = (row(0) + row(1) + row(58) + row(59)) / 4.0;
        let middle = (row(28) + row(29) + row(30) + row(31)) / 4.0;
        assert!(
            edge > middle,
            "finish rubbed off at the edges: edge {edge} middle {middle}"
        );
    }

    #[test]
    fn felt_is_the_base_colour_with_a_nap() {
        let c = felt(0x2F4A3B, 120.0, 60.0, 1.0);
        let m = mean_rgb(&c);
        assert!((m[0] - 0x2F as f64 / 255.0).abs() < 0.03);
        assert!((m[1] - 0x4A as f64 / 255.0).abs() < 0.03);
        assert!(c.pixel(5, 5)[3] > 0.999);
    }
}
