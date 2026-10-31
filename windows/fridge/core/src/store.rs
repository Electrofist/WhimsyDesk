//! Moves files in and out of the fridge folder and keeps a small JSON index beside them.
//! Port of `FridgeStore.swift`. Files are only ever moved, never copied and left behind or deleted.

use crate::iso;
use crate::layout::ShelfLayout;
use crate::rng::SeededRandom;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// One stored item. Fields are in alphabetical order so the JSON keys come out sorted, like the Mac app.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FridgeEntry {
    /// Uppercase UUID.
    pub id: String,
    /// Full path the item came from.
    pub original_path: String,
    /// Desktop icon position, if it was known when the item went in.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub original_x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub original_y: Option<f64>,
    /// Seconds since the Unix epoch, written as ISO 8601.
    #[serde(with = "iso::serde_iso")]
    pub placed_at: f64,
    pub shelf: usize,
    pub slot: usize,
    /// File name inside the fridge folder (may differ from the original if it had to be made unique).
    pub stored_name: String,
}

impl FridgeEntry {
    pub fn global_slot(&self) -> usize {
        self.shelf * ShelfLayout::SLOTS_PER_SHELF + self.slot
    }

    /// Stable per-item seed: the first 8 bytes of the UUID as a little-endian u64 (as on the Mac).
    pub fn stable_seed(&self) -> u64 {
        match uuid::Uuid::parse_str(&self.id) {
            Ok(u) => {
                let b = u.as_bytes();
                u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
            }
            Err(_) => self.id.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, c| (h ^ c as u64).wrapping_mul(0x1000_0000_01b3)),
        }
    }

    /// Small fixed jitter and tilt for this item, so the shelves look placed by hand.
    pub fn jitter_and_tilt(&self) -> (f64, f64) {
        let mut r = SeededRandom::new(self.stable_seed());
        let jitter = r.range(-3.0, 3.0);
        let tilt = r.range(-0.045, 0.045);
        (jitter, tilt)
    }

    pub fn desktop_position(&self) -> Option<(f64, f64)> {
        Some((self.original_x?, self.original_y?))
    }
}

#[derive(Debug, PartialEq)]
pub enum FridgeError {
    Full,
    AlreadyInside,
    MissingSource,
    NotFound,
    Io(String),
}

impl From<io::Error> for FridgeError {
    fn from(e: io::Error) -> Self {
        FridgeError::Io(e.to_string())
    }
}

impl std::fmt::Display for FridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FridgeError::Full => write!(f, "the fridge is full"),
            FridgeError::AlreadyInside => write!(f, "already in the fridge"),
            FridgeError::MissingSource => write!(f, "the file is gone"),
            FridgeError::NotFound => write!(f, "not in the fridge any more"),
            FridgeError::Io(e) => write!(f, "{e}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RestoreResult {
    pub destination: PathBuf,
    /// Only when the item went back onto the Desktop and a position was recorded.
    pub desktop_position: Option<(f64, f64)>,
}

#[derive(Serialize, Deserialize)]
struct IndexFile {
    items: Vec<FridgeEntry>,
    version: u32,
}

pub struct FridgeStore {
    pub root: PathBuf,
    /// Where items go when their folder is gone, and the only folder whose icon positions matter.
    pub desktop: PathBuf,
    entries: Vec<FridgeEntry>,
}

impl FridgeStore {
    pub const INDEX_NAME: &'static str = ".fridge-index.json";

