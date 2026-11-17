//! Owns the drawer folder and a small JSON index of where each stashed item came from
//! (PORT-SPEC section 6). Port of `DrawerStore.swift`.
//!
//! Files are only ever moved, never copied and left behind, and never deleted. This type does the
//! disk work synchronously; the app calls it from a worker thread and reads `items()` on the UI
//! thread after each call.
//!
//! One deliberate difference from the Mac app: the Mac orders items by the file system's "date
//! added to directory", which Windows does not have, and a moved file keeps its old creation
//! time. So the index records `addedAt` when a file is stashed. Files placed in the folder by hand
//! have no entry and are ordered by their creation (or modified) time.

use crate::fsutil::{
    file_name, is_hidden, is_inside_or_same, is_system_file, move_item, normalize, same_path,
    unique_path, write_atomic,
};
use crate::json::Json;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Clone, Debug, PartialEq)]
pub struct IndexEntry {
    pub original_name: String,
    pub original_directory: String,
    /// Desktop icon position, if the file came from the Desktop and the position was known.
    pub desktop_position: Option<(f64, f64)>,
    /// Seconds since the Unix epoch.
    pub added_at: f64,
}

/// One item in the drawer, oldest first.
#[derive(Clone, Debug, PartialEq)]
pub struct DrawerItem {
    /// File name inside the drawer folder (may differ from the original if it had to be made unique).
    pub name: String,
    pub added_at: f64,
}

#[derive(Debug, PartialEq)]
pub enum DrawerError {
    /// The file is already in the drawer folder.
    AlreadyInside,
    /// The file is the drawer folder or one of its ancestors: never swallow our own container.
    ContainsDrawer,
    MissingSource,
    /// Not in the drawer any more.
    NotFound,
    Io(String),
}

impl From<io::Error> for DrawerError {
    fn from(e: io::Error) -> Self {
        DrawerError::Io(e.to_string())
    }
}

impl std::fmt::Display for DrawerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DrawerError::AlreadyInside => write!(f, "already in the drawer"),
            DrawerError::ContainsDrawer => write!(f, "that folder contains the drawer"),
            DrawerError::MissingSource => write!(f, "the file is gone"),
            DrawerError::NotFound => write!(f, "not in the drawer any more"),
            DrawerError::Io(e) => write!(f, "{e}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RestoreResult {
    /// The name the item had inside the drawer.
    pub name: String,
    pub destination: PathBuf,
    /// Only when the item landed on the Desktop and a position was recorded.
    pub desktop_position: Option<(f64, f64)>,
}

pub struct DrawerStore {
    folder: PathBuf,
    desktop: PathBuf,
    index_path: PathBuf,
    /// Keyed by stored file name.
    index: BTreeMap<String, IndexEntry>,
    items: Vec<DrawerItem>,
}

impl DrawerStore {
    /// Opens (creating if needed) the drawer folder, reads the index and lists the folder.
    /// `folder` is `%USERPROFILE%\Desktop Drawer`; `index_path` is
    /// `%APPDATA%\WhimsyDesk\Desktop Drawer\index.json`.
    pub fn open(
        folder: impl Into<PathBuf>,
        desktop: impl Into<PathBuf>,
        index_path: impl Into<PathBuf>,
    ) -> io::Result<Self> {
        let folder = folder.into();
        let index_path = index_path.into();
        fs::create_dir_all(&folder)?;
        if let Some(parent) = index_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut store = Self {
            folder,
            desktop: desktop.into(),
            index_path,
            index: BTreeMap::new(),
            items: Vec::new(),
        };
        store.load_index();
        store.reload();
        Ok(store)
    }

    pub fn items(&self) -> &[DrawerItem] {
        &self.items
    }
    pub fn folder(&self) -> &Path {
        &self.folder
    }
    pub fn desktop(&self) -> &Path {
        &self.desktop
    }
    pub fn path_for(&self, name: &str) -> PathBuf {
        self.folder.join(name)
    }
    /// True when `path` sits directly on the Desktop, so its icon position is worth reading.
    pub fn is_on_desktop(&self, path: &Path) -> bool {
        normalize(path)
            .parent()
            .map(|p| same_path(p, &self.desktop))
            .unwrap_or(false)
    }
    pub fn original_directory(&self, name: &str) -> Option<&str> {
        self.index.get(name).map(|e| e.original_directory.as_str())
    }

