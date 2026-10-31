//! The in-place note editor: a small popup with an EDIT control over the note's text area.
//! Unrotated. Enter finishes, Alt+Enter adds a line, Esc cancels, losing focus finishes.
//! It never touches the app state; it posts `WM_EDITOR_DONE` to the main window
//! (wParam 1 = save, 0 = cancel; lParam = editor generation, so stale posts are ignored).

use super::util::{from_wide, pcwstr, wide};
use std::cell::RefCell;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, CreateSolidBrush, DeleteObject, SetBkColor, SetTextColor, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET,
    DEFAULT_PITCH, FF_DONTCARE, FW_BOLD, HBRUSH, HDC, HFONT, OUT_TT_PRECIS, CLEARTYPE_QUALITY,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{EM_REPLACESEL, EM_SETLIMITTEXT, EM_SETMARGINS, EM_SETSEL};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, SetFocus, VK_CONTROL, VK_ESCAPE, VK_RETURN};
use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetWindowTextLengthW, GetWindowTextW, PostMessageW,
    RegisterClassExW, SendMessageW, SetForegroundWindow, SetWindowTextW, ShowWindow, CS_HREDRAW, CS_VREDRAW,
    EC_LEFTMARGIN, EC_RIGHTMARGIN, ES_AUTOVSCROLL, ES_CENTER, ES_MULTILINE, SW_SHOW, WINDOW_EX_STYLE, WINDOW_STYLE,
    WM_CHAR, WM_CTLCOLOREDIT, WM_KEYDOWN, WM_KILLFOCUS, WM_SETFONT, WM_SYSCHAR, WM_SYSKEYDOWN, WNDCLASSEXW,
    WS_CHILD, WS_EX_TOOLWINDOW, WS_POPUP, WS_VISIBLE,
};

pub const WM_EDITOR_DONE: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 3;
const CLASS: PCWSTR = w!("DesktopFridgeNoteEditor");
const MAX_CHARS: usize = 90;

/// Note paper colours (PORT-SPEC §7) and the ink.
const PAPER: [(u8, u8, u8); 4] = [(0xFF, 0xE8, 0x73), (0xFF, 0xB3, 0xC7), (0xB8, 0xF0, 0xC8), (0xB5, 0xDD, 0xFF)];
const INK: (u8, u8, u8) = (41, 43, 56);

struct State {
    main: HWND,
    host: HWND,
    edit: HWND,
    font: HFONT,
    brush: HBRUSH,
    paper: COLORREF,
    generation: isize,
    closing: bool,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
    static GENERATION: RefCell<isize> = const { RefCell::new(0) };
}

fn rgb(c: (u8, u8, u8)) -> COLORREF {
    COLORREF(c.0 as u32 | (c.1 as u32) << 8 | (c.2 as u32) << 16)
}

pub fn register_class() {
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(host_proc),
            hInstance: instance.into(),
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&class);
    }
}

pub fn is_open() -> bool {
    STATE.with(|s| s.borrow().is_some())
}

pub fn generation() -> isize {
    STATE.with(|s| s.borrow().as_ref().map(|s| s.generation).unwrap_or(-1))
}

/// Opens the editor over `rect` (screen pixels). `font_px` is the em height in pixels.
pub fn open(main: HWND, rect: RECT, text: &str, color: usize, font_px: i32, face: &str) {
    close();
    let paper = rgb(PAPER[color % PAPER.len()]);
    let generation = GENERATION.with(|g| {
        *g.borrow_mut() += 1;
        *g.borrow()
    });
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        let (w, h) = ((rect.right - rect.left).max(8), (rect.bottom - rect.top).max(8));
        let Ok(host) = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            CLASS,
            w!(""),
            WS_POPUP,
            rect.left,
            rect.top,
            w,
            h,
            None,
            None,
            Some(instance.into()),
            None,
        ) else {
            return;
        };
        let style = WINDOW_STYLE((ES_MULTILINE | ES_CENTER | ES_AUTOVSCROLL) as u32) | WS_CHILD | WS_VISIBLE;
        let Ok(edit) =
            CreateWindowExW(WINDOW_EX_STYLE(0), w!("EDIT"), w!(""), style, 0, 0, w, h, Some(host), None, Some(instance.into()), None)
        else {
            let _ = DestroyWindow(host);
            return;
        };
        let face_w = wide(face);
        let font = CreateFontW(
            -font_px.max(6),
            0,
            0,
            0,
            FW_BOLD.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_TT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            pcwstr(&face_w),
        );
        let brush = CreateSolidBrush(paper);
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        SendMessageW(edit, EM_SETMARGINS, Some(WPARAM((EC_LEFTMARGIN | EC_RIGHTMARGIN) as usize)), Some(LPARAM(0)));
        SendMessageW(edit, EM_SETLIMITTEXT, Some(WPARAM(MAX_CHARS)), Some(LPARAM(0)));
        let shown = wide(&text.replace("\r\n", "\n").replace('\n', "\r\n"));
        let _ = SetWindowTextW(edit, pcwstr(&shown));
        SendMessageW(edit, EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));
        let _ = SetWindowSubclass(edit, Some(edit_proc), 1, 0);
        STATE.with(|s| {
            *s.borrow_mut() = Some(State { main, host, edit, font, brush, paper, generation, closing: false });
        });
        let _ = ShowWindow(host, SW_SHOW);
        let _ = SetForegroundWindow(host);
        let _ = SetFocus(Some(edit));
    }
}