    /// Opens (creating if needed) the fridge folder, reads the index and reconciles it with the disk.
    pub fn open(root: impl Into<PathBuf>, desktop: impl Into<PathBuf>) -> io::Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        let mut store = Self { root, desktop: desktop.into(), entries: Vec::new() };
        store.load_index();
        store.reconcile();
        Ok(store)
    }

    pub fn entries(&self) -> &[FridgeEntry] {
        &self.entries
    }

    pub fn path_for(&self, entry: &FridgeEntry) -> PathBuf {
        self.root.join(&entry.stored_name)
    }

    pub fn entry(&self, id: &str) -> Option<&FridgeEntry> {
        self.entries.iter().find(|e| e.id == id)
    }

    pub fn is_full(&self) -> bool {
        self.entries.len() >= ShelfLayout::CAPACITY
    }

    /// Moves a file or folder into the fridge. Fails with `Full` before touching the file when there is no room.
    pub fn store(
        &mut self,
        source: &Path,
        desktop_position: Option<(f64, f64)>,
        preferred_shelf: i64,
        now: f64,
    ) -> Result<FridgeEntry, FridgeError> {
        let source = normalize(source);
        if source.parent().map(|p| same_path(p, &self.root)).unwrap_or(false) {
            return Err(FridgeError::AlreadyInside);
        }
        if fs::symlink_metadata(&source).is_err() {
            return Err(FridgeError::MissingSource);
        }
        let occupied: HashSet<usize> = self.entries.iter().map(|e| e.global_slot()).collect();
        let (shelf, slot) = ShelfLayout::first_free_slot(&occupied, preferred_shelf).ok_or(FridgeError::Full)?;

        let name = file_name(&source);
        let destination = unique_path(&self.root, &name);
        move_item(&source, &destination)?;

        let entry = FridgeEntry {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            original_path: source.to_string_lossy().into_owned(),
            original_x: desktop_position.map(|p| p.0),
            original_y: desktop_position.map(|p| p.1),
            placed_at: now,
            shelf,
            slot,
            stored_name: file_name(&destination),
        };
        self.entries.push(entry.clone());
        self.save_index();
        Ok(entry)
    }

    /// Moves an item back where it came from, or onto the Desktop if that folder is gone.
    pub fn restore(&mut self, id: &str) -> Result<RestoreResult, FridgeError> {
        let entry = self.entry(id).cloned().ok_or(FridgeError::NotFound)?;
        let source = self.path_for(&entry);
        if fs::symlink_metadata(&source).is_err() {
            self.remove_entry(id);
            return Err(FridgeError::NotFound);
        }
        let original = PathBuf::from(&entry.original_path);
        let mut parent = original.parent().map(Path::to_path_buf).unwrap_or_else(|| self.desktop.clone());
        if !parent.is_dir() {
            parent = self.desktop.clone();
        }
        let destination = unique_path(&parent, &file_name(&original));
        move_item(&source, &destination)?;
        self.remove_entry(id);
        let position = if same_path(&parent, &self.desktop) { entry.desktop_position() } else { None };
        Ok(RestoreResult { destination, desktop_position: position })
    }

    /// Moves an item onto the Desktop whatever folder it came from. Same naming and index update as `restore`.
    pub fn move_to_desktop(&mut self, id: &str) -> Result<RestoreResult, FridgeError> {
        let entry = self.entry(id).cloned().ok_or(FridgeError::NotFound)?;
        let source = self.path_for(&entry);
        if fs::symlink_metadata(&source).is_err() {
            self.remove_entry(id);
            return Err(FridgeError::NotFound);
        }
        let original = PathBuf::from(&entry.original_path);
        let destination = unique_path(&self.desktop, &file_name(&original));
        move_item(&source, &destination)?;
        self.remove_entry(id);
        let came_from_desktop = original.parent().map(|p| same_path(p, &self.desktop)).unwrap_or(false);
        let position = if came_from_desktop { entry.desktop_position() } else { None };
        Ok(RestoreResult { destination, desktop_position: position })
    }

    /// Forget an entry without touching files (a drag moved the file elsewhere).
    pub fn remove_entry(&mut self, id: &str) {
        self.entries.retain(|e| e.id != id);
        self.save_index();
    }

    /// True when the item's file is no longer in the fridge folder.
    pub fn is_gone(&self, id: &str) -> bool {
        match self.entry(id) {
            Some(e) => fs::symlink_metadata(self.path_for(e)).is_err(),
            None => true,
        }
    }

    fn index_path(&self) -> PathBuf {
        self.root.join(Self::INDEX_NAME)
    }

    fn load_index(&mut self) {
        if let Ok(data) = fs::read(self.index_path()) {
            if let Ok(file) = serde_json::from_slice::<IndexFile>(&data) {
                self.entries = file.items;
            }
        }
    }

    fn save_index(&self) {
        let file = IndexFile { items: self.entries.clone(), version: 1 };
        if let Ok(data) = serde_json::to_vec_pretty(&file) {
            let _ = write_atomic(&self.index_path(), &data);
        }
    }

    /// Drops entries whose files left the folder and adopts files put there by hand.
    fn reconcile(&mut self) {
        let mut changed = false;
        let before = self.entries.len();
        let root = self.root.clone();
        self.entries.retain(|e| fs::symlink_metadata(root.join(&e.stored_name)).is_ok());
        if self.entries.len() != before {
            changed = true;
        }

        let mut names: Vec<String> = fs::read_dir(&self.root)
            .map(|it| it.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        names.sort();
        let known: HashSet<String> = self.entries.iter().map(|e| e.stored_name.clone()).collect();
        for name in names {
            if name.starts_with('.') || known.contains(&name) || is_system_file(&name) {
                continue;
            }
            let occupied: HashSet<usize> = self.entries.iter().map(|e| e.global_slot()).collect();
            let Some((shelf, slot)) = ShelfLayout::first_free_slot(&occupied, 1) else { break };
            let placed = fs::metadata(self.root.join(&name))
                .and_then(|m| m.created())
                .map(iso::from_system_time)
                .unwrap_or_else(|_| iso::now());
            self.entries.push(FridgeEntry {
                id: uuid::Uuid::new_v4().to_string().to_uppercase(),
                original_path: self.desktop.join(&name).to_string_lossy().into_owned(),
                original_x: None,
                original_y: None,
                placed_at: placed,
                shelf,
                slot,
                stored_name: name,
            });
            changed = true;
        }
        if changed {
            self.save_index();
        }
    }
}

