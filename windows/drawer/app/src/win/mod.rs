//! The Win32 shell: one layered tool window kept at the bottom of the z-order (above the Desktop
//! icons, below every normal window). The window is only as tall as the visible slice of the
//! drawer and is re-placed and redrawn every frame while the drawer moves.
//!
//! State lives in a thread-local `App`. It is only borrowed for short, non-reentrant work:
//! anything that runs a modal loop (the menu) runs with the borrow released, because the window
//! keeps getting messages meanwhile. Messages that arrive while the state is borrowed fall back
//! to default handling.

mod dnd;
mod present;
mod shell;
mod sound;
mod text;
mod ticker;
mod util;

use crate::compose::Compositor;
use crate::contents::{self, ItemView};
use crate::controller::{Controller, Press};
use crate::placement::{self, Monitor, Placement};
use crate::sprite::Sprite;
use drawer_art::scene::{EMPTY_HINT, EMPTY_HINT_CENTER_X};
use drawer_art::{Theme, DARK, LIGHT};
use drawer_core::layout::{hit_test, layout_items};
use drawer_core::DrawerStore;
use present::Surface;
use sound::Sounds;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;
use ticker::Ticker;
use util::{loword, lparam_point, pcwstr, wide};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    GetLastError, SetLastError, ERROR_ALREADY_EXISTS, HANDLE, HWND, LPARAM, LRESULT, POINT,
    WIN32_ERROR, WPARAM,
};
use windows::Win32::Media::MM_WOM_DONE;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Ole::{
    OleInitialize, OleUninitialize, RegisterDragDrop, RevokeDragDrop,
};
use windows::Win32::System::Power::{
    RegisterPowerSettingNotification, UnregisterPowerSettingNotification, HPOWERNOTIFY,
    POWERBROADCAST_SETTING,
};
use windows::Win32::System::RemoteDesktop::{
    WTSRegisterSessionNotification, WTSUnRegisterSessionNotification, NOTIFY_FOR_THIS_SESSION,
};
use windows::Win32::System::SystemServices::{
    GUID_CONSOLE_DISPLAY_STATE, GUID_POWER_SAVING_STATUS,
};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::HiDpi::{
    GetDpiForWindow, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetCapture, ReleaseCapture, SetCapture};
use windows::Win32::UI::Shell::{FOLDERID_Desktop, FOLDERID_Profile, FOLDERID_RoamingAppData};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
    DispatchMessageW, GetCursorPos, GetMessagePos, GetMessageW, GetWindow, KillTimer, LoadCursorW,
    MessageBoxW, PostMessageW, PostQuitMessage, RegisterClassExW, SetCursor, SetForegroundWindow,
    SetTimer, SetWindowPos, ShowWindow, TrackPopupMenu, TranslateMessage, CS_DBLCLKS,
    DEVICE_NOTIFY_WINDOW_HANDLE, GW_HWNDPREV, HTCLIENT, HWND_BOTTOM, IDC_ARROW, IDC_HAND, IDOK,
    MA_NOACTIVATE, MB_ICONERROR, MB_ICONWARNING, MB_OK, MB_OKCANCEL, MB_SETFOREGROUND, MF_GRAYED,
    MF_SEPARATOR, MF_STRING, MSG, PBT_APMPOWERSTATUSCHANGE, PBT_APMRESUMEAUTOMATIC,
    PBT_APMRESUMESUSPEND, PBT_APMSUSPEND, PBT_POWERSETTINGCHANGE, SWP_NOACTIVATE, SWP_NOMOVE,
    SWP_NOSIZE, SWP_NOZORDER, SW_SHOWNOACTIVATE, TPM_NONOTIFY, TPM_RETURNCMD, TPM_RIGHTBUTTON,
    WINDOWPOS, WM_APP, WM_CAPTURECHANGED, WM_DESTROY, WM_DISPLAYCHANGE, WM_DPICHANGED,
    WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_NULL,
    WM_POWERBROADCAST, WM_RBUTTONUP, WM_SETCURSOR, WM_SETTINGCHANGE, WM_TIMER,
    WM_WINDOWPOSCHANGING, WM_WTSSESSION_CHANGE, WNDCLASSEXW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_POPUP, WTS_SESSION_LOCK, WTS_SESSION_UNLOCK,
};

