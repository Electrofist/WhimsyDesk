//! Sticky notes and photo magnets on the outside of the doors. Port of `DoorNotes.swift`.
//! Kept in `.fridge-notes.json` beside the fridge index; magnet thumbnails in `.magnets`.

use crate::iso;
use crate::store::write_atomic;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoteKind {
    Note,
    Photo,
}

/// Fields in alphabetical order so JSON keys come out sorted.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DoorNote {
    /// Index into the sticky note palette (or magnet colour for photos).
    pub color: usize,
    #[serde(with = "iso::serde_iso")]
    pub created_at: f64,
    /// "fridge" or "freezer".
    pub door: String,
    pub id: String,
    pub kind: NoteKind,
    /// Photo magnets: where the picture came from.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub original_path: Option<String>,
    /// Photo magnets: thumbnail file name inside `.magnets`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub photo_name: Option<String>,
    #[serde(default)]
    pub text: String,
    /// Radians. Every note sits a little crooked.
    pub tilt: f64,
    /// Centre in door space (origin at the door's bottom left), points.
    pub x: f64,
    pub y: f64,
}

impl DoorNote {
    pub fn new_note(door: &str, x: f64, y: f64, color: usize, tilt: f64) -> Self {
        Self {
            color,
            created_at: iso::now(),
            door: door.to_string(),
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            kind: NoteKind::Note,
            original_path: None,
            photo_name: None,
            text: String::new(),
            tilt,
            x,
            y,
        }
    }
}

#[derive(Serialize, Deserialize)]
struct IndexFile {
    notes: Vec<DoorNote>,
    version: u32,
}

pub struct DoorNotesStore {
    pub root: PathBuf,
    notes: Vec<DoorNote>,
}

impl DoorNotesStore {
    pub const INDEX_NAME: &'static str = ".fridge-notes.json";
    pub const PHOTO_FOLDER: &'static str = ".magnets";
    /// Enough to cover a door, few enough to stay tidy.
    pub const MAX_PER_DOOR: usize = 16;
    /// Short reminders, not documents. Counted in UTF-16 units, like the Mac app.
    pub const MAX_TEXT_LENGTH: usize = 90;

    pub fn open(root: impl Into<PathBuf>) -> Self {
        let mut s = Self { root: root.into(), notes: Vec::new() };
        s.load();
        // A magnet whose picture went missing has nothing left to show.
        let before = s.notes.len();
        let folder = s.photo_folder();
        s.notes.retain(|n| {
            n.kind != NoteKind::Photo || n.photo_name.as_ref().map(|p| folder.join(p).exists()).unwrap_or(false)
        });
        if s.notes.len() != before {
            s.save();
        }
        s
    }

    pub fn notes(&self) -> &[DoorNote] {
        &self.notes
    }

    pub fn photo_folder(&self) -> PathBuf {
        self.root.join(Self::PHOTO_FOLDER)
    }

    pub fn photo_path(&self, note: &DoorNote) -> Option<PathBuf> {
        note.photo_name.as_ref().map(|n| self.photo_folder().join(n))
    }

    pub fn note(&self, id: &str) -> Option<&DoorNote> {
        self.notes.iter().find(|n| n.id == id)
    }

    pub fn is_full(&self, door: &str) -> bool {
        self.notes.iter().filter(|n| n.door == door).count() >= Self::MAX_PER_DOOR
    }

    /// Colour for a new sticky note: the next one after the last note's colour.
    pub fn next_note_color(&self) -> usize {
        self.notes.iter().rev().find(|n| n.kind == NoteKind::Note).map(|n| (n.color + 1) % 4).unwrap_or(0)
    }

    pub fn add(&mut self, mut note: DoorNote) {
        note.text = truncate_utf16(&note.text, Self::MAX_TEXT_LENGTH);
        self.notes.push(note);
        self.save();
    }

