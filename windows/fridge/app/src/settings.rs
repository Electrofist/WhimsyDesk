//! `settings.json` in `%APPDATA%\WhimsyDesk\Desktop Fridge`. PORT-SPEC §11.
//!
//! `windowOrigin` is the window's top-left corner in physical screen pixels (Windows virtual
//! screen coordinates, y down). The Mac app stores AppKit points; the two files never meet.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub const MIN_SCALE: f64 = 0.45;
pub const MAX_SCALE: f64 = 1.6;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Origin {
    pub x: i32,
    pub y: i32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_origin: Option<Origin>,
    #[serde(default = "one")]
    pub fridge_scale: f64,
    #[serde(default = "one")]
    pub time_scale: f64,
}

fn one() -> f64 {
    1.0
}

impl Default for Settings {
    fn default() -> Self {
        Settings { window_origin: None, fridge_scale: 1.0, time_scale: 1.0 }
    }
}

impl Settings {
    /// Reads the file; anything missing or broken falls back to the defaults.
    pub fn load(path: &Path) -> Settings {
        let mut s = fs::read(path)
            .ok()
            .and_then(|d| serde_json::from_slice::<Settings>(&d).ok())
            .unwrap_or_default();
        s.sanitize();
        s
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let data = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        fridge_core::store::write_atomic(path, &data)
    }

    fn sanitize(&mut self) {
        if !self.fridge_scale.is_finite() || self.fridge_scale <= 0.0 {
            self.fridge_scale = 1.0;
        }
        self.fridge_scale = self.fridge_scale.clamp(MIN_SCALE, MAX_SCALE);
        if !self.time_scale.is_finite() || self.time_scale <= 0.0 {
            self.time_scale = 1.0;
        }
    }

    /// Frost speed: `FRIDGE_TIME_SCALE` wins over the file.
    pub fn effective_time_scale(&self, env: Option<&str>) -> f64 {
        match env.and_then(|v| v.trim().parse::<f64>().ok()) {
            Some(v) if v.is_finite() && v > 0.0 => v,
            _ => self.time_scale,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_with_camel_case_keys() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("settings.json");
        let s = Settings { window_origin: Some(Origin { x: -20, y: 300 }), fridge_scale: 1.25, time_scale: 3.0 };
        s.save(&path).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"windowOrigin\"") && text.contains("\"fridgeScale\"") && text.contains("\"timeScale\""));
        assert_eq!(Settings::load(&path), s);
    }

    #[test]
    fn missing_or_bad_files_give_defaults() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(Settings::load(&dir.path().join("none.json")), Settings::default());
        let bad = dir.path().join("bad.json");
        fs::write(&bad, "{not json").unwrap();
        assert_eq!(Settings::load(&bad), Settings::default());
        fs::write(&bad, r#"{"fridgeScale": 9}"#).unwrap();
        let s = Settings::load(&bad);
        assert_eq!(s.fridge_scale, MAX_SCALE);
        assert_eq!(s.time_scale, 1.0);
        assert_eq!(s.window_origin, None);
    }

    #[test]
    fn environment_time_scale_wins() {
        let s = Settings { time_scale: 2.0, ..Settings::default() };
        assert_eq!(s.effective_time_scale(Some("100")), 100.0);
        assert_eq!(s.effective_time_scale(Some("nope")), 2.0);
        assert_eq!(s.effective_time_scale(Some("-1")), 2.0);
        assert_eq!(s.effective_time_scale(None), 2.0);
    }
}
