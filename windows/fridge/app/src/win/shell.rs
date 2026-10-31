//! Explorer and system services: known folders, opening files, shell icons, Desktop icon
//! positions, Start with Windows, theme and power settings, monitors.

use super::util::{from_wide, pcwstr, take_pwstr, wide, wide_path};
use crate::placement::{Monitor, RectPx};
use fridge_art::Image;
use fridge_core::store::same_path;
use std::path::{Path, PathBuf};
use windows::core::{Interface, GUID, PWSTR};
use windows::Win32::Foundation::{BOOL, ERROR_SUCCESS, LPARAM, POINT, RECT, SIZE};
use windows::Win32::Graphics::Gdi::{
    DeleteObject, EnumDisplayMonitors, GetDC, GetDIBits, GetMonitorInfoW, GetObjectW, ReleaseDC, BITMAP, BITMAPINFO,
    BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC, HMONITOR, MONITORINFO,
};
use windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, IServiceProvider, CLSCTX_LOCAL_SERVER};
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::System::Registry::{
    RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
};
use windows::Win32::System::Variant::{VARIANT, VT_I4};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Shell::Common::{ITEMIDLIST, STRRET};
use windows::Win32::UI::Shell::{
    ILCreateFromPathW, ILFree, IFolderView, IShellBrowser, IShellFolder, IShellItemImageFactory, IShellWindows,
    SHCreateItemFromParsingName, SHGetKnownFolderPath, SHOpenFolderAndSelectItems, ShellExecuteW, ShellWindows,
    StrRetToStrW, CSIDL_DESKTOP, KF_FLAG_DEFAULT, SHGDN_FORPARSING, SID_STopLevelBrowser, SIIGBF_ICONONLY, SVGIO_ALLVIEW,
    SVSI_POSITIONITEM, SWC_DESKTOP, SWFO_NEEDDISPATCH,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AllowSetForegroundWindow, SystemParametersInfoW, ASFW_ANY, SPI_GETCLIENTAREAANIMATION, SW_SHOWNORMAL,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
};

pub fn known_folder(id: &GUID) -> Option<PathBuf> {
    unsafe { SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None).ok().and_then(|p| take_pwstr(p)).map(PathBuf::from) }
}