    /// Replaces the note with the same id. Moving it to the end also puts it on top.
    pub fn update(&mut self, mut note: DoorNote, bring_to_front: bool) {
        let Some(index) = self.notes.iter().position(|n| n.id == note.id) else { return };
        note.text = truncate_utf16(&note.text, Self::MAX_TEXT_LENGTH);
        if bring_to_front {
            self.notes.remove(index);
            self.notes.push(note);
        } else {
            self.notes[index] = note;
        }
        self.save();
    }

    pub fn remove(&mut self, id: &str) {
        if let Some(note) = self.note(id).cloned() {
            if let Some(p) = self.photo_path(&note) {
                let _ = fs::remove_file(p);
            }
        }
        self.notes.retain(|n| n.id != id);
        self.save();
    }

    /// Writes PNG data for a new magnet and returns the file name to store on the note.
    pub fn save_photo(&self, png: &[u8]) -> std::io::Result<String> {
        fs::create_dir_all(self.photo_folder())?;
        let name = format!("{}.png", uuid::Uuid::new_v4().to_string().to_uppercase());
        write_atomic(&self.photo_folder().join(&name), png)?;
        Ok(name)
    }

    fn index_path(&self) -> PathBuf {
        self.root.join(Self::INDEX_NAME)
    }

    fn load(&mut self) {
        if let Ok(data) = fs::read(self.index_path()) {
            if let Ok(file) = serde_json::from_slice::<IndexFile>(&data) {
                self.notes = file.notes;
            }
        }
    }

    fn save(&self) {
        let file = IndexFile { notes: self.notes.clone(), version: 1 };
        if let Ok(data) = serde_json::to_vec_pretty(&file) {
            let _ = write_atomic(&self.index_path(), &data);
        }
    }
}

/// Keeps at most `max` UTF-16 code units without splitting a character.
pub fn truncate_utf16(s: &str, max: usize) -> String {
    let mut units = 0;
    let mut out = String::new();
    for c in s.chars() {
        let n = c.len_utf16();
        if units + n > max {
            break;
        }
        units += n;
        out.push(c);
    }
    out
}

pub fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notes_persist_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = DoorNotesStore::open(dir.path());
        let a = DoorNote::new_note("fridge", 50.0, 60.0, 0, 0.02);
        let b = DoorNote::new_note("fridge", 80.0, 90.0, 1, -0.03);
        store.add(a.clone());
        store.add(b.clone());
        store.update(a.clone(), true);
        let again = DoorNotesStore::open(dir.path());
        let ids: Vec<_> = again.notes().iter().map(|n| n.id.clone()).collect();
        assert_eq!(ids, vec![b.id, a.id]);
    }

    #[test]
    fn text_is_capped_at_90_units() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = DoorNotesStore::open(dir.path());
        let mut n = DoorNote::new_note("freezer", 10.0, 10.0, 2, 0.0);
        n.text = "x".repeat(200);
        store.add(n);
        assert_eq!(store.notes()[0].text.len(), 90);
    }

    #[test]
    fn colours_cycle() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = DoorNotesStore::open(dir.path());
        assert_eq!(store.next_note_color(), 0);
        store.add(DoorNote::new_note("fridge", 1.0, 1.0, 3, 0.0));
        assert_eq!(store.next_note_color(), 0);
        store.add(DoorNote::new_note("fridge", 1.0, 1.0, 1, 0.0));
        assert_eq!(store.next_note_color(), 2);
    }

    #[test]
    fn magnets_without_pictures_are_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = DoorNotesStore::open(dir.path());
        let name = store.save_photo(b"png").unwrap();
        let mut photo = DoorNote::new_note("fridge", 1.0, 1.0, 0, 0.0);
        photo.kind = NoteKind::Photo;
        photo.photo_name = Some(name.clone());
        store.add(photo.clone());
        assert_eq!(DoorNotesStore::open(dir.path()).notes().len(), 1);
        fs::remove_file(store.photo_folder().join(name)).unwrap();
        assert_eq!(DoorNotesStore::open(dir.path()).notes().len(), 0);
    }

    #[test]
    fn surrogate_pairs_are_not_split() {
        assert_eq!(truncate_utf16("ab😀", 3), "ab");
        assert_eq!(utf16_len("😀"), 2);
    }
}
