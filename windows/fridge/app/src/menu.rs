//! The right-click menu as data. PORT-SPEC §9, with Windows wording. The Win32 layer turns this
//! into a popup menu and hands the chosen command back to the model.

use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    EditNote(String),
    SetNoteColor(String, usize),
    PeelNote(String),
    OpenOriginal(PathBuf),
    TakePhotoDown(String),
    OpenItem(String),
    PutBack(String),
    ShowInExplorer(String),
    OpenFridgeFolder,
    MoveEverythingToDesktop,
    ToggleStartWithWindows,
    Quit,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Entry {
    Item { label: String, command: Command, enabled: bool, checked: bool },
    Submenu { label: String, entries: Vec<Entry> },
    Separator,
}

impl Entry {
    pub fn item(label: &str, command: Command) -> Entry {
        Entry::Item { label: label.to_string(), command, enabled: true, checked: false }
    }
}

pub const NOTE_COLOR_NAMES: [&str; 4] = ["Yellow", "Pink", "Mint", "Blue"];

/// What the pointer was over when the menu opened.
pub enum Target {
    Note { id: String, color: usize },
    Photo { id: String, original: Option<PathBuf> },
    Item { id: String },
    Nothing,
}

pub fn build(target: Target, fridge_empty: bool, start_with_windows: bool) -> Vec<Entry> {
    let mut m = Vec::new();
    match target {
        Target::Note { id, color } => {
            m.push(Entry::item("Edit Note", Command::EditNote(id.clone())));
            let colours = NOTE_COLOR_NAMES
                .iter()
                .enumerate()
                .map(|(i, name)| Entry::Item {
                    label: name.to_string(),
                    command: Command::SetNoteColor(id.clone(), i),
                    enabled: true,
                    checked: i == color,
                })
                .collect();
            m.push(Entry::Submenu { label: "Color".into(), entries: colours });
            m.push(Entry::item("Peel Off Note", Command::PeelNote(id)));
            m.push(Entry::Separator);
        }
        Target::Photo { id, original } => {
            if let Some(path) = original {
                m.push(Entry::item("Open Original", Command::OpenOriginal(path)));
            }
            m.push(Entry::item("Take Photo Down", Command::TakePhotoDown(id)));
            m.push(Entry::Separator);
        }
        Target::Item { id } => {
            m.push(Entry::item("Open", Command::OpenItem(id.clone())));
            m.push(Entry::item("Put Back", Command::PutBack(id.clone())));
            m.push(Entry::item("Show in Explorer", Command::ShowInExplorer(id)));
            m.push(Entry::Separator);
        }
        Target::Nothing => {}
    }
    m.push(Entry::item("Open Fridge Folder", Command::OpenFridgeFolder));
    m.push(Entry::Item {
        label: "Move Everything to Desktop".into(),
        command: Command::MoveEverythingToDesktop,
        enabled: !fridge_empty,
        checked: false,
    });
    m.push(Entry::Separator);
    m.push(Entry::Item {
        label: "Start with Windows".into(),
        command: Command::ToggleStartWithWindows,
        enabled: true,
        checked: start_with_windows,
    });
    m.push(Entry::item("Quit Desktop Fridge", Command::Quit));
    m
}

/// Flattens commands so the Win32 menu can use numeric ids (1-based; 0 means dismissed).
pub fn commands(entries: &[Entry]) -> Vec<Command> {
    let mut out = Vec::new();
    fn walk(e: &[Entry], out: &mut Vec<Command>) {
        for entry in e {
            match entry {
                Entry::Item { command, .. } => out.push(command.clone()),
                Entry::Submenu { entries, .. } => walk(entries, out),
                Entry::Separator => {}
            }
        }
    }
    walk(entries, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(e: &[Entry]) -> Vec<String> {
        e.iter()
            .map(|x| match x {
                Entry::Item { label, .. } | Entry::Submenu { label, .. } => label.clone(),
                Entry::Separator => "-".into(),
            })
            .collect()
    }

    #[test]
    fn item_menu() {
        let m = build(Target::Item { id: "A".into() }, false, false);
        assert_eq!(
            labels(&m),
            ["Open", "Put Back", "Show in Explorer", "-", "Open Fridge Folder", "Move Everything to Desktop", "-", "Start with Windows", "Quit Desktop Fridge"]
        );
    }

    #[test]
    fn empty_fridge_greys_move_everything() {
        let m = build(Target::Nothing, true, true);
        let move_all = m.iter().find(|e| matches!(e, Entry::Item { command: Command::MoveEverythingToDesktop, .. })).unwrap();
        assert!(matches!(move_all, Entry::Item { enabled: false, .. }));
        let start = m.iter().find(|e| matches!(e, Entry::Item { command: Command::ToggleStartWithWindows, .. })).unwrap();
        assert!(matches!(start, Entry::Item { checked: true, .. }));
    }

    #[test]
    fn note_menu_checks_the_colour() {
        let m = build(Target::Note { id: "N".into(), color: 2 }, false, false);
        let Entry::Submenu { entries, .. } = &m[1] else { panic!() };
        let checked: Vec<bool> = entries.iter().map(|e| matches!(e, Entry::Item { checked: true, .. })).collect();
        assert_eq!(checked, [false, false, true, false]);
        assert_eq!(commands(&m).len(), 1 + 4 + 1 + 4);
    }

    #[test]
    fn photo_without_original_has_no_open() {
        let m = build(Target::Photo { id: "P".into(), original: None }, false, false);
        assert_eq!(labels(&m)[0], "Take Photo Down");
    }
}