/// Opens a file or folder the way a double-click in Explorer would. False if Windows refused.
pub fn open(path: &Path) -> bool {
    let file = wide_path(path);
    let verb = wide("open");
    unsafe {
        let _ = AllowSetForegroundWindow(ASFW_ANY);
        let r = ShellExecuteW(None, pcwstr(&verb), pcwstr(&file), None, None, SW_SHOWNORMAL);
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

/// The shell's file-type icon (not a thumbnail) at `px` x `px`, premultiplied RGBA.
pub fn file_icon(path: &Path, px: i32) -> Option<Image> {
    let p = wide_path(path);
    unsafe {
        let factory: IShellItemImageFactory = SHCreateItemFromParsingName(pcwstr(&p), None).ok()?;
        let bitmap = factory.GetImage(SIZE { cx: px, cy: px }, SIIGBF_ICONONLY).ok()?;
        let image = bitmap_to_image(bitmap);
        let _ = DeleteObject(bitmap.into());
        image
    }
}

/// Reads a 32-bit HBITMAP as premultiplied RGBA. Shell bitmaps are usually premultiplied, but
/// some icons come back straight or without alpha; both are handled.
unsafe fn bitmap_to_image(bitmap: HBITMAP) -> Option<Image> {
    let mut bm = BITMAP::default();
    if GetObjectW(bitmap.into(), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut _ as *mut _)) == 0 {
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
    let lines = GetDIBits(dc, bitmap, 0, h as u32, Some(bgra.as_mut_ptr() as *mut _), &mut info, DIB_RGB_COLORS);
    ReleaseDC(None, dc);
    if lines == 0 {
        return None;
    }
    let has_alpha = bgra.chunks(4).any(|p| p[3] != 0);
    let straight = has_alpha && bgra.chunks(4).any(|p| p[0] > p[3] || p[1] > p[3] || p[2] > p[3]);
    let mut rgba = Vec::with_capacity(bgra.len());
    for p in bgra.chunks(4) {
        let a = if has_alpha { p[3] } else { 255 };
        let pm = |c: u8| if straight { ((c as u32 * a as u32 + 127) / 255) as u8 } else { c };
        rgba.extend_from_slice(&[pm(p[2]), pm(p[1]), pm(p[0]), a]);
    }
    Some(Image { width: w as u32, height: h as u32, data: rgba })
}

// MARK: Desktop icon positions (best effort, silent on failure)

/// The desktop's own folder view, through the shell windows registry (Raymond Chen's recipe).
unsafe fn desktop_view() -> windows::core::Result<IFolderView> {
    let windows: IShellWindows = CoCreateInstance(&ShellWindows, None, CLSCTX_LOCAL_SERVER)?;
    let mut location = VARIANT::default();
    (*location.Anonymous.Anonymous).vt = VT_I4;
    (*location.Anonymous.Anonymous).Anonymous.lVal = CSIDL_DESKTOP as i32;
    let empty = VARIANT::default();
    let mut hwnd = 0i32;
    let dispatch = windows.FindWindowSW(&location, &empty, SWC_DESKTOP, &mut hwnd, SWFO_NEEDDISPATCH)?;
    let provider: IServiceProvider = dispatch.cast()?;
    let browser: IShellBrowser = provider.QueryService(&SID_STopLevelBrowser)?;
    let view = browser.QueryActiveShellView()?;
    view.cast()
}

/// Finds an item in the desktop view by its full path. The returned child PIDL must be freed.
unsafe fn find_item(view: &IFolderView, path: &Path) -> Option<*mut ITEMIDLIST> {
    let folder: IShellFolder = view.GetFolder().ok()?;
    let count = view.ItemCount(SVGIO_ALLVIEW).ok()?;
    for i in 0..count {
        let Ok(pidl) = view.Item(i) else { continue };
        let mut name = STRRET::default();
        let mut text = PWSTR::null();
        let matches = folder.GetDisplayNameOf(pidl, SHGDN_FORPARSING, &mut name).is_ok()
            && StrRetToStrW(&mut name, Some(pidl), &mut text).is_ok()
            && take_pwstr(text).map(|t| same_path(Path::new(&t), path)).unwrap_or(false);
        if matches {
            return Some(pidl);
        }
        CoTaskMemFree(Some(pidl as *const _));
    }
    None
}

/// Where Explorer shows this item's icon on the Desktop.
pub fn desktop_icon_position(path: &Path) -> Option<(f64, f64)> {
    unsafe {
        let view = desktop_view().ok()?;
        let pidl = find_item(&view, path)?;
        let p = view.GetItemPosition(pidl);
        CoTaskMemFree(Some(pidl as *const _));
        p.ok().map(|p| (p.x as f64, p.y as f64))
    }
}

/// Puts the icon back where it sat. With auto-arrange on, Explorer moves it again; that is fine.
pub fn set_desktop_icon_position(path: &Path, position: (f64, f64)) {
    unsafe {
        let Ok(view) = desktop_view() else { return };
        let Some(pidl) = find_item(&view, path) else { return };
        let pt = POINT { x: position.0.round() as i32, y: position.1.round() as i32 };
        let list = [pidl as *const ITEMIDLIST];
        let _ = view.SelectAndPositionItems(1, list.as_ptr(), Some(&pt), SVSI_POSITIONITEM.0 as u32);
        CoTaskMemFree(Some(pidl as *const _));
    }
}

// MARK: Start with Windows

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_VALUE: &str = "Desktop Fridge";

pub fn start_with_windows_command() -> Option<String> {
    let key = wide(RUN_KEY);
    let name = wide(RUN_VALUE);
    let mut buf = vec![0u16; 1024];
    let mut bytes = (buf.len() * 2) as u32;
    unsafe {
        let r = RegGetValueW(
            HKEY_CURRENT_USER,
            pcwstr(&key),
            pcwstr(&name),
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut _),
            Some(&mut bytes),
        );
        (r == ERROR_SUCCESS).then(|| from_wide(&buf))
    }
}

pub fn exe_command() -> Option<String> {
    std::env::current_exe().ok().map(|p| format!("\"{}\"", p.display()))
}

pub fn set_start_with_windows(on: bool) -> bool {
    let key = wide(RUN_KEY);
    let name = wide(RUN_VALUE);
    unsafe {
        if on {
            let Some(cmd) = exe_command() else { return false };
            let data = wide(&cmd);
            RegSetKeyValueW(
                HKEY_CURRENT_USER,
                pcwstr(&key),
                pcwstr(&name),
                REG_SZ.0,
                Some(data.as_ptr() as *const _),
                (data.len() * 2) as u32,
            ) == ERROR_SUCCESS
        } else {
            RegDeleteKeyValueW(HKEY_CURRENT_USER, pcwstr(&key), pcwstr(&name)) == ERROR_SUCCESS
        }
    }
}

/// If Start with Windows is on but the exe moved, point the entry at this copy.
pub fn refresh_start_with_windows() {
    if let (Some(current), Some(me)) = (start_with_windows_command(), exe_command()) {
        if !current.eq_ignore_ascii_case(&me) {
            set_start_with_windows(true);
        }
    }
}

// MARK: Theme and power

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

// MARK: Monitors

pub fn monitors() -> Vec<Monitor> {
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let list = &mut *(data.0 as *mut Vec<Monitor>);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
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

/// The monitor a screen point is on (nearest if none).
pub fn monitor_at(monitors: &[Monitor], p: (i32, i32)) -> Option<&Monitor> {
    monitors
        .iter()
        .find(|m| p.0 >= m.bounds.left && p.0 < m.bounds.right && p.1 >= m.bounds.top && p.1 < m.bounds.bottom)
        .or_else(|| {
            monitors.iter().min_by_key(|m| {
                let dx = (m.bounds.left - p.0).max(p.0 - m.bounds.right).max(0) as i64;
                let dy = (m.bounds.top - p.1).max(p.1 - m.bounds.bottom).max(0) as i64;
                dx * dx + dy * dy
            })
        })
}