/// The frame clock's tick (posted by `ticker`).
const WM_TICK: u32 = WM_APP + 1;
const CLASS: PCWSTR = w!("DesktopDrawerWindow");
const TITLE: &str = "Desktop Drawer";
const CMD_PUT_BACK: usize = 1;
const CMD_SHOW: usize = 2;
const CMD_PUT_ALL_BACK: usize = 3;
const CMD_OPEN_FOLDER: usize = 4;
const CMD_MOVE_ALL: usize = 5;
const CMD_QUIT: usize = 6;
/// A file was dragged out and accepted: look at the folder again shortly, once the destination
/// has finished moving it.
const TIMER_RELOAD: usize = 1;
/// A drop was accepted; do the work now that the source's drag loop is over.
const WM_DROP_DONE: u32 = WM_APP + 2;

struct App {
    hwnd: HWND,
    ctl: Controller,
    comp: Compositor,
    surface: Surface,
    monitor: Monitor,
    dark: bool,
    /// Where the window is right now (for hit-testing and the cursor).
    placed: Placement,
    last_tick: Instant,
    /// Sleeping, locked or display off: no frames.
    paused: u32,
    power_notify: Vec<HPOWERNOTIFY>,
    store: DrawerStore,
    /// Item pictures and label text, by stored file name; made on demand, dropped when the theme
    /// or the DPI changes.
    icons: HashMap<String, Sprite>,
    labels: HashMap<String, Sprite>,
    hint: Option<Sprite>,
    /// The drawer was open enough to reach into at the last tick.
    was_interactive: bool,
    /// A press on an item that may turn into a drag: the item's name and where the mouse was.
    press: Option<(String, (f64, f64))>,
    /// The item being dragged out (drawn faint).
    lifted: Option<String>,
    dragging_out: bool,
    sounds: Sounds,
}

const PAUSE_LOCK: u32 = 1;
const PAUSE_SLEEP: u32 = 2;
const PAUSE_DISPLAY: u32 = 4;

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
    static TICKER: RefCell<Option<Ticker>> = const { RefCell::new(None) };
    static MAIN: Cell<HWND> = const { Cell::new(HWND(std::ptr::null_mut())) };
    /// Files from the last drop, waiting for `WM_DROP_DONE`.
    static PENDING_DROP: RefCell<Vec<PathBuf>> = const { RefCell::new(Vec::new()) };
}

/// Runs `f` on the app state, or does nothing if it is busy further up the stack.
fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|cell| match cell.try_borrow_mut() {
        Ok(mut guard) => guard.as_mut().map(f),
        Err(_) => None,
    })
}

fn with_ticker(f: impl FnOnce(&Ticker)) {
    TICKER.with(|t| {
        if let Some(t) = t.borrow().as_ref() {
            f(t)
        }
    });
}

fn theme(dark: bool) -> &'static Theme {
    if dark {
        &DARK
    } else {
        &LIGHT
    }
}

