//! Small helpers for talking to Win32.

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::CoTaskMemFree;

/// Null-terminated UTF-16.
pub fn wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

pub fn wide_path(p: &Path) -> Vec<u16> {
    p.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
}

pub fn pcwstr(w: &[u16]) -> PCWSTR {
    PCWSTR(w.as_ptr())
}

/// Text up to the first null.
pub fn from_wide(buf: &[u16]) -> String {
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}

/// Takes a shell-allocated string and frees it.
pub unsafe fn take_pwstr(p: PWSTR) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = p.to_string().ok();
    CoTaskMemFree(Some(p.0 as *const _));
    s
}

pub fn path_from_wide(buf: &[u16]) -> PathBuf {
    use std::os::windows::ffi::OsStringExt;
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    PathBuf::from(std::ffi::OsString::from_wide(&buf[..end]))
}

/// Signed client coordinates packed in an LPARAM (GET_X_LPARAM / GET_Y_LPARAM).
pub fn lparam_point(l: LPARAM) -> (i32, i32) {
    let v = l.0 as u32;
    ((v & 0xFFFF) as u16 as i16 as i32, ((v >> 16) & 0xFFFF) as u16 as i16 as i32)
}

pub fn loword(w: WPARAM) -> u32 {
    (w.0 & 0xFFFF) as u32
}

/// HWND is a raw pointer and not `Send`; threads carry it as an integer.
pub fn hwnd_to_isize(h: HWND) -> isize {
    h.0 as isize
}

pub fn hwnd_from_isize(v: isize) -> HWND {
    HWND(v as *mut _)
}