    /// Lists the folder again (call at launch and whenever the drawer opens past 0.6, and after a
    /// drag out ends). Also forgets index entries whose files have left the drawer.
    pub fn reload(&mut self) {
        let names: Vec<String> = fs::read_dir(&self.folder)
            .map(|it| {
                it.filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();

        let present: HashSet<&String> = names.iter().collect();
        let stale: Vec<String> = self
            .index
            .keys()
            .filter(|k| !present.contains(k))
            .cloned()
            .collect();
        if !stale.is_empty() {
            for k in &stale {
                self.index.remove(k);
            }
            self.save_index();
        }

        let mut items: Vec<DrawerItem> = names
            .into_iter()
            .filter(|n| !is_system_file(n) && !is_hidden(&self.folder.join(n)))
            .map(|name| {
                let added_at = self
                    .index
                    .get(&name)
                    .map(|e| e.added_at)
                    .or_else(|| file_time(&self.folder.join(&name)))
                    .unwrap_or(0.0);
                DrawerItem { name, added_at }
            })
            .collect();
        items.sort_by(|a, b| {
            a.added_at
                .total_cmp(&b.added_at)
                .then_with(|| a.name.cmp(&b.name))
        });
        self.items = items;
    }

    /// Moves one dropped file or folder into the drawer, remembering where it came from.
    /// `desktop_position` is only kept when the file really sits on the Desktop.
    /// The app calls this once per dropped path and carries on with the rest if one fails.
    pub fn stash(
        &mut self,
        source: &Path,
        desktop_position: Option<(f64, f64)>,
        now: f64,
    ) -> Result<DrawerItem, DrawerError> {
        let source = normalize(source);
        let name = file_name(&source);
        if name.is_empty() {
            return Err(DrawerError::MissingSource);
        }
        let parent = source.parent().map(Path::to_path_buf).unwrap_or_default();
        if same_path(&parent, &self.folder) {
            return Err(DrawerError::AlreadyInside);
        }
        if is_inside_or_same(&self.folder, &source) {
            return Err(DrawerError::ContainsDrawer);
        }
        if fs::symlink_metadata(&source).is_err() {
            return Err(DrawerError::MissingSource);
        }
        let position = if same_path(&parent, &self.desktop) {
            desktop_position
        } else {
            None
        };

        let target = unique_path(&self.folder, &name);
        move_item(&source, &target)?;
        let stored = file_name(&target);
        self.index.insert(
            stored.clone(),
            IndexEntry {
                original_name: name,
                original_directory: parent.to_string_lossy().into_owned(),
                desktop_position: position,
                added_at: now,
            },
        );
        self.save_index();
        self.reload();
        Ok(DrawerItem {
            name: stored,
            added_at: now,
        })
    }

    /// Moves an item back to the folder it came from (the Desktop if that is gone).
    pub fn put_back(&mut self, name: &str) -> Result<RestoreResult, DrawerError> {
        self.move_out(name, false)
    }

    /// Moves an item onto the Desktop whatever folder it came from.
    pub fn move_to_desktop(&mut self, name: &str) -> Result<RestoreResult, DrawerError> {
        self.move_out(name, true)
    }

    /// Puts back (or moves to the Desktop) every item. Items that vanished on their own are
    /// skipped quietly, as on the Mac. Returns what moved and how many failed.
    pub fn move_all(&mut self, to_desktop: bool) -> (Vec<RestoreResult>, usize) {
        let names: Vec<String> = self.items.iter().map(|i| i.name.clone()).collect();
        let mut moved = Vec::new();
        let mut failed = 0;
        for name in names {
            match self.move_out(&name, to_desktop) {
                Ok(r) => moved.push(r),
                Err(DrawerError::NotFound) => {}
                Err(_) => failed += 1,
            }
        }
        (moved, failed)
    }

    fn move_out(&mut self, name: &str, to_desktop: bool) -> Result<RestoreResult, DrawerError> {
        let source = self.folder.join(name);
        if fs::symlink_metadata(&source).is_err() {
            self.index.remove(name);
            self.save_index();
            self.reload();
            return Err(DrawerError::NotFound);
        }
        let entry = self.index.get(name).cloned();
        let mut dest_dir = self.desktop.clone();
        if !to_desktop {
            if let Some(e) = &entry {
                let dir = PathBuf::from(&e.original_directory);
                if dir.is_dir() {
                    dest_dir = dir;
                }
            }
        }
        let original_name = entry
            .as_ref()
            .map(|e| e.original_name.as_str())
            .unwrap_or(name);
        let target = unique_path(&dest_dir, original_name);
        move_item(&source, &target)?;
        self.index.remove(name);
        self.save_index();
        self.reload();
        let desktop_position = if same_path(&dest_dir, &self.desktop) {
            entry.and_then(|e| e.desktop_position)
        } else {
            None
        };
        Ok(RestoreResult {
            name: name.to_string(),
            destination: target,
            desktop_position,
        })
    }

    // MARK: Index file

    fn load_index(&mut self) {
        let Ok(text) = fs::read_to_string(&self.index_path) else {
            return;
        };
        let Ok(json) = Json::parse(&text) else { return };
        let Some(items) = json.get("items").and_then(Json::as_object) else {
            return;
        };
        for (name, v) in items {
            let (Some(original_name), Some(original_directory)) = (
                v.get("originalName").and_then(Json::as_str),
                v.get("originalDirectory").and_then(Json::as_str),
            ) else {
                continue;
            };
            let desktop_position = match (
                v.get("desktopX").and_then(Json::as_f64),
                v.get("desktopY").and_then(Json::as_f64),
            ) {
                (Some(x), Some(y)) => Some((x, y)),
                _ => None,
            };
            self.index.insert(
                name.clone(),
                IndexEntry {
                    original_name: original_name.to_string(),
                    original_directory: original_directory.to_string(),
                    desktop_position,
                    added_at: v.get("addedAt").and_then(Json::as_f64).unwrap_or(0.0),
                },
            );
        }
    }

    fn save_index(&self) {
        let items = self
            .index
            .iter()
            .map(|(name, e)| {
                let mut fields = vec![
                    ("addedAt".to_string(), Json::Num(e.added_at)),
                    (
                        "originalDirectory".to_string(),
                        Json::Str(e.original_directory.clone()),
                    ),
                    (
                        "originalName".to_string(),
                        Json::Str(e.original_name.clone()),
                    ),
                ];
                if let Some((x, y)) = e.desktop_position {
                    fields.push(("desktopX".to_string(), Json::Num(x)));
                    fields.push(("desktopY".to_string(), Json::Num(y)));
                }
                (name.clone(), Json::Obj(fields))
            })
            .collect();
        let doc = Json::Obj(vec![
            ("items".to_string(), Json::Obj(items)),
            ("version".to_string(), Json::Num(1.0)),
        ]);
        let _ = write_atomic(&self.index_path, doc.to_string_pretty().as_bytes());
    }
}

/// Creation time, else modified time, as seconds since the Unix epoch.
fn file_time(path: &Path) -> Option<f64> {
    let meta = fs::symlink_metadata(path).ok()?;
    let t = meta.created().or_else(|_| meta.modified()).ok()?;
    Some(t.duration_since(UNIX_EPOCH).ok()?.as_secs_f64())
}

#[cfg(test)]
mod tests {
    //! Mirrors the cases in the fridge store tests, plus the drawer's own rules.
    use super::*;
    use crate::fsutil::testutil::TempDir;

    struct Sandbox {
        _dir: TempDir,
        drawer: PathBuf,
        desk: PathBuf,
        desktop: PathBuf,
        index: PathBuf,
    }

    fn sandbox() -> Sandbox {
        let dir = TempDir::new();
        let root = dir.path().to_path_buf();
        let desk = root.join("Desk");
        let desktop = root.join("Desktop");
        fs::create_dir_all(&desk).unwrap();
        fs::create_dir_all(&desktop).unwrap();
        Sandbox {
            drawer: root.join("Home").join("Desktop Drawer"),
            index: root.join("AppData").join("index.json"),
            desk,
            desktop,
            _dir: dir,
        }
    }

    fn open(s: &Sandbox) -> DrawerStore {
        DrawerStore::open(&s.drawer, &s.desktop, &s.index).unwrap()
    }

    fn make(dir: &Path, name: &str) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, "x").unwrap();
        p
    }