fn fatal(message: &str) {
    let text = wide(message);
    let title = wide(TITLE);
    unsafe {
        MessageBoxW(
            None,
            pcwstr(&text),
            pcwstr(&title),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}

impl App {
    /// Draws the drawer at its current position and shows it. Returns false if drawing failed.
    fn present(&mut self) -> bool {
        let position = self.ctl.physics.position();
        let p = placement::placement(&self.monitor, position, !self.store.items().is_empty());
        let max_h = placement::max_height_px(self.monitor.dpi_scale);
        let Some(buf) = self.surface.pixels(p.w, p.h, max_h) else {
            return false;
        };
        self.comp.compose(position, &p, buf);
        self.placed = p;
        self.surface.show(self.hwnd, (p.x, p.y), (p.w, p.h))
    }

    /// Frame clock on while anything moves, off at rest; slower on battery saver.
    fn sync_ticker(&self) {
        let running = self.paused == 0 && self.ctl.physics.needs_motion();
        let hz = if shell::battery_saver() { 30 } else { 60 };
        with_ticker(|t| t.set(running, hz));
    }

    fn set_pause(&mut self, bit: u32, on: bool) {
        if on {
            self.paused |= bit;
        } else {
            self.paused &= !bit;
        }
        let suspended = self.paused != 0;
        self.ctl.physics.set_suspended(suspended);
        if suspended {
            self.sounds.set_slide_speed(0.0);
        }
        if !suspended {
            self.last_tick = Instant::now();
        }
        self.sync_ticker();
    }

    /// The drawer's monitor changed size, position or DPI: re-pick it and redraw.
    fn refresh_monitor(&mut self) {
        let monitors = shell::monitors();
        let Some(m) = placement::primary(&monitors).copied() else {
            return;
        };
        let scale_changed = (m.dpi_scale - self.monitor.dpi_scale).abs() > 1e-6;
        self.monitor = m;
        self.ctl.set_monitor(m.dpi_scale, m.work.bottom);
        if scale_changed {
            self.rebuild_art();
        }
        self.present();
    }

    fn refresh_theme(&mut self) {
        let dark = shell::is_dark_mode();
        if dark != self.dark {
            self.dark = dark;
            self.rebuild_art();
            self.present();
        }
    }

    /// The theme or the scale changed: redraw the artwork, the labels and the contents.
    fn rebuild_art(&mut self) {
        self.comp = Compositor::new(theme(self.dark), self.monitor.dpi_scale);
        self.icons.clear();
        self.labels.clear();
        self.hint = None;
        self.rebuild_contents();
    }

    /// Pictures and text for everything that is in the drawer, then the contents layer.
    fn rebuild_contents(&mut self) {
        let scale = self.monitor.dpi_scale;
        let th = *theme(self.dark);
        let names: Vec<String> = self.store.items().iter().map(|i| i.name.clone()).collect();
        self.icons.retain(|k, _| names.contains(k));
        self.labels.retain(|k, _| names.contains(k));
        let icon_px = (52.0 * scale).round() as i32;
        for name in &names {
            if !self.icons.contains_key(name) {
                if let Some(pic) = shell::file_icon(&self.store.path_for(name), icon_px) {
                    self.icons
                        .insert(name.clone(), contents::icon_sprite(&pic, scale));
                }
            }
            if !self.labels.contains_key(name) {
                let (lw, lh) = (
                    (76.0 * scale).round() as usize,
                    (16.0 * scale).round() as usize,
                );
                if let Some(m) = text::render(name, lw, lh, 10.5 * scale, true) {
                    self.labels.insert(
                        name.clone(),
                        contents::label_sprite(&m.data, m.w, m.h, scale, th.label_alpha),
                    );
                }
            }
        }
        if names.is_empty() && self.hint.is_none() {
            let h = (13.0 * scale * 1.5).ceil() as usize;
            if let Some(m) = text::render(EMPTY_HINT, 0, h, 13.0 * scale, false) {
                self.hint = Some(contents::hint_sprite(&m.data, m.w, m.h, scale));
            }
        }
        let slots = layout_items(names.len());
        let views: Vec<ItemView> = slots
            .iter()
            .zip(&names)
            .map(|(slot, name)| ItemView {
                slot,
                icon: self.icons.get(name),
                label: self.labels.get(name),
                lifted: self.lifted.as_deref() == Some(name.as_str()),
            })
            .collect();
        let (w, h) = self.comp.size();
        let layer = contents::render(w, h, scale, &views, self.hint.as_ref(), EMPTY_HINT_CENTER_X);
        self.comp.set_contents(Some(layer.data));
    }

    /// The stored name of the item under a window-relative pixel, if any.
    fn item_at(&self, client: (i32, i32)) -> Option<String> {
        let scale = self.monitor.dpi_scale;
        let (x, y) = (
            client.0 as f64 / scale,
            (client.1 - self.placed.sag_px) as f64 / scale,
        );
        let slots = layout_items(self.store.items().len());
        hit_test(&slots, x, y).map(|i| self.store.items()[i].name.clone())
    }

    /// The folder changed under us: list it again and redraw.
    fn reload(&mut self) {
        self.store.reload();
        self.rebuild_contents();
        self.present();
        self.sync_ticker();
    }

    /// Sends one item back to where it came from.
    fn put_back(&mut self, name: &str) {
        if let Err(e) = self.store.put_back(name) {
            eprintln!("could not put {name} back: {e}");
        }
        self.reload();
    }

    /// Puts everything back (or on the Desktop). Returns how many could not be moved.
    fn move_all(&mut self, to_desktop: bool) -> usize {
        let (_, failed) = self.store.move_all(to_desktop);
        self.reload();
        failed
    }

    /// Moves dropped files into the drawer and shows them.
    fn stash(&mut self, files: &[PathBuf]) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let mut any = false;
        for f in files {
            match self.store.stash(f, None, now) {
                Ok(_) => any = true,
                Err(e) => eprintln!("could not put {} in the drawer: {e}", f.display()),
            }
        }
        if any {
            if let Some(knock) = self.ctl.physics.items_dropped() {
                self.sounds.knock(knock);
            }
            self.rebuild_contents();
        }
        self.present();
    }
}

pub fn run() {
    unsafe {
        // The manifest will ask for this too; calling it covers a build without the manifest.
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        SetLastError(WIN32_ERROR(0));
        let mutex = CreateMutexW(None, true, w!("Local\\WhimsyDesk.DesktopDrawer"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            fatal("Desktop Drawer is already running.");
            return;
        }
        if OleInitialize(None).is_err() {
            fatal("Desktop Drawer could not start (OLE is not available).");
            return;
        }
        match start() {
            Ok(()) => {
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            Err(message) => fatal(&message),
        }
        APP.with(|a| a.borrow_mut().take());
        TICKER.with(|t| t.borrow_mut().take());
        OleUninitialize();
        if let Ok(m) = mutex {
            let _ = windows::Win32::Foundation::CloseHandle(m);
        }
    }
}

unsafe fn start() -> Result<(), String> {
    let monitors = shell::monitors();
    let monitor =
        *placement::primary(&monitors).ok_or("Desktop Drawer could not find a screen.")?;
    let dark = shell::is_dark_mode();
    let first = placement::placement(&monitor, 0.0, false);

    let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
    let class = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: CS_DBLCLKS,
        lpfnWndProc: Some(wndproc),
        hInstance: instance.into(),
        lpszClassName: CLASS,
        ..Default::default()
    };
    if RegisterClassExW(&class) == 0 {
        return Err("Desktop Drawer could not register its window.".into());
    }
    let hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        CLASS,
        w!("Desktop Drawer"),
        WS_POPUP,
        first.x,
        first.y,
        first.w,
        first.h,
        None,
        None,
        Some(instance.into()),
        None,
    )
    .map_err(|e| format!("Desktop Drawer could not create its window.\n\n{e}"))?;
    MAIN.with(|m| m.set(hwnd));

    // Windows knows best which monitor the window landed on.
    let mut monitor = monitor;
    let dpi = GetDpiForWindow(hwnd);
    if dpi > 0 {
        monitor.dpi_scale = dpi as f64 / 96.0;
    }

    let comp = Compositor::new(theme(dark), monitor.dpi_scale);
    let store =
        open_store().map_err(|e| format!("Desktop Drawer could not open its folder.\n\n{e}"))?;
    TICKER.with(|t| *t.borrow_mut() = Some(Ticker::start(hwnd, WM_TICK)));

    let _ = WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION);
    let mut notify = Vec::new();
    for guid in [GUID_CONSOLE_DISPLAY_STATE, GUID_POWER_SAVING_STATUS] {
        if let Ok(h) =
            RegisterPowerSettingNotification(HANDLE(hwnd.0), &guid, DEVICE_NOTIFY_WINDOW_HANDLE)
        {
            notify.push(h);
        }
    }

    let mut app = App {
        hwnd,
        ctl: Controller::new(monitor.dpi_scale, monitor.work.bottom),
        comp,
        surface: Surface::new(),
        monitor,
        dark,
        placed: first,
        last_tick: Instant::now(),
        paused: 0,
        power_notify: notify,
        store,
        icons: HashMap::new(),
        labels: HashMap::new(),
        hint: None,
        was_interactive: false,
        press: None,
        lifted: None,
        dragging_out: false,
        sounds: Sounds::new(hwnd),
    };
    app.rebuild_contents();
    app.ctl
        .physics
        .set_battery_saver(shell::battery_saver() || shell::reduce_motion());
    if !app.present() {
        return Err("Desktop Drawer could not draw its window.".into());
    }
    APP.with(|a| *a.borrow_mut() = Some(app));

    let _ = RegisterDragDrop(hwnd, &dnd::make_target(hwnd));
    let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    let _ = SetWindowPos(
        hwnd,
        Some(HWND_BOTTOM),
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );
    Ok(())
}

