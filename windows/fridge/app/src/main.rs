//! Desktop Fridge for Windows. The Win32 shell lives in `win`; drawing is in `fridge-art`,
//! file handling and physics in `fridge-core`. Everything between them that does not touch
//! Windows (gestures, animations, menus, settings) is plain Rust here so it can be tested anywhere.

#![cfg_attr(windows, windows_subsystem = "windows")]
#![cfg_attr(not(windows), allow(dead_code))]

mod anim;
mod cursors;
mod menu;
mod model;
mod placement;
mod resample;
mod settings;
mod wav;

#[cfg(windows)]
mod win;

fn main() {
    #[cfg(windows)]
    win::run();
    #[cfg(not(windows))]
    eprintln!("Desktop Fridge for Windows only runs on Windows.");
}