/// Windows drops these into folders on its own; they are not the user's things.
fn is_system_file(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n == "desktop.ini" || n == "thumbs.db"
}

pub fn file_name(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Lexically cleans a path (drops "." and resolves ".."), like `standardizedFileURL`.
pub fn normalize(p: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Path equality, case-insensitive on Windows.
pub fn same_path(a: &Path, b: &Path) -> bool {
    let (a, b) = (normalize(a), normalize(b));
    if cfg!(windows) {
        a.to_string_lossy().to_lowercase().trim_end_matches(['\\', '/']) == b.to_string_lossy().to_lowercase().trim_end_matches(['\\', '/'])
    } else {
        a == b
    }
}

/// "name.ext", then "name 2.ext", "name 3.ext" and so on, like Finder and Explorer.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if fs::symlink_metadata(&candidate).is_err() {
        return candidate;
    }
    let path = Path::new(name);
    let base = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| name.to_string());
    let ext = path.extension().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let mut n = 2;
    loop {
        let numbered = if ext.is_empty() { format!("{base} {n}") } else { format!("{base} {n}.{ext}") };
        let candidate = dir.join(numbered);
        if fs::symlink_metadata(&candidate).is_err() {
            return candidate;
        }
        n += 1;
    }
}

/// Moves a file or folder. A rename when possible; across drives, copies everything, checks the
/// copy, and only then removes the original. If anything fails, the original stays where it was.
pub fn move_item(from: &Path, to: &Path) -> io::Result<()> {
    match fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(rename_error) => {
            if fs::symlink_metadata(to).is_ok() {
                return Err(rename_error);
            }
            if let Err(e) = copy_recursive(from, to) {
                let _ = remove_recursive(to);
                return Err(e);
            }
            if !same_size(from, to) {
                let _ = remove_recursive(to);
                return Err(io::Error::new(io::ErrorKind::Other, "the copy did not match the original"));
            }
            remove_recursive(from)
        }
    }
}

fn copy_recursive(from: &Path, to: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(from)?;
    if meta.is_dir() {
        fs::create_dir(to)?;
        for item in fs::read_dir(from)? {
            let item = item?;
            copy_recursive(&item.path(), &to.join(item.file_name()))?;
        }
        Ok(())
    } else {
        fs::copy(from, to).map(|_| ())
    }
}

fn remove_recursive(p: &Path) -> io::Result<()> {
    if fs::symlink_metadata(p)?.is_dir() {
        fs::remove_dir_all(p)
    } else {
        fs::remove_file(p)
    }
}

fn total_size(p: &Path) -> u64 {
    match fs::symlink_metadata(p) {
        Ok(m) if m.is_dir() => fs::read_dir(p)
            .map(|it| it.filter_map(|e| e.ok()).map(|e| total_size(&e.path())).sum())
            .unwrap_or(0),
        Ok(m) => m.len(),
        Err(_) => u64::MAX,
    }
}

fn same_size(a: &Path, b: &Path) -> bool {
    total_size(a) == total_size(b)
}