// MARK: Window procedure

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        // Stay at the bottom of the z-order whatever asks us to come forward.
        WM_WINDOWPOSCHANGING => {
            let wp = &mut *(lparam.0 as *mut WINDOWPOS);
            if wp.flags.0 & SWP_NOZORDER.0 == 0 {
                match bottom_slot(hwnd) {
                    Some(after) => wp.hwndInsertAfter = after,
                    None => wp.flags |= SWP_NOZORDER, // already there
                }
            }
            return LRESULT(0);
        }
        WM_MOUSEACTIVATE => return LRESULT(MA_NOACTIVATE as isize),
        WM_SETCURSOR => {
            if (lparam.0 & 0xFFFF) as u32 == HTCLIENT {
                set_cursor();
                return LRESULT(1);
            }
        }
        WM_TICK => {
            with_ticker(|t| t.handled());
            on_tick();
            return LRESULT(0);
        }
        WM_LBUTTONDOWN | WM_LBUTTONDBLCLK => {
            mouse_down(if msg == WM_LBUTTONDBLCLK { 2 } else { 1 }, lparam);
            return LRESULT(0);
        }
        WM_MOUSEMOVE => {
            let screen = screen_point();
            with_app(|a| {
                a.ctl.mouse_move(screen.1);
                a.sync_ticker();
            });
            maybe_begin_drag(screen);
            return LRESULT(0);
        }
        WM_LBUTTONUP => {
            with_app(|a| {
                a.press = None;
                a.ctl.mouse_up();
                a.sync_ticker();
            });
            if GetCapture() == hwnd {
                let _ = ReleaseCapture();
            }
            return LRESULT(0);
        }
        WM_RBUTTONUP => {
            context_menu(lparam);
            return LRESULT(0);
        }
        WM_CAPTURECHANGED => {
            if lparam.0 != hwnd.0 as isize {
                with_app(|a| {
                    a.ctl.cancel_grab();
                    a.sync_ticker();
                });
            }
            return LRESULT(0);
        }
        MM_WOM_DONE => {
            with_app(|a| a.sounds.on_done(wparam.0 as isize, lparam.0));
            return LRESULT(0);
        }
        WM_TIMER => {
            if wparam.0 == TIMER_RELOAD {
                let _ = KillTimer(Some(hwnd), TIMER_RELOAD);
                with_app(|a| a.reload());
            }
            return LRESULT(0);
        }
        WM_DROP_DONE => {
            on_drop_done();
            return LRESULT(0);
        }
        WM_DPICHANGED => {
            let _ = loword(wparam);
            with_app(|a| a.refresh_monitor());
            return LRESULT(0);
        }
        WM_DISPLAYCHANGE => {
            with_app(|a| a.refresh_monitor());
        }
        WM_SETTINGCHANGE => {
            with_app(|a| {
                a.refresh_theme();
                a.ctl
                    .physics
                    .set_battery_saver(shell::battery_saver() || shell::reduce_motion());
            });
        }
        WM_WTSSESSION_CHANGE => match wparam.0 as u32 {
            WTS_SESSION_LOCK => {
                with_app(|a| a.set_pause(PAUSE_LOCK, true));
            }
            WTS_SESSION_UNLOCK => {
                with_app(|a| a.set_pause(PAUSE_LOCK, false));
            }
            _ => {}
        },
        WM_POWERBROADCAST => {
            on_power(wparam.0 as u32, lparam);
            return LRESULT(1);
        }
        WM_DESTROY => {
            on_destroy(hwnd);
            PostQuitMessage(0);
            return LRESULT(0);
        }
        _ => {}
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