    fn names(store: &DrawerStore) -> Vec<String> {
        store.items().iter().map(|i| i.name.clone()).collect()
    }

    #[test]
    fn stash_moves_the_file_and_the_index_survives_a_restart() {
        let s = sandbox();
        let mut store = open(&s);
        let src = make(&s.desk, "a.txt");
        let item = store.stash(&src, Some((10.0, 20.0)), 1000.0).unwrap();
        assert_eq!(item.name, "a.txt");
        assert!(!src.exists());
        assert!(s.drawer.join("a.txt").exists());
        assert_eq!(names(&store), vec!["a.txt"]);

        let reopened = open(&s);
        assert_eq!(names(&reopened), vec!["a.txt"]);
        assert_eq!(
            reopened.original_directory("a.txt"),
            Some(s.desk.to_string_lossy().as_ref())
        );
        assert_eq!(reopened.items()[0].added_at, 1000.0);
    }

    #[test]
    fn a_name_collision_gets_a_number_and_put_back_uses_the_original_name() {
        let s = sandbox();
        let mut store = open(&s);
        store.stash(&make(&s.desk, "a.txt"), None, 1.0).unwrap();
        let second = store.stash(&make(&s.desk, "a.txt"), None, 2.0).unwrap();
        assert_eq!(second.name, "a 2.txt");
        let r = store.put_back("a 2.txt").unwrap();
        assert_eq!(r.destination, s.desk.join("a.txt"));
        assert!(r.destination.exists());
    }