/// The text as typed, with plain `\n` line breaks.
pub fn text() -> Option<String> {
    let edit = STATE.with(|s| s.borrow().as_ref().map(|s| s.edit))?;
    unsafe {
        let n = GetWindowTextLengthW(edit).max(0) as usize;
        let mut buf = vec![0u16; n + 1];
        GetWindowTextW(edit, &mut buf);
        Some(from_wide(&buf).replace("\r\n", "\n"))
    }
}

/// Closes without telling anyone. Safe to call when nothing is open.
pub fn close() {
    let state = STATE.with(|s| {
        if let Some(st) = s.borrow_mut().as_mut() {
            st.closing = true;
        }
        s.borrow().as_ref().map(|s| (s.host, s.edit, s.font, s.brush))
    });
    let Some((host, edit, font, brush)) = state else { return };
    unsafe {
        let _ = RemoveWindowSubclass(edit, Some(edit_proc), 1);
        let _ = DestroyWindow(host);
        let _ = DeleteObject(font.into());
        let _ = DeleteObject(brush.into());
    }
    STATE.with(|s| *s.borrow_mut() = None);
}

fn post_done(save: bool) {
    let target = STATE.with(|s| s.borrow().as_ref().filter(|s| !s.closing).map(|s| (s.main, s.generation)));
    if let Some((main, generation)) = target {
        unsafe {
            let _ = PostMessageW(Some(main), WM_EDITOR_DONE, WPARAM(save as usize), LPARAM(generation));
        }
    }
}

unsafe extern "system" fn host_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_CTLCOLOREDIT {
        let colors = STATE.with(|s| s.borrow().as_ref().map(|s| (s.paper, s.brush)));
        if let Some((paper, brush)) = colors {
            let dc = HDC(wparam.0 as *mut _);
            SetBkColor(dc, paper);
            SetTextColor(dc, rgb(INK));
            return LRESULT(brush.0 as isize);
        }
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM, _id: usize, _data: usize) -> LRESULT {
    let key = wparam.0 as u16;
    match msg {
        WM_KEYDOWN if key == VK_RETURN.0 => {
            post_done(true);
            return LRESULT(0);
        }
        WM_KEYDOWN if key == VK_ESCAPE.0 => {
            post_done(false);
            return LRESULT(0);
        }
        // Ctrl+A selects everything (older EDIT controls do not).
        WM_KEYDOWN if key == b'A' as u16 && GetKeyState(VK_CONTROL.0 as i32) < 0 => {
            SendMessageW(hwnd, EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));
            return LRESULT(0);
        }
        // Alt+Enter: a new line.
        WM_SYSKEYDOWN if key == VK_RETURN.0 => {
            let nl = wide("\r\n");
            SendMessageW(hwnd, EM_REPLACESEL, Some(WPARAM(1)), Some(LPARAM(nl.as_ptr() as isize)));
            return LRESULT(0);
        }
        // Swallow the characters for the keys handled above (no beep, no stray newline).
        WM_CHAR if matches!(wparam.0, 0x0D | 0x0A | 0x1B | 0x01) => return LRESULT(0),
        WM_SYSCHAR if wparam.0 == 0x0D => return LRESULT(0),
        WM_KILLFOCUS => post_done(true),
        _ => {}
    }
    DefSubclassProc(hwnd, msg, wparam, lparam)
}