/// Where to sit in the z-order: right above the window holding the Desktop icons (normally the
/// same as HWND_BOTTOM; differs when Explorer has moved the icons into a WorkerW, which would
/// otherwise cover us with the wallpaper). None when we are already there.
unsafe fn bottom_slot(hwnd: HWND) -> Option<HWND> {
    let Some(host) = shell::desktop_icons_host() else {
        return Some(HWND_BOTTOM);
    };
    match GetWindow(host, GW_HWNDPREV) {
        Ok(prev) if prev == hwnd => None,
        Ok(prev) if !prev.is_invalid() => Some(prev),
        _ => Some(HWND_BOTTOM),
    }
}

// MARK: Input

/// The mouse position of the message being handled, in screen pixels.
unsafe fn screen_point() -> (f64, f64) {
    let pos = GetMessagePos();
    (
        (pos & 0xFFFF) as u16 as i16 as f64,
        ((pos >> 16) & 0xFFFF) as u16 as i16 as f64,
    )
}

unsafe fn mouse_down(clicks: u32, lparam: LPARAM) {
    let client = lparam_point(lparam);
    let screen = screen_point();
    let hwnd = MAIN.with(|m| m.get());
    let press = with_app(|a| {
        let on_face = a.ctl.face_hit(client, a.placed.sag_px);
        if !on_face && a.ctl.physics.is_interactive() {
            // Reaching into the drawer: an item.
            if let Some(name) = a.item_at(client) {
                if clicks >= 2 {
                    a.press = None;
                    a.put_back(&name);
                } else {
                    a.press = Some((name, screen));
                }
                return Press::Grabbed; // capture the mouse until it is released
            }
        }
        let press = a
            .ctl
            .mouse_down(on_face, clicks, screen.1, a.placed.y as f64);
        a.sync_ticker();
        press
    });
    if press == Some(Press::Grabbed) {
        SetCapture(hwnd);
    }
}

