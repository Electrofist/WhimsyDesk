//! A small start-up and error log, so a fridge that does not appear can be diagnosed:
//! %LOCALAPPDATA%\WhimsyDesk\Desktop Fridge\fridge.log. Kept short; nothing leaves the PC.

use std::io::Write;
use std::path::PathBuf;

pub fn path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("WhimsyDesk").join("Desktop Fridge").join("fridge.log")
}

/// Starts a fresh log for this run (keeps the previous run as fridge.old.log).
pub fn start() {
    let p = path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::rename(&p, p.with_file_name("fridge.old.log"));
    line(&format!("Desktop Fridge {} starting", env!("CARGO_PKG_VERSION")));
}

pub fn line(text: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path()) {
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = writeln!(f, "[{}] {}", fridge_core::iso::format(secs as f64), text);
    }
}

/// Any crash shows a message with the reason and writes it to the log, instead of vanishing.
pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let what = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown error".into());
        let place = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
        line(&format!("CRASH: {what} at {place}"));
        super::dialog::fatal(&format!(
            "Desktop Fridge stopped because of an error.\n\n{what}\n{place}\n\nDetails are in:\n{}",
            path().display()
        ));
    }));
}
