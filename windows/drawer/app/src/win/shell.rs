//! Explorer and system services: theme and power settings, monitors, the Desktop icons window.

use super::util::{pcwstr, take_pwstr, wide, wide_path};
use crate::placement::{Monitor, RectPx};
use crate::sprite::Sprite;
use std::path::{Path, PathBuf};
use windows::core::{BOOL, GUID};
use windows::Win32::Foundation::{ERROR_SUCCESS, HWND, LPARAM, RECT, SIZE};
use windows::Win32::Graphics::Gdi::{
    DeleteObject, EnumDisplayMonitors, GetDC, GetDIBits, GetMonitorInfoW, GetObjectW, ReleaseDC,
    BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC, HMONITOR,
    MONITORINFO,
};
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Shell::{
    ILCreateFromPathW, ILFree, IShellItemImageFactory, SHCreateItemFromParsingName,
    SHGetKnownFolderPath, SHOpenFolderAndSelectItems, ShellExecuteW, KF_FLAG_DEFAULT,
    SIIGBF_ICONONLY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AllowSetForegroundWindow, SystemParametersInfoW, ASFW_ANY, SPI_GETCLIENTAREAANIMATION,
    SW_SHOWNORMAL, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
};

/// Windows "app mode": dark unless AppsUseLightTheme is 1 (missing means light).
pub fn is_dark_mode() -> bool {
    let key = wide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    let name = wide("AppsUseLightTheme");
    let mut value = 1u32;
    let mut bytes = 4u32;
    unsafe {
        let r = RegGetValueW(
            HKEY_CURRENT_USER,
            pcwstr(&key),
            pcwstr(&name),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut value as *mut _ as *mut _),
            Some(&mut bytes),
        );
        r == ERROR_SUCCESS && value == 0
    }
}

/// Settings > Accessibility > Visual effects > Animation effects turned off.
pub fn reduce_motion() -> bool {
    let mut on = BOOL(1);
    unsafe {
        let _ = SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some(&mut on as *mut _ as *mut _),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        );
    }
    !on.as_bool()
}

/// Battery saver / energy saver is on.
pub fn battery_saver() -> bool {
    let mut s = SYSTEM_POWER_STATUS::default();
    unsafe { GetSystemPowerStatus(&mut s).is_ok() && s.SystemStatusFlag == 1 }
}

/// The top-level window that holds the Desktop icons: Progman, or a WorkerW once Explorer has
/// split the wallpaper off (slideshows and wallpaper changes do this).
pub fn desktop_icons_host() -> Option<HWND> {
    use windows::core::w;
    use windows::Win32::UI::WindowsAndMessaging::{FindWindowExW, FindWindowW};
    unsafe {
        if let Ok(progman) = FindWindowW(w!("Progman"), None) {
            if FindWindowExW(Some(progman), None, w!("SHELLDLL_DefView"), None).is_ok() {
                return Some(progman);
            }
        }
        let mut after = None;
        for _ in 0..64 {
            let worker = FindWindowExW(None, after, w!("WorkerW"), None).ok()?;
            if FindWindowExW(Some(worker), None, w!("SHELLDLL_DefView"), None).is_ok() {
                return Some(worker);
            }
            after = Some(worker);
        }
        None
    }
}

pub fn monitors() -> Vec<Monitor> {
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let list = &mut *(data.0 as *mut Vec<Monitor>);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(m, &mut info).as_bool() {
            let (mut dx, mut dy) = (96u32, 96u32);
            let _ = GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
            let r = |r: RECT| RectPx::new(r.left, r.top, r.right, r.bottom);
            list.push(Monitor {
                bounds: r(info.rcMonitor),
                work: r(info.rcWork),
                dpi_scale: dx.max(48) as f64 / 96.0,
                primary: info.dwFlags & 1 != 0, // MONITORINFOF_PRIMARY
            });
        }
        BOOL(1)
    }
    let mut list: Vec<Monitor> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut list as *mut _ as isize));
    }
    list
}

pub fn known_folder(id: &GUID) -> Option<PathBuf> {
    unsafe {
        SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None)
            .ok()
            .and_then(|p| take_pwstr(p))
            .map(PathBuf::from)
    }
}

/// The shell icon for a file, `px` pixels square.
pub fn file_icon(path: &Path, px: i32) -> Option<Sprite> {
    let p = wide_path(path);
    unsafe {
        let factory: IShellItemImageFactory = SHCreateItemFromParsingName(pcwstr(&p), None).ok()?;
        let bitmap = factory
            .GetImage(SIZE { cx: px, cy: px }, SIIGBF_ICONONLY)
            .ok()?;
        let image = bitmap_to_sprite(bitmap);
        let _ = DeleteObject(bitmap.into());
        image
    }
}

/// Reads a 32-bit HBITMAP as a premultiplied picture. Shell bitmaps are usually premultiplied, but
/// some icons come back straight or without alpha; both are handled.
unsafe fn bitmap_to_sprite(bitmap: HBITMAP) -> Option<Sprite> {
    let mut bm = BITMAP::default();
    if GetObjectW(
        bitmap.into(),
        std::mem::size_of::<BITMAP>() as i32,
        Some(&mut bm as *mut _ as *mut _),
    ) == 0
    {
        return None;
    }
    let (w, h) = (bm.bmWidth, bm.bmHeight.abs());
    if w <= 0 || h <= 0 {
        return None;
    }
    let mut info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bgra = vec![0u8; (w * h * 4) as usize];
    let dc: HDC = GetDC(None);
    let lines = GetDIBits(
        dc,
        bitmap,
        0,
        h as u32,
        Some(bgra.as_mut_ptr() as *mut _),
        &mut info,
        DIB_RGB_COLORS,
    );
    ReleaseDC(None, dc);
    if lines == 0 {
        return None;
    }
    let has_alpha = bgra.chunks(4).any(|p| p[3] != 0);
    let straight = has_alpha
        && bgra
            .chunks(4)
            .any(|p| p[0] > p[3] || p[1] > p[3] || p[2] > p[3]);
    for p in bgra.chunks_exact_mut(4) {
        let a = if has_alpha { p[3] } else { 255 };
        if straight {
            for c in &mut p[..3] {
                *c = ((*c as u32 * a as u32 + 127) / 255) as u8;
            }
        }
        p[3] = a;
    }
    Some(Sprite::from_bgra(w as usize, h as usize, bgra))
}

/// Opens a file or folder the way a double-click in Explorer would. False if Windows refused.
pub fn open(path: &Path) -> bool {
    let file = wide_path(path);
    let verb = wide("open");
    unsafe {
        let _ = AllowSetForegroundWindow(ASFW_ANY);
        let r = ShellExecuteW(
            None,
            pcwstr(&verb),
            pcwstr(&file),
            None,
            None,
            SW_SHOWNORMAL,
        );
        r.0 as isize > 32
    }
}

/// Opens the folder holding `path` in Explorer with the item selected.
pub fn show_in_explorer(path: &Path) -> bool {
    let p = wide_path(path);
    unsafe {
        let pidl = ILCreateFromPathW(pcwstr(&p));
        if pidl.is_null() {
            return false;
        }
        let _ = AllowSetForegroundWindow(ASFW_ANY);
        let ok = SHOpenFolderAndSelectItems(pidl, None, 0).is_ok();
        ILFree(Some(pidl));
        ok
    }
}