/// The mouse moved with an item pressed: past a few points it becomes a drag out of the drawer.
unsafe fn maybe_begin_drag(screen: (f64, f64)) {
    let name = with_app(|a| {
        let (name, start) = a.press.clone()?;
        let far = 4.0 * a.monitor.dpi_scale;
        if (screen.0 - start.0).hypot(screen.1 - start.1) > far {
            a.press = None;
            Some(name)
        } else {
            None
        }
    })
    .flatten();
    if let Some(name) = name {
        begin_item_drag(&name);
    }
}

/// Drags one item out with the shell's own drag and drop. Runs with the state released: the
/// drag loop dispatches messages.
unsafe fn begin_item_drag(name: &str) {
    let hwnd = MAIN.with(|m| m.get());
    let info = with_app(|a| {
        a.dragging_out = true;
        a.lifted = Some(name.to_string());
        a.ctl.physics.set_drag_in_progress(true);
        a.rebuild_contents();
        a.present();
        (a.store.path_for(name), a.icons.get(name).cloned())
    });
    let Some((path, icon)) = info else { return };
    if GetCapture() == hwnd {
        let _ = ReleaseCapture();
    }
    let effect = dnd::drag_out(&path, icon.as_ref());
    with_app(|a| {
        a.dragging_out = false;
        a.lifted = None;
        a.ctl.physics.set_drag_in_progress(false);
        a.reload();
    });
    if dnd::accepted(effect) {
        // The destination may still be moving the file.
        SetTimer(Some(hwnd), TIMER_RELOAD, 600, None);
    }
}

/// The hand over the front panel, the arrow elsewhere.
unsafe fn set_cursor() {
    let mut p = POINT::default();
    let _ = GetCursorPos(&mut p);
    let over_face = with_app(|a| {
        let client = (p.x - a.placed.x, p.y - a.placed.y);
        a.ctl.is_grabbed() || a.ctl.face_hit(client, a.placed.sag_px)
    })
    .unwrap_or(false);
    if let Ok(c) = LoadCursorW(None, if over_face { IDC_HAND } else { IDC_ARROW }) {
        SetCursor(Some(c));
    }
}