    #[test]
    fn put_back_returns_to_the_original_folder_without_a_position() {
        let s = sandbox();
        let mut store = open(&s);
        let src = make(&s.desk, "b.txt");
        store.stash(&src, Some((1.0, 2.0)), 1.0).unwrap();
        let r = store.put_back("b.txt").unwrap();
        assert!(src.exists());
        assert!(store.items().is_empty());
        assert_eq!(r.desktop_position, None, "no position outside the Desktop");
    }

    #[test]
    fn put_back_falls_back_to_the_desktop_when_the_folder_is_gone() {
        let s = sandbox();
        let mut store = open(&s);
        store.stash(&make(&s.desk, "c.txt"), None, 1.0).unwrap();
        fs::remove_dir_all(&s.desk).unwrap();
        let r = store.put_back("c.txt").unwrap();
        assert_eq!(r.destination, s.desktop.join("c.txt"));
        assert!(r.destination.exists());
    }

    #[test]
    fn a_desktop_file_comes_back_with_its_icon_position() {
        let s = sandbox();
        let mut store = open(&s);
        let src = make(&s.desktop, "d.txt");
        assert!(store.is_on_desktop(&src));
        store.stash(&src, Some((5.0, 6.0)), 1.0).unwrap();
        let reopened_position = {
            let mut again = open(&s); // survives a restart
            again.put_back("d.txt").unwrap().desktop_position
        };
        assert_eq!(reopened_position, Some((5.0, 6.0)));
    }

    #[test]
    fn a_position_is_ignored_for_files_not_on_the_desktop() {
        let s = sandbox();
        let mut store = open(&s);
        store
            .stash(&make(&s.desk, "e.txt"), Some((9.0, 9.0)), 1.0)
            .unwrap();
        let r = store.move_to_desktop("e.txt").unwrap();
        assert_eq!(r.destination, s.desktop.join("e.txt"));
        assert_eq!(r.desktop_position, None);
    }

    #[test]
    fn hand_placed_files_are_adopted_and_go_to_the_desktop() {
        let s = sandbox();
        let mut store = open(&s);
        make(&s.drawer, "handmade.txt");
        store.reload();
        assert_eq!(names(&store), vec!["handmade.txt"]);
        let r = store.put_back("handmade.txt").unwrap();
        assert_eq!(r.destination, s.desktop.join("handmade.txt"));
    }

    #[test]
    fn items_are_ordered_by_when_they_were_added() {
        let s = sandbox();
        let mut store = open(&s);
        store.stash(&make(&s.desk, "zebra.txt"), None, 1.0).unwrap();
        store.stash(&make(&s.desk, "apple.txt"), None, 2.0).unwrap();
        store.stash(&make(&s.desk, "mango.txt"), None, 3.0).unwrap();
        assert_eq!(names(&store), vec!["zebra.txt", "apple.txt", "mango.txt"]);
        assert_eq!(
            names(&open(&s)),
            vec!["zebra.txt", "apple.txt", "mango.txt"]
        );
    }

    #[test]
    fn hidden_and_system_files_stay_out() {
        let s = sandbox();
        let mut store = open(&s);
        make(&s.drawer, "desktop.ini");
        make(&s.drawer, "Thumbs.db");
        make(&s.drawer, ".hidden");
        make(&s.drawer, "real.txt");
        store.reload();
        assert_eq!(names(&store), vec!["real.txt"]);
    }

