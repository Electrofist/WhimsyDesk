//! Desktop Drawer for Windows. The Win32 shell lives in `win`; drawing is in `drawer-art`, the
//! physics, layout and file handling in `drawer-core`. Everything between them that does not
//! touch Windows (where the window goes, how a frame is put together, what a mouse click means)
//! is plain Rust here, so it can be tested on any OS.

// Debug builds keep a console, so `cargo run` shows log lines.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]
#![cfg_attr(not(windows), allow(dead_code))]

mod compose;
mod contents;
mod controller;
mod placement;
mod sprite;

#[cfg(windows)]
mod win;

fn main() {
    #[cfg(windows)]
    win::run();
    #[cfg(not(windows))]
    eprintln!("Desktop Drawer for Windows only runs on Windows.");
}