/// The right-click menu. Runs with the state released: the menu's own message loop keeps feeding
/// the window messages.
unsafe fn context_menu(lparam: LPARAM) {
    let hwnd = MAIN.with(|m| m.get());
    let mut at = POINT::default();
    let _ = GetCursorPos(&mut at);
    let client = lparam_point(lparam);
    let (item, count) = with_app(|a| {
        let item = if a.ctl.physics.is_interactive() {
            a.item_at(client)
        } else {
            None
        };
        (item, a.store.items().len())
    })
    .unwrap_or((None, 0));
    let Ok(menu) = CreatePopupMenu() else { return };
    let add = |id: usize, flags, label: &str| {
        let text = wide(label);
        let _ = AppendMenuW(menu, flags, id, pcwstr(&text));
    };
    if item.is_some() {
        add(CMD_PUT_BACK, MF_STRING, "Put Back on Desktop");
        add(CMD_SHOW, MF_STRING, "Show in Explorer");
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
    }
    let some = if count == 0 {
        MF_STRING | MF_GRAYED
    } else {
        MF_STRING
    };
    add(CMD_PUT_ALL_BACK, some, "Put Everything Back");
    add(CMD_OPEN_FOLDER, MF_STRING, "Open Drawer Folder");
    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
    add(CMD_MOVE_ALL, some, "Move Everything to Desktop");
    add(CMD_QUIT, MF_STRING, "Quit Desktop Drawer");
    // Needed so the menu closes when the user clicks elsewhere (TrackPopupMenu remarks).
    let _ = SetForegroundWindow(hwnd);
    let chosen = TrackPopupMenu(
        menu,
        TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
        at.x,
        at.y,
        None,
        hwnd,
        None,
    )
    .0;
    let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(menu);
    match chosen as usize {
        CMD_PUT_BACK => {
            if let Some(name) = item {
                with_app(|a| a.put_back(&name));
            }
        }
        CMD_SHOW => {
            if let Some(name) = item {
                if let Some(path) = with_app(|a| a.store.path_for(&name)) {
                    shell::show_in_explorer(&path);
                }
            }
        }
        CMD_PUT_ALL_BACK => {
            let failed = with_app(|a| a.move_all(false)).unwrap_or(0);
            if failed > 0 {
                tell_failed(failed);
            }
        }
        CMD_OPEN_FOLDER => {
            if let Some(folder) = with_app(|a| a.store.folder().to_path_buf()) {
                shell::open(&folder);
            }
        }
        CMD_MOVE_ALL => {
            let message = format!(
                "Move everything to your Desktop?\n\n{count} {} will be moved out of the drawer.",
                if count == 1 { "item" } else { "items" }
            );
            if confirm(&message) {
                let failed = with_app(|a| a.move_all(true)).unwrap_or(0);
                if failed > 0 {
                    tell_failed(failed);
                }
            }
        }
        CMD_QUIT => {
            let _ = DestroyWindow(hwnd);
        }
        _ => {}
    }
}

fn confirm(message: &str) -> bool {
    let text = wide(message);
    let title = wide(TITLE);
    unsafe {
        MessageBoxW(
            None,
            pcwstr(&text),
            pcwstr(&title),
            MB_OKCANCEL | MB_ICONWARNING | MB_SETFOREGROUND,
        ) == IDOK
    }
}

fn tell_failed(count: usize) {
    let message = format!(
        "{count} {} could not be moved. {} still in the drawer.",
        if count == 1 { "file" } else { "files" },
        if count == 1 { "It is" } else { "They are" }
    );
    let text = wide(&message);
    let title = wide(TITLE);
    unsafe {
        MessageBoxW(
            None,
            pcwstr(&text),
            pcwstr(&title),
            MB_OK | MB_ICONWARNING | MB_SETFOREGROUND,
        );
    }
}

// MARK: Frames and system events

fn on_tick() {
    with_app(|a| {
        let now = Instant::now();
        let dt = now.duration_since(a.last_tick).as_secs_f64();
        a.last_tick = now;
        for knock in a.ctl.physics.advance(dt) {
            a.sounds.knock(knock);
        }
        a.sounds.set_slide_speed(a.ctl.physics.slide_speed());
        // Reaching into the drawer: pick up changes made in Explorer since it was last open.
        let interactive = a.ctl.physics.is_interactive();
        if interactive && !a.was_interactive {
            a.store.reload();
            a.rebuild_contents();
        }
        a.was_interactive = interactive;
        a.present();
        a.sync_ticker();
    });
}

unsafe fn on_power(event: u32, lparam: LPARAM) {
    match event {
        PBT_APMSUSPEND => {
            with_app(|a| a.set_pause(PAUSE_SLEEP, true));
        }
        PBT_APMRESUMESUSPEND | PBT_APMRESUMEAUTOMATIC => {
            with_app(|a| a.set_pause(PAUSE_SLEEP, false));
        }
        PBT_APMPOWERSTATUSCHANGE => {
            with_app(|a| {
                a.ctl
                    .physics
                    .set_battery_saver(shell::battery_saver() || shell::reduce_motion())
            });
        }
        PBT_POWERSETTINGCHANGE if lparam.0 != 0 => {
            let s = &*(lparam.0 as *const POWERBROADCAST_SETTING);
            let value = if s.DataLength >= 4 {
                std::ptr::read_unaligned(s.Data.as_ptr() as *const u32)
            } else {
                s.Data[0] as u32
            };
            if s.PowerSetting == GUID_CONSOLE_DISPLAY_STATE {
                // 0 off, 1 on, 2 dimmed.
                with_app(|a| a.set_pause(PAUSE_DISPLAY, value == 0));
            } else if s.PowerSetting == GUID_POWER_SAVING_STATUS {
                with_app(|a| {
                    a.ctl
                        .physics
                        .set_battery_saver(value != 0 || shell::reduce_motion())
                });
            }
        }
        _ => {}
    }
}