    #[test]
    fn reload_forgets_files_that_left_the_drawer() {
        let s = sandbox();
        let mut store = open(&s);
        store.stash(&make(&s.desk, "gone.txt"), None, 1.0).unwrap();
        fs::remove_file(s.drawer.join("gone.txt")).unwrap();
        store.reload();
        assert!(store.items().is_empty());
        assert_eq!(store.original_directory("gone.txt"), None);
        let index_text = fs::read_to_string(&s.index).unwrap();
        assert!(!index_text.contains("gone.txt"));
    }

    #[test]
    fn stash_refuses_what_it_must_not_touch() {
        let s = sandbox();
        let mut store = open(&s);
        let inside = make(&s.drawer, "inside.txt");
        assert_eq!(
            store.stash(&inside, None, 1.0),
            Err(DrawerError::AlreadyInside)
        );
        assert_eq!(
            store.stash(&s.drawer, None, 1.0),
            Err(DrawerError::ContainsDrawer)
        );
        let home = s.drawer.parent().unwrap().to_path_buf();
        assert_eq!(
            store.stash(&home, None, 1.0),
            Err(DrawerError::ContainsDrawer),
            "an ancestor of the drawer"
        );
        assert_eq!(
            store.stash(&s.desk.join("nope.txt"), None, 1.0),
            Err(DrawerError::MissingSource)
        );
        assert!(inside.exists() && home.exists(), "nothing was moved");
    }

    #[test]
    fn folders_move_too_and_come_back_whole() {
        let s = sandbox();
        let mut store = open(&s);
        let folder = s.desk.join("Projects");
        fs::create_dir_all(folder.join("inner")).unwrap();
        fs::write(folder.join("inner/a.txt"), "x").unwrap();
        store.stash(&folder, None, 1.0).unwrap();
        assert!(s.drawer.join("Projects/inner/a.txt").exists());
        store.put_back("Projects").unwrap();
        assert!(folder.join("inner/a.txt").exists());
    }

    #[test]
    fn move_all_to_desktop_and_put_everything_back() {
        let s = sandbox();
        let mut store = open(&s);
        store.stash(&make(&s.desk, "one.txt"), None, 1.0).unwrap();
        store.stash(&make(&s.desk, "two.txt"), None, 2.0).unwrap();
        store.stash(&make(&s.desk, "three.txt"), None, 3.0).unwrap();
        fs::remove_file(s.drawer.join("two.txt")).unwrap(); // vanished by hand: skipped, not a failure
        let (moved, failed) = store.move_all(true);
        assert_eq!((moved.len(), failed), (2, 0));
        assert!(s.desktop.join("one.txt").exists() && s.desktop.join("three.txt").exists());
        assert!(store.items().is_empty());

        store
            .stash(&s.desktop.join("one.txt"), Some((1.0, 1.0)), 4.0)
            .unwrap();
        let (moved, failed) = store.move_all(false);
        assert_eq!((moved.len(), failed), (1, 0));
        assert!(
            s.desktop.join("one.txt").exists(),
            "it came from the Desktop, so it goes back there"
        );
        assert_eq!(moved[0].desktop_position, Some((1.0, 1.0)));
    }

    #[test]
    fn put_back_of_a_missing_item_reports_not_found_and_cleans_up() {
        let s = sandbox();
        let mut store = open(&s);
        assert_eq!(store.put_back("ghost.txt"), Err(DrawerError::NotFound));
    }

    #[test]
    fn unicode_names_and_windows_style_paths_round_trip_through_the_index() {
        let s = sandbox();
        let mut store = open(&s);
        let name = "résumé 日本語 🎉 (v2) it's.txt";
        store.stash(&make(&s.desk, name), None, 1.0).unwrap();
        let again = open(&s);
        assert_eq!(names(&again), vec![name.to_string()]);
        assert_eq!(
            again.original_directory(name),
            Some(s.desk.to_string_lossy().as_ref())
        );
    }

    #[test]
    fn a_corrupt_index_is_ignored_and_the_drawer_still_works() {
        let s = sandbox();
        fs::create_dir_all(s.index.parent().unwrap()).unwrap();
        fs::write(&s.index, "{ this is not json").unwrap();
        make(
            &{
                fs::create_dir_all(&s.drawer).unwrap();
                s.drawer.clone()
            },
            "kept.txt",
        );
        let mut store = open(&s);
        assert_eq!(
            names(&store),
            vec!["kept.txt"],
            "files are never lost because the index is bad"
        );
        store.stash(&make(&s.desk, "new.txt"), None, 5.0).unwrap();
        assert_eq!(names(&open(&s)).len(), 2);
    }
}
