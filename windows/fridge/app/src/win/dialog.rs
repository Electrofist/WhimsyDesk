//! Alerts. Task dialogs need Common Controls 6 (from the manifest); `TaskDialogIndirect` is looked
//! up at run time so a build without the manifest still starts and falls back to MessageBox.

use super::util::{pcwstr, wide};
use windows::core::{BOOL, HRESULT, PCWSTR};
use windows::Win32::Foundation::HWND;
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::UI::Controls::{
    TASKDIALOGCONFIG, TASKDIALOGCONFIG_0, TASKDIALOG_BUTTON, TASKDIALOG_COMMON_BUTTON_FLAGS, TDCBF_CANCEL_BUTTON,
    TDCBF_OK_BUTTON, TDF_ALLOW_DIALOG_CANCELLATION, TD_WARNING_ICON,
};
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, IDOK, MB_ICONERROR, MB_ICONWARNING, MB_OK, MB_OKCANCEL, MB_SETFOREGROUND, MESSAGEBOX_STYLE,
};

const TITLE: &str = "Desktop Fridge";
const ID_CONFIRM: i32 = 100;

type TaskDialogIndirectFn = unsafe extern "system" fn(*const TASKDIALOGCONFIG, *mut i32, *mut i32, *mut BOOL) -> HRESULT;

fn task_dialog() -> Option<TaskDialogIndirectFn> {
    unsafe {
        let module = LoadLibraryW(windows::core::w!("comctl32.dll")).ok()?;
        let f = GetProcAddress(module, windows::core::s!("TaskDialogIndirect"))?;
        Some(std::mem::transmute::<unsafe extern "system" fn() -> isize, TaskDialogIndirectFn>(f))
    }
}

/// Runs a task dialog; returns the pressed button id, or None if task dialogs are unavailable.
unsafe fn run(owner: HWND, instruction: &str, content: &str, buttons: &[(i32, &str)], common: TASKDIALOG_COMMON_BUTTON_FLAGS) -> Option<i32> {
    let f = task_dialog()?;
    let title = wide(TITLE);
    let main = wide(instruction);
    let body = wide(content);
    let labels: Vec<Vec<u16>> = buttons.iter().map(|b| wide(b.1)).collect();
    let list: Vec<TASKDIALOG_BUTTON> =
        buttons.iter().zip(&labels).map(|(b, l)| TASKDIALOG_BUTTON { nButtonID: b.0, pszButtonText: pcwstr(l) }).collect();
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        hwndParent: owner,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION,
        dwCommonButtons: common,
        pszWindowTitle: pcwstr(&title),
        Anonymous1: TASKDIALOGCONFIG_0 { pszMainIcon: TD_WARNING_ICON },
        pszMainInstruction: pcwstr(&main),
        pszContent: if content.is_empty() { PCWSTR::null() } else { pcwstr(&body) },
        cButtons: list.len() as u32,
        pButtons: if list.is_empty() { std::ptr::null() } else { list.as_ptr() },
        nDefaultButton: buttons.first().map(|b| b.0).unwrap_or(0),
        ..Default::default()
    };
    let mut pressed = 0i32;
    let hr = f(&config, &mut pressed, std::ptr::null_mut(), std::ptr::null_mut());
    hr.is_ok().then_some(pressed)
}

/// "Move to Desktop" / "Cancel". True when confirmed.
pub fn confirm(owner: HWND, instruction: &str, content: &str, confirm_label: &str) -> bool {
    unsafe {
        if let Some(id) = run(owner, instruction, content, &[(ID_CONFIRM, confirm_label)], TDCBF_CANCEL_BUTTON) {
            return id == ID_CONFIRM;
        }
        message_box(owner, &format!("{instruction}\n\n{content}"), MB_OKCANCEL | MB_ICONWARNING) == IDOK.0
    }
}

pub fn alert(owner: HWND, instruction: &str, content: &str) {
    unsafe {
        if run(owner, instruction, content, &[], TDCBF_OK_BUTTON).is_none() {
            message_box(owner, &format!("{instruction}\n\n{content}"), MB_OK | MB_ICONWARNING);
        }
    }
}

/// Before the window exists (or when things are badly wrong).
pub fn fatal(message: &str) {
    unsafe {
        message_box(HWND::default(), message, MB_OK | MB_ICONERROR);
    }
}

unsafe fn message_box(owner: HWND, text: &str, style: MESSAGEBOX_STYLE) -> i32 {
    let t = wide(text);
    let c = wide(TITLE);
    let owner = if owner.is_invalid() { None } else { Some(owner) };
    MessageBoxW(owner, pcwstr(&t), pcwstr(&c), style | MB_SETFOREGROUND).0
}