unsafe fn on_destroy(hwnd: HWND) {
    with_ticker(|t| t.stop_thread());
    let _ = RevokeDragDrop(hwnd);
    let _ = WTSUnRegisterSessionNotification(hwnd);
    with_app(|a| {
        a.sounds.stop_all();
        for h in a.power_notify.drain(..) {
            let _ = UnregisterPowerSettingNotification(h);
        }
    });
}

// MARK: Folders

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

fn desktop_dir() -> PathBuf {
    shell::known_folder(&FOLDERID_Desktop)
        .or_else(|| env_path("USERPROFILE").map(|p| p.join("Desktop")))
        .unwrap_or_else(|| PathBuf::from("C:\\"))
}

/// `%USERPROFILE%\Desktop Drawer`; when OneDrive holds the Desktop, beside it inside OneDrive, so
/// moving a file in stays inside OneDrive. `DRAWER_ROOT` overrides it (for testing).
fn drawer_folder() -> PathBuf {
    if let Some(p) = env_path("DRAWER_ROOT") {
        return p;
    }
    let home = shell::known_folder(&FOLDERID_Profile)
        .or_else(|| env_path("USERPROFILE"))
        .unwrap_or_else(|| PathBuf::from("C:\\"));
    let desktop = desktop_dir();
    match desktop.parent() {
        Some(parent) if !drawer_core::fsutil::same_path(parent, &home) => {
            parent.join("Desktop Drawer")
        }
        _ => home.join("Desktop Drawer"),
    }
}

fn index_path() -> PathBuf {
    let base = shell::known_folder(&FOLDERID_RoamingAppData)
        .or_else(|| env_path("APPDATA"))
        .unwrap_or_default();
    base.join("WhimsyDesk")
        .join("Desktop Drawer")
        .join("index.json")
}

fn open_store() -> Result<DrawerStore, String> {
    let folder = drawer_folder();
    DrawerStore::open(&folder, desktop_dir(), index_path())
        .map_err(|e| format!("{}\n\n{e}", folder.display()))
}

// MARK: Drag and drop

/// A file drag is over the drawer. Hovering pulls a closed drawer open; files are welcome once
/// it is open enough to reach into.
pub fn on_drag_over(has_files: bool) -> bool {
    if !has_files {
        return false;
    }
    with_app(|a| {
        if a.dragging_out {
            return false; // never drop an item back onto the drawer it is leaving
        }
        a.ctl.physics.set_drag_in_progress(true);
        a.ctl.physics.open_for_drag();
        a.sync_ticker();
        a.ctl.physics.is_interactive()
    })
    .unwrap_or(false)
}

pub fn on_drag_leave() {
    with_app(|a| {
        if a.dragging_out {
            return; // our own drag keeps the drawer from closing until it ends
        }
        a.ctl.physics.set_drag_in_progress(false);
        a.sync_ticker();
    });
}

/// The drop itself: remember the files and handle them once the source's drag loop is over.
pub fn on_drop(files: Vec<PathBuf>) {
    on_drag_leave();
    let interactive =
        with_app(|a| a.ctl.physics.is_interactive() && !a.dragging_out).unwrap_or(false);
    if files.is_empty() || !interactive {
        return;
    }
    PENDING_DROP.with(|p| *p.borrow_mut() = files);
    let hwnd = MAIN.with(|m| m.get());
    unsafe {
        let _ = PostMessageW(Some(hwnd), WM_DROP_DONE, WPARAM(0), LPARAM(0));
    }
}

fn on_drop_done() {
    let files = PENDING_DROP.with(|p| std::mem::take(&mut *p.borrow_mut()));
    with_app(|a| a.stash(&files));
}
