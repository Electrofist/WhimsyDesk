//! Turns the menu from `menu.rs` into a Win32 popup menu and returns the chosen command.

use super::util::{pcwstr, wide};
use crate::menu::{commands, Command, Entry};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, DestroyMenu, PostMessageW, SetForegroundWindow, TrackPopupMenu, HMENU, MF_CHECKED,
    MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, TPM_NONOTIFY, TPM_RETURNCMD, TPM_RIGHTBUTTON, WM_NULL,
};

/// Fills `menu`; ids run 1, 2, 3... in the same order as `menu::commands`.
unsafe fn fill(menu: HMENU, entries: &[Entry], next: &mut usize) {
    for e in entries {
        match e {
            Entry::Item { label, enabled, checked, .. } => {
                let mut flags = MF_STRING;
                if !enabled {
                    flags |= MF_GRAYED;
                }
                if *checked {
                    flags |= MF_CHECKED;
                }
                let text = wide(label);
                let _ = AppendMenuW(menu, flags, *next, pcwstr(&text));
                *next += 1;
            }
            Entry::Submenu { label, entries } => {
                let Ok(sub) = CreatePopupMenu() else { continue };
                fill(sub, entries, next);
                let text = wide(label);
                // The parent menu owns and destroys the submenu.
                let _ = AppendMenuW(menu, MF_POPUP, sub.0 as usize, pcwstr(&text));
            }
            Entry::Separator => {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
            }
        }
    }
}

/// Shows the menu at a screen point and waits. None when dismissed.
pub fn show(hwnd: HWND, entries: &[Entry], at: (i32, i32)) -> Option<Command> {
    let list = commands(entries);
    unsafe {
        let menu = CreatePopupMenu().ok()?;
        let mut next = 1;
        fill(menu, entries, &mut next);
        // Needed so the menu closes when the user clicks elsewhere (TrackPopupMenu remarks).
        let _ = SetForegroundWindow(hwnd);
        let chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, at.0, at.1, None, hwnd, None).0;
        let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        if chosen <= 0 {
            return None;
        }
        list.get(chosen as usize - 1).cloned()
    }
}