/// Write to a temporary file beside the target, then replace the target.
pub fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp-write");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    //! Mirrors `Tests/FridgeCoreTests/FridgeStoreTests.swift`.
    use super::*;

    struct Sandbox {
        _dir: tempfile::TempDir,
        fridge: PathBuf,
        desk: PathBuf,
        desktop: PathBuf,
    }

    fn sandbox() -> Sandbox {
        let dir = tempfile::tempdir().unwrap();
        let fridge = dir.path().join("Fridge");
        let desk = dir.path().join("Desk");
        let desktop = dir.path().join("Desktop");
        fs::create_dir_all(&desk).unwrap();
        fs::create_dir_all(&desktop).unwrap();
        Sandbox { _dir: dir, fridge, desk, desktop }
    }

    fn make(dir: &Path, name: &str) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, "x").unwrap();
        p
    }

    #[test]
    fn store_moves_file_and_writes_index() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let src = make(&s.desk, "a.txt");
        let entry = store.store(&src, Some((10.0, 20.0)), 2, 1000.0).unwrap();
        assert!(!src.exists());
        assert!(s.fridge.join("a.txt").exists());
        assert_eq!(entry.shelf, 2);
        assert_eq!(entry.desktop_position(), Some((10.0, 20.0)));

        let reopened = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        assert_eq!(reopened.entries().len(), 1);
        assert_eq!(reopened.entries()[0].id, entry.id);
        assert_eq!(reopened.entries()[0].original_path, normalize(&src).to_string_lossy());
    }

    #[test]
    fn name_collision_gets_a_number() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        store.store(&make(&s.desk, "a.txt"), None, 1, 0.0).unwrap();
        let second = store.store(&make(&s.desk, "a.txt"), None, 1, 0.0).unwrap();
        assert_eq!(second.stored_name, "a 2.txt");
    }

    #[test]
    fn restore_goes_back_to_the_original_folder() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let src = make(&s.desk, "b.txt");
        let e = store.store(&src, Some((1.0, 2.0)), 1, 0.0).unwrap();
        let r = store.restore(&e.id).unwrap();
        assert!(src.exists());
        assert!(store.entries().is_empty());
        assert_eq!(r.desktop_position, None, "no position outside the Desktop");
    }

    #[test]
    fn restore_falls_back_to_the_desktop() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let e = store.store(&make(&s.desk, "c.txt"), None, 1, 0.0).unwrap();
        fs::remove_dir_all(&s.desk).unwrap();
        let r = store.restore(&e.id).unwrap();
        assert_eq!(r.destination, s.desktop.join("c.txt"));
        assert!(r.destination.exists());
    }

    #[test]
    fn restore_to_desktop_returns_the_position() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let e = store.store(&make(&s.desktop, "d.txt"), Some((5.0, 6.0)), 1, 0.0).unwrap();
        let r = store.restore(&e.id).unwrap();
        assert_eq!(r.desktop_position, Some((5.0, 6.0)));
    }

    #[test]
    fn full_fridge_refuses_and_leaves_the_file() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        for i in 0..24 {
            store.store(&make(&s.desk, &format!("f{i}.txt")), None, 1, 0.0).unwrap();
        }
        assert!(store.is_full());
        let extra = make(&s.desk, "extra.txt");
        assert_eq!(store.store(&extra, None, 1, 0.0), Err(FridgeError::Full));
        assert!(extra.exists());
    }

    #[test]
    fn reconcile_drops_missing_and_adopts_strangers() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let e = store.store(&make(&s.desk, "gone.txt"), None, 1, 0.0).unwrap();
        fs::remove_file(s.fridge.join(&e.stored_name)).unwrap();
        fs::write(s.fridge.join("handmade.txt"), "x").unwrap();
        let reopened = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let names: Vec<_> = reopened.entries().iter().map(|e| e.stored_name.clone()).collect();
        assert_eq!(names, vec!["handmade.txt".to_string()]);
    }

    #[test]
    fn storing_something_already_inside_fails() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let inside = make(&s.fridge, "inside.txt");
        assert_eq!(store.store(&inside, None, 1, 0.0), Err(FridgeError::AlreadyInside));
    }

    #[test]
    fn move_to_desktop_from_elsewhere() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let e = store.store(&make(&s.desk, "m.txt"), Some((3.0, 4.0)), 1, 0.0).unwrap();
        let r = store.move_to_desktop(&e.id).unwrap();
        assert_eq!(r.destination, s.desktop.join("m.txt"));
        assert_eq!(r.desktop_position, None);
        assert!(store.entries().is_empty());
    }

    #[test]
    fn unique_names_without_extension() {
        let s = sandbox();
        fs::write(s.desk.join("notes"), "x").unwrap();
        assert_eq!(unique_path(&s.desk, "notes"), s.desk.join("notes 2"));
    }

    #[test]
    fn folders_move_too() {
        let s = sandbox();
        let mut store = FridgeStore::open(&s.fridge, &s.desktop).unwrap();
        let folder = s.desk.join("Projects");
        fs::create_dir_all(folder.join("inner")).unwrap();
        fs::write(folder.join("inner/a.txt"), "x").unwrap();
        let e = store.store(&folder, None, 0, 0.0).unwrap();
        assert!(s.fridge.join("Projects/inner/a.txt").exists());
        store.restore(&e.id).unwrap();
        assert!(folder.join("inner/a.txt").exists());
    }

    #[test]
    fn copy_fallback_keeps_everything() {
        let s = sandbox();
        let folder = s.desk.join("Copied");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("x.txt"), "hello").unwrap();
        let to = s.desktop.join("Copied");
        copy_recursive(&folder, &to).unwrap();
        assert!(same_size(&folder, &to));
    }
}
