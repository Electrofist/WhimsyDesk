//! The Win32 shell: one layered tool window kept at the bottom of the z-order (above the
//! Desktop icons, below every normal window). It feeds mouse, drag and drop, timer and system
//! events to the [`Model`] and carries out the [`Effect`]s it returns.
//!
//! State lives in a thread-local `App`. It is only borrowed for short, non-reentrant work: anything
//! that runs a modal loop or calls into Explorer (menus, dialogs, drag and drop, opening files,
//! Desktop icon positions, the note editor) runs with the borrow released, because the window
//! keeps getting messages meanwhile. Messages that arrive while the state is borrowed fall back
//! to default handling.

mod cursor;
mod dialog;
mod log;
mod dnd;
mod editor;
mod popup;
mod present;
mod shell;
mod sound;
mod ticker;
mod util;

use crate::menu::Command;
use crate::model::{
    Allowed, DragInfo, DropAction, DropEffect, Effect, EditorRequest, Model, Mouse, PauseReason, Task, WindowGeom,
};
use crate::placement::{self, Monitor};
use crate::settings::{Origin, Settings, MAX_SCALE};
use crate::wav;
use cursor::Cursors;
use fridge_art::{Assets, Image, Renderer, NOTE_FONT_SIZE, NOTE_TEXT_RECT};
use fridge_core::{DoorNotesStore, FridgeStore};
use present::Surface;
use sound::Sounds;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use ticker::Ticker;
use util::{lparam_point, loword};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{GetLastError, SetLastError, ERROR_ALREADY_EXISTS, HANDLE, WIN32_ERROR, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::AddFontMemResourceEx;
use windows::Win32::Media::MM_WOM_DONE;
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Ole::{OleInitialize, OleUninitialize, RegisterDragDrop, RevokeDragDrop};
use windows::Win32::System::Power::{RegisterPowerSettingNotification, UnregisterPowerSettingNotification, HPOWERNOTIFY, POWERBROADCAST_SETTING};
use windows::Win32::System::RemoteDesktop::{WTSRegisterSessionNotification, WTSUnRegisterSessionNotification, NOTIFY_FOR_THIS_SESSION};
use windows::Win32::System::SystemServices::{GUID_CONSOLE_DISPLAY_STATE, GUID_POWER_SAVING_STATUS, MK_CONTROL};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetCapture, GetKeyState, ReleaseCapture, SetCapture, VK_MENU};
use windows::Win32::UI::Shell::{FOLDERID_Desktop, FOLDERID_Profile, FOLDERID_RoamingAppData};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetCursorPos, GetWindow, GW_HWNDPREV, GetMessagePos, GetMessageW, KillTimer,
    PostMessageW, PostQuitMessage, RegisterClassExW, SetTimer, SetWindowPos, ShowWindow, TranslateMessage, CS_DBLCLKS,
    DEVICE_NOTIFY_WINDOW_HANDLE, HTCLIENT, HWND_BOTTOM, MA_NOACTIVATE, MB_OK, MSG, PBT_APMPOWERSTATUSCHANGE,
    PBT_APMRESUMEAUTOMATIC, PBT_APMRESUMESUSPEND, PBT_APMSUSPEND, PBT_POWERSETTINGCHANGE, SWP_NOACTIVATE, SWP_NOMOVE,
    SWP_NOSIZE, SWP_NOZORDER, SW_SHOWNOACTIVATE, WINDOWPOS, WM_APP, WM_CAPTURECHANGED, WM_DESTROY, WM_DISPLAYCHANGE,
    WM_DPICHANGED, WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_POWERBROADCAST,
    WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SETCURSOR, WM_SETTINGCHANGE, WM_TIMER, WM_WINDOWPOSCHANGING, WM_WTSSESSION_CHANGE,
    WNDCLASSEXW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP, WTS_SESSION_LOCK, WTS_SESSION_UNLOCK,
};

/// The frame clock's tick (posted by `ticker`).
const WM_TICK: u32 = WM_APP + 1;
/// A drop was accepted; do the work now that the source's drag loop is over.
const WM_DROP_DONE: u32 = WM_APP + 2;
/// WM_DPICHANGED came while the state was busy: look at the DPI again.
const WM_DPI_RECHECK: u32 = WM_APP + 4;
const CLASS: PCWSTR = w!("DesktopFridgeWindow");
const FIRST_TASK_TIMER: usize = 100;

struct App {
    hwnd: HWND,
    model: Model,
    renderer: Renderer,
    surface: Surface,
    sounds: Sounds,
    cursors: Cursors,
    settings: Settings,
    settings_path: PathBuf,
    last_tick: Instant,
    tasks: HashMap<usize, Task>,
    next_timer: usize,
    icons: HashMap<PathBuf, Arc<Image>>,
    pending_drop: Option<DropAction>,
    dragging_out: bool,
    note_face: String,
    power_notify: Vec<HPOWERNOTIFY>,
    present_failed: bool,
    position_retries: HashMap<PathBuf, u32>,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
    static TICKER: RefCell<Option<Ticker>> = const { RefCell::new(None) };
    static MAIN: Cell<HWND> = const { Cell::new(HWND(std::ptr::null_mut())) };
}

/// Runs `f` on the app state, or does nothing if it is busy further up the stack.
fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|cell| match cell.try_borrow_mut() {
        Ok(mut guard) => guard.as_mut().map(f),
        Err(_) => None,
    })
}

fn with_ticker_value<R>(f: impl FnOnce(&Ticker) -> R) -> Option<R> {
    TICKER.with(|t| t.borrow().as_ref().map(f))
}

fn with_ticker(f: impl FnOnce(&Ticker)) {
    TICKER.with(|t| {
        if let Some(t) = t.borrow().as_ref() {
            f(t)
        }
    });
}

fn main_hwnd() -> HWND {
    MAIN.with(|m| m.get())
}

fn beep() {
    unsafe {
        let _ = MessageBeep(MB_OK);
    }
}

fn wall_now() -> f64 {
    fridge_core::iso::now()
}

pub fn run() {
    log::start();
    log::install_panic_hook();
    log::install_crash_filter();
    unsafe {
        // The manifest asks for this too; calling it covers a build without the manifest.
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        SetLastError(WIN32_ERROR(0));
        let mutex = CreateMutexW(None, true, w!("Local\\WhimsyDesk.DesktopFridge"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            log::line("another copy is already running; this one exits");
            dialog::fatal("Desktop Fridge is already running.\n\nIf you cannot see it, quit it from Task Manager (Details tab, DesktopFridge.exe) and open it again.");
            return;
        }
        if OleInitialize(None).is_err() {
            dialog::fatal("Desktop Fridge could not start (OLE is not available).");
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
            Err(message) => {
                log::line(&format!("start failed: {message}"));
                dialog::fatal(&message)
            }
        }
        // Drop the state (drop target, sounds, cursors) before COM goes away.
        APP.with(|a| a.borrow_mut().take());
        TICKER.with(|t| t.borrow_mut().take());
        OleUninitialize();
        if let Ok(m) = mutex {
            let _ = windows::Win32::Foundation::CloseHandle(m);
        }
    }
}

// MARK: Start-up

/// `assets` beside the exe; while developing, the repo's `assets` folder.
fn assets_dir() -> PathBuf {
    let exe = std::env::current_exe().unwrap_or_default();
    let dir = exe.parent().map(Path::to_path_buf).unwrap_or_default();
    let candidates = [dir.join("assets"), dir.join("../../assets"), dir.join("../../../assets")];
    candidates.iter().find(|p| p.join("door").is_dir()).cloned().unwrap_or_else(|| dir.join("assets"))
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn fridge_root() -> PathBuf {
    if let Some(p) = env_path("FRIDGE_ROOT") {
        return p;
    }
    let home = shell::known_folder(&FOLDERID_Profile).or_else(|| env_path("USERPROFILE")).unwrap_or_else(|| PathBuf::from("C:\\"));
    let classic = home.join("Fridge");
    // When OneDrive syncs the Desktop, keep the fridge beside it inside OneDrive. Moving a file in
    // then stays inside OneDrive; from a OneDrive Desktop to a plain folder, OneDrive treats the
    // move as a delete and asks about removing the file everywhere.
    let desktop = desktop_dir();
    let Some(parent) = desktop.parent().map(Path::to_path_buf) else { return classic };
    if fridge_core::store::same_path(&parent, &home) {
        return classic;
    }
    let beside = parent.join("Fridge");
    if classic.join(FridgeStore::INDEX_NAME).exists() && !beside.exists() {
        match fridge_core::store::move_item(&classic, &beside) {
            Ok(()) => log::line(&format!("moved the fridge folder next to the Desktop: {}", beside.display())),
            Err(e) => {
                log::line(&format!("could not move the fridge folder into OneDrive ({e}); keeping {}", classic.display()));
                return classic;
            }
        }
    }
    beside
}

fn desktop_dir() -> PathBuf {
    shell::known_folder(&FOLDERID_Desktop)
        .or_else(|| env_path("USERPROFILE").map(|p| p.join("Desktop")))
        .unwrap_or_else(|| PathBuf::from("C:\\"))
}

fn settings_path() -> PathBuf {
    let base = shell::known_folder(&FOLDERID_RoamingAppData).or_else(|| env_path("APPDATA")).unwrap_or_default();
    base.join("WhimsyDesk").join("Desktop Fridge").join("settings.json")
}

/// The saved spot if the fridge would be visible there, else the default spot on the main monitor.
fn initial_geom(settings: &Settings, monitors: &[Monitor]) -> WindowGeom {
    let user = settings.fridge_scale;
    if let Some(o) = settings.window_origin {
        let origin = (o.x, o.y);
        let feet = placement::feet_on_screen(origin, user);
        let dpi = shell::monitor_at(monitors, (feet.0 as i32, feet.1 as i32)).map(|m| m.dpi_scale).unwrap_or(1.0);
        if placement::body_visible(origin, dpi * user, monitors) {
            return WindowGeom { origin, dpi_scale: dpi, user_scale: user };
        }
    }
    match placement::primary(monitors) {
        Some(m) => WindowGeom { origin: placement::default_origin(m, user), dpi_scale: m.dpi_scale, user_scale: user },
        None => WindowGeom { origin: (100, 100), dpi_scale: 1.0, user_scale: user },
    }
}

/// Makes the bundled handwriting font usable by the note editor (private to this process).
fn register_note_font(assets: &Assets) -> String {
    let mut count = 0u32;
    let handle = unsafe {
        AddFontMemResourceEx(assets.note_font.as_ptr() as *const _, assets.note_font.len() as u32, None, &mut count as *mut u32)
    };
    if !handle.is_invalid() && count > 0 {
        "Caveat".into()
    } else {
        "Ink Free".into()
    }
}

fn read_wav(dir: &Path, name: &str) -> Option<wav::Wav> {
    std::fs::read(dir.join("sounds").join(name)).ok().and_then(|b| wav::parse(&b))
}

/// `FRIDGE_DEBUG_ANGLE="fridge,freezer"` in degrees pins doors open (development aid).
fn debug_angles() -> Option<[f64; 2]> {
    let v = std::env::var("FRIDGE_DEBUG_ANGLE").ok()?;
    let mut parts = v.split(',').map(|p| p.trim().parse::<f64>().unwrap_or(0.0));
    Some([parts.next().unwrap_or(0.0), parts.next().unwrap_or(0.0)])
}

/// Size the shell icons are fetched at: big enough for the largest fridge on this monitor.
fn icon_px(dpi_scale: f64) -> i32 {
    ((60.0 * 1.14 * MAX_SCALE * dpi_scale).ceil() as i32).clamp(48, 256)
}

unsafe fn start() -> Result<(), String> {
    let dir = assets_dir();
    log::line(&format!("assets: {}", dir.display()));
    let assets = Assets::load(&dir).map_err(|e| {
        format!("Desktop Fridge could not find its pictures and sounds.\n\nKeep the \"assets\" folder next to DesktopFridge.exe.\n\n{e}")
    })?;
    let assets = Arc::new(assets);

    let root = fridge_root();
    log::line(&format!("fridge folder: {} (desktop {})", root.display(), desktop_dir().display()));
    let store = FridgeStore::open(&root, desktop_dir())
        .map_err(|e| format!("Desktop Fridge could not open its folder:\n{}\n\n{e}", root.display()))?;
    let notes = DoorNotesStore::open(&root);
    let settings_path = settings_path();
    let settings = Settings::load(&settings_path);
    let time_scale = settings.effective_time_scale(std::env::var("FRIDGE_TIME_SCALE").ok().as_deref());

    let monitors = shell::monitors();
    let mut geom = initial_geom(&settings, &monitors);
    for m in &monitors {
        log::line(&format!("monitor: bounds {:?} work {:?} scale {}", m.bounds, m.work, m.dpi_scale));
    }
    log::line(&format!("window: origin {:?} dpi {} user {}", geom.origin, geom.dpi_scale, geom.user_scale));

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
        return Err("Desktop Fridge could not register its window.".into());
    }
    editor::register_class();

    let (w, h) = geom.size();
    let hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        CLASS,
        w!("Desktop Fridge"),
        WS_POPUP,
        geom.origin.0,
        geom.origin.1,
        w,
        h,
        None,
        None,
        Some(instance.into()),
        None,
    )
    .map_err(|e| format!("Desktop Fridge could not create its window.\n\n{e}"))?;
    log::line("window created");
    MAIN.with(|m| m.set(hwnd));

    // Windows knows best which monitor the window landed on.
    let dpi = GetDpiForWindow(hwnd);
    if dpi > 0 {
        let real = dpi as f64 / 96.0;
        if (real - geom.dpi_scale).abs() > 1e-6 {
            let old = geom.scale();
            geom.dpi_scale = real;
            geom.origin = placement::rescale_origin(geom.origin, old, geom.scale());
        }
    }

    let note_face = register_note_font(&assets);
    log::line("font ready");
    let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(7);
    let mut model = Model::new(store, notes, geom, time_scale, seed);
    log::line("model ready");
    model.reduce_motion = shell::reduce_motion();
    model.low_power = shell::battery_saver();
    if let Some(angles) = debug_angles() {
        for (i, a) in angles.iter().enumerate() {
            if *a > 0.0 {
                model.debug_pin(i, a.to_radians());
            }
        }
    }
    let renderer = Renderer::new(assets.clone(), geom.scale() as f32, shell::is_dark_mode());
    log::line("renderer ready");
    let sounds = Sounds::new(hwnd, read_wav(&dir, "open_click.wav"), read_wav(&dir, "seal_click.wav"));
    log::line("sounds ready");
    let cursors = Cursors::new(geom.dpi_scale);
    log::line("cursors ready");
    TICKER.with(|t| *t.borrow_mut() = Some(Ticker::start(hwnd, WM_TICK)));
    log::line("frame clock ready");

    APP.with(|a| {
        *a.borrow_mut() = Some(App {
            hwnd,
            model,
            renderer,
            surface: Surface::new(),
            sounds,
            cursors,
            settings,
            settings_path,
            last_tick: Instant::now(),
            tasks: HashMap::new(),
            next_timer: FIRST_TASK_TIMER,
            icons: HashMap::new(),
            pending_drop: None,
            dragging_out: false,
            note_face,
            power_notify: Vec::new(),
            present_failed: false,
            position_retries: HashMap::new(),
        })
    });

    // Shell icons for what is already inside.
    let requests = with_app(|a| a.model.icon_requests()).unwrap_or_default();
    for (id, path) in requests {
        let icon = icon_for(&path);
        with_app(|a| a.model.set_icon(&id, icon));
    }

    let _ = RegisterDragDrop(hwnd, &dnd::make_target(hwnd));
    log::line("drag and drop ready");
    let _ = WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION);
    let mut notify = Vec::new();
    for guid in [GUID_CONSOLE_DISPLAY_STATE, GUID_POWER_SAVING_STATUS] {
        if let Ok(h) = RegisterPowerSettingNotification(HANDLE(hwnd.0), &guid, DEVICE_NOTIFY_WINDOW_HANDLE) {
            notify.push(h);
        }
    }
    shell::refresh_start_with_windows();
    log::line("system hooks ready");

    log::line("first draw");
    with_app(|a| {
        a.power_notify = notify;
        a.present();
    });
    log::line("first draw done");
    let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    let _ = SetWindowPos(hwnd, Some(HWND_BOTTOM), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    log::line(&format!("shown; icons host found: {}", shell::desktop_icons_host().is_some()));
    run_effects(Vec::new());
    Ok(())
}

// MARK: App

impl App {
    fn present(&mut self) {
        let scene = self.model.scene();
        let frame = self.renderer.render(&scene);
        let size = self.model.window.size();
        if !self.surface.present(self.hwnd, self.model.window.origin, size, frame) && !self.present_failed {
            // Log once: a failed present leaves the window invisible.
            self.present_failed = true;
            log::line(&format!(
                "could not draw: window {:?} at {:?}, frame {}x{}, error {:?}",
                size, self.model.window.origin, frame.width, frame.height, windows::core::Error::from_thread()
            ));
        }
    }

    /// Draw if something changed, and run the frame clock only while something moves.
    fn schedule(&mut self, delay: f64, task: Task) {
        let id = self.next_timer;
        self.next_timer += 1;
        self.tasks.insert(id, task);
        let ms = (delay * 1000.0).round().max(1.0) as u32;
        unsafe {
            SetTimer(Some(self.hwnd), id, ms, None);
        }
    }

    /// Draw if something changed, and run the frame clock only while something moves.
    /// While the clock runs, only its ticks draw (at most 60 a second), so a fast mouse sending
    /// hundreds of moves a second cannot make the fridge redraw hundreds of times.
    fn refresh(&mut self, from_tick: bool) {
        let animating = self.model.is_animating();
        let clock_running = with_ticker_value(|t| t.is_running()).unwrap_or(false);
        if (from_tick || !(animating && clock_running)) && self.model.take_dirty() {
            self.present();
        }
        // Software drawing: 60 a second is smooth and leaves the CPU cool.
        let hz = 60;
        let last_tick = &mut self.last_tick;
        with_ticker(|t| {
            if animating && !t.is_running() {
                *last_tick = Instant::now() - Duration::from_secs_f64(1.0 / hz as f64);
            }
            t.set(animating, hz);
        });
    }

    /// Redraws the static art at the current size.
    fn rescale_art(&mut self) {
        self.renderer.set_scale(self.model.window.scale() as f32);
        self.model.art_scale_changed();
    }

    fn save_settings(&mut self) {
        let w = self.model.window;
        self.settings.window_origin = Some(Origin { x: w.origin.0, y: w.origin.1 });
        self.settings.fridge_scale = w.user_scale;
        let _ = self.settings.save(&self.settings_path);
    }

    fn view_from_screen(&self, screen: (i32, i32)) -> fridge_core::geometry::Pt {
        let o = self.model.window.origin;
        self.model.window.view_point(((screen.0 - o.0) as f64, (screen.1 - o.1) as f64))
    }

    /// Effects that neither block nor call out of the process.
    fn perform(&mut self, effect: Effect) {
        unsafe {
            match effect {
                Effect::Play(s) => self.sounds.play(s),
                Effect::StopSounds => self.sounds.stop_all(),
                Effect::Beep => beep(),
                Effect::SetCursor(c) => self.cursors.set(c),
                Effect::Capture(true) => {
                    SetCapture(self.hwnd);
                }
                Effect::Capture(false) => {
                    if GetCapture() == self.hwnd {
                        let _ = ReleaseCapture();
                    }
                }
                Effect::WindowResized { rerender } => {
                    if rerender {
                        self.rescale_art();
                    }
                    self.present();
                }
                Effect::SaveSettings => self.save_settings(),
                Effect::Schedule { delay, task } => self.schedule(delay, task),
                // The rest are handled in `perform` below, outside the borrow.
                _ => {}
            }
        }
    }
}

/// Carries out effects in order, including any they lead to, then redraws.
fn run_effects(effects: Vec<Effect>) {
    perform_all(effects);
    with_app(|a| a.refresh(false));
}

fn perform_all(effects: Vec<Effect>) {
    let mut queue: VecDeque<Effect> = effects.into();
    while let Some(e) = queue.pop_front() {
        queue.extend(perform(e));
    }
}

fn perform(effect: Effect) -> Vec<Effect> {
    match effect {
        Effect::BeginItemDrag { id, path } => return begin_item_drag(&id, &path),
        Effect::ConfirmMoveAll { title, message } => {
            with_app(|a| a.refresh(false));
            if dialog::confirm(HWND::default(), &title, &message, "Move to Desktop") {
                return with_app(|a| a.model.move_everything_to_desktop()).unwrap_or_default();
            }
        }
        Effect::Alert { title, message } => dialog::alert(HWND::default(), &title, &message),
        Effect::Open(path) => {
            if !shell::open(&path) {
                beep();
            }
        }
        Effect::ShowInExplorer(path) => {
            if !shell::show_in_explorer(&path) {
                beep();
            }
        }
        Effect::NeedIcon { id, path } => {
            let icon = icon_for(&path);
            with_app(|a| a.model.set_icon(&id, icon));
        }
        Effect::BeginEditor(request) => open_editor(&request),
        Effect::EndEditor => editor::close(),
        // Moving can cross onto another monitor and send WM_DPICHANGED, so not under the borrow.
        Effect::WindowMoved => {
            if let Some((hwnd, (x, y))) = with_app(|a| (a.hwnd, a.model.window.origin)) {
                unsafe {
                    let _ = SetWindowPos(hwnd, None, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                }
            }
        }
        other => {
            with_app(|a| a.perform(other));
        }
    }
    Vec::new()
}

/// The shell icon for a file, cached per path.
fn icon_for(path: &Path) -> Option<Arc<Image>> {
    let (cached, px) = with_app(|a| (a.icons.get(path).cloned(), icon_px(a.model.window.dpi_scale)))?;
    if cached.is_some() {
        return cached;
    }
    let icon = Arc::new(shell::file_icon(path, px)?);
    with_app(|a| a.icons.insert(path.to_path_buf(), icon.clone()));
    Some(icon)
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
                cursor::apply_current();
                return LRESULT(1);
            }
        }
        WM_TICK => {
            with_ticker(|t| t.handled());
            on_tick();
            return LRESULT(0);
        }
        WM_LBUTTONDOWN | WM_LBUTTONDBLCLK | WM_RBUTTONDOWN => {
            // A click on the fridge ends note editing (the window never takes focus itself).
            if editing() {
                finish_editor(true);
            }
            if msg != WM_RBUTTONDOWN {
                mouse(MouseKind::Down(if msg == WM_LBUTTONDBLCLK { 2 } else { 1 }), wparam, lparam);
            }
            return LRESULT(0);
        }
        WM_MOUSEMOVE => {
            mouse(MouseKind::Move, wparam, lparam);
            return LRESULT(0);
        }
        WM_LBUTTONUP => {
            mouse(MouseKind::Up, wparam, lparam);
            return LRESULT(0);
        }
        WM_RBUTTONUP => {
            context_menu(lparam);
            return LRESULT(0);
        }
        WM_CAPTURECHANGED => {
            if lparam.0 != hwnd.0 as isize {
                let fx = with_app(|a| a.model.cancel_interaction()).unwrap_or_default();
                run_effects(fx);
            }
            return LRESULT(0);
        }
        WM_TIMER => {
            on_timer(hwnd, wparam.0);
            return LRESULT(0);
        }
        WM_DROP_DONE => {
            on_drop_done();
            return LRESULT(0);
        }
        editor::WM_EDITOR_DONE => {
            if lparam.0 == editor::generation() {
                finish_editor(wparam.0 == 1);
            }
            return LRESULT(0);
        }
        MM_WOM_DONE => {
            with_app(|a| a.sounds.on_done(wparam.0 as isize));
            return LRESULT(0);
        }
        WM_DPICHANGED => {
            if !on_dpi_changed(loword(wparam), Some(*(lparam.0 as *const RECT))) {
                let _ = PostMessageW(Some(hwnd), WM_DPI_RECHECK, WPARAM(0), LPARAM(0));
            }
            return LRESULT(0);
        }
        WM_DPI_RECHECK => {
            let dpi = GetDpiForWindow(hwnd);
            if dpi > 0 {
                on_dpi_changed(dpi, None);
            }
            return LRESULT(0);
        }
        WM_DISPLAYCHANGE => on_display_change(),
        WM_SETTINGCHANGE => on_setting_change(),
        WM_WTSSESSION_CHANGE => match wparam.0 as u32 {
            WTS_SESSION_LOCK => set_paused(PauseReason::Lock, true),
            WTS_SESSION_UNLOCK => set_paused(PauseReason::Lock, false),
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
    let Some(host) = shell::desktop_icons_host() else { return Some(HWND_BOTTOM) };
    match GetWindow(host, GW_HWNDPREV) {
        Ok(prev) if prev == hwnd => None,
        Ok(prev) if !prev.is_invalid() => Some(prev),
        _ => Some(HWND_BOTTOM),
    }
}

/// The model is in note-editing mode (the editor window may have failed to open).
fn editing() -> bool {
    editor::is_open() || with_app(|a| a.model.editing_id().is_some()).unwrap_or(false)
}

// MARK: Input

enum MouseKind {
    Down(u32),
    Move,
    Up,
}

unsafe fn mouse(kind: MouseKind, wparam: WPARAM, lparam: LPARAM) {
    let client = lparam_point(lparam);
    let pos = GetMessagePos();
    let screen = ((pos & 0xFFFF) as u16 as i16 as f64, ((pos >> 16) & 0xFFFF) as u16 as i16 as f64);
    let ctrl = wparam.0 as u32 & MK_CONTROL.0 != 0;
    let alt = GetKeyState(VK_MENU.0 as i32) < 0;
    let fx = with_app(|a| {
        let view = a.model.window.view_point((client.0 as f64, client.1 as f64));
        let clicks = if let MouseKind::Down(n) = kind { n } else { 1 };
        let m = Mouse { view, screen, clicks, ctrl, alt };
        match kind {
            MouseKind::Down(_) => a.model.mouse_down(&m),
            MouseKind::Move => a.model.mouse_move(&m),
            MouseKind::Up => a.model.mouse_up(&m),
        }
    });
    run_effects(fx.unwrap_or_default());
}

unsafe fn context_menu(lparam: LPARAM) {
    let hwnd = main_hwnd();
    if editing() {
        finish_editor(true);
    }
    let client = lparam_point(lparam);
    let start_with_windows = shell::start_with_windows_command().is_some();
    let menu = with_app(|a| {
        if a.model.is_interacting() {
            return None;
        }
        let view = a.model.window.view_point((client.0 as f64, client.1 as f64));
        let o = a.model.window.origin;
        Some((a.model.context_menu(view, start_with_windows), (o.0 + client.0, o.1 + client.1)))
    })
    .flatten();
    let Some((entries, at)) = menu else { return };
    let Some(command) = popup::show(hwnd, &entries, at) else { return };
    match command {
        Command::ToggleStartWithWindows => {
            if !shell::set_start_with_windows(!start_with_windows) {
                beep();
            }
        }
        Command::Quit => {
            let _ = DestroyWindow(hwnd);
        }
        c => {
            let fx = with_app(|a| a.model.run_command(c)).unwrap_or_default();
            run_effects(fx);
        }
    }
}

fn on_tick() {
    let fx = with_app(|a| {
        let now = Instant::now();
        let dt = now.duration_since(a.last_tick).as_secs_f64();
        a.last_tick = now;
        a.model.tick(dt, wall_now())
    });
    perform_all(fx.unwrap_or_default());
    with_app(|a| a.refresh(true));
}

unsafe fn on_timer(hwnd: HWND, id: usize) {
    if id < FIRST_TASK_TIMER {
        return;
    }
    let _ = KillTimer(Some(hwnd), id);
    let Some(task) = with_app(|a| a.tasks.remove(&id)).flatten() else { return };
    match task {
        Task::RestoreDesktopPosition { path, position } => {
            if shell::set_desktop_icon_position(&path, position) {
                log::line(&format!("icon put back at {position:?}: {}", path.display()));
                with_app(|a| a.position_retries.remove(&path));
            } else {
                // Explorer may not show the file yet. Try again for about six seconds.
                let tries = with_app(|a| {
                    let n = a.position_retries.entry(path.clone()).or_insert(0);
                    *n += 1;
                    *n
                })
                .unwrap_or(99);
                if tries < 12 {
                    with_app(|a| a.schedule(0.5, Task::RestoreDesktopPosition { path, position }));
                } else {
                    log::line(&format!("could not put the icon back at {position:?}: {}", path.display()));
                    with_app(|a| a.position_retries.remove(&path));
                }
            }
        }
        task => {
            let fx = with_app(|a| a.model.run_task(task)).unwrap_or_default();
            run_effects(fx);
        }
    }
}

// MARK: Drag and drop

fn on_drag_over(screen: (i32, i32), info: &DragInfo, allowed: Allowed) -> DropEffect {
    let result = with_app(|a| {
        if a.dragging_out {
            return (DropEffect::None, Vec::new());
        }
        let view = a.view_from_screen(screen);
        a.model.drag_over(view, info, allowed)
    });
    let (effect, fx) = result.unwrap_or((DropEffect::None, Vec::new()));
    run_effects(fx);
    effect
}

fn on_drag_leave() {
    with_app(|a| a.model.drag_leave());
    run_effects(Vec::new());
}

fn on_drop(screen: (i32, i32), info: &DragInfo, allowed: Allowed) -> DropEffect {
    let effect = with_app(|a| {
        if a.dragging_out {
            return DropEffect::None;
        }
        let view = a.view_from_screen(screen);
        let (effect, action) = a.model.drop(view, info, allowed);
        let reply = match &action {
            // We move these ourselves; "no effect" keeps the source from deleting anything.
            DropAction::Store { .. } => DropEffect::None,
            _ => effect,
        };
        if action != DropAction::Nothing {
            a.pending_drop = Some(action);
            unsafe {
                let _ = PostMessageW(Some(a.hwnd), WM_DROP_DONE, WPARAM(0), LPARAM(0));
            }
        }
        reply
    })
    .unwrap_or(DropEffect::None);
    run_effects(Vec::new());
    effect
}

fn on_drop_done() {
    let Some((action, desktop)) = with_app(|a| a.pending_drop.take().map(|x| (x, a.model.store.desktop.clone()))).flatten()
    else {
        return;
    };
    let fx = match action {
        DropAction::Store { shelf, files } => {
            // Read Desktop icon positions before the files leave, so Put Back can restore them.
            let list: Vec<(PathBuf, Option<(f64, f64)>)> = files
                .into_iter()
                .map(|f| {
                    let pos = if dnd::on_desktop(&f, &desktop) { shell::desktop_icon_position(&f) } else { None };
                    log::line(&format!("storing {} (desktop icon at {:?})", f.display(), pos));
                    (f, pos)
                })
                .collect();
            with_app(|a| a.model.store_files(list, shelf, wall_now()))
        }
        DropAction::StickPhotos { door, point, files } => with_app(|a| a.model.stick_photos(door, point, &files)),
        DropAction::StickText { door, point, text } => with_app(|a| a.model.stick_text(door, point, &text)),
        DropAction::Nothing => None,
    };
    run_effects(fx.unwrap_or_default());
}

fn begin_item_drag(id: &str, path: &Path) -> Vec<Effect> {
    let prepared = with_app(|a| {
        a.model.item_drag_started(id);
        a.dragging_out = true;
        a.refresh(false);
        (a.icons.get(path).cloned(), (64.0 * a.model.window.scale()).round() as i32)
    });
    let Some((icon, px)) = prepared else { return Vec::new() };
    dnd::drag_out(path, icon.as_deref(), px);
    with_app(|a| {
        a.dragging_out = false;
        a.model.item_drag_ended(id)
    })
    .unwrap_or_default()
}

// MARK: Note editor

fn open_editor(request: &EditorRequest) {
    let placed = with_app(|a| {
        let s = a.model.window.scale();
        let c = a.model.window.screen_point(request.center);
        let (tx, ty, tw, th) = NOTE_TEXT_RECT;
        // The text area's centre relative to the note's centre, y up in the note, y down on screen.
        let dx = tx + tw / 2.0 - fridge_art::NOTE_SIZE / 2.0;
        let dy = ty + th / 2.0 - fridge_art::NOTE_SIZE / 2.0;
        let (cx, cy) = (c.0 + dx * s, c.1 - dy * s);
        let rect = RECT {
            left: (cx - tw * s / 2.0).round() as i32,
            top: (cy - th * s / 2.0).round() as i32,
            right: (cx + tw * s / 2.0).round() as i32,
            bottom: (cy + th * s / 2.0).round() as i32,
        };
        a.refresh(false);
        (a.hwnd, rect, (NOTE_FONT_SIZE as f64 * s).round() as i32, a.note_face.clone())
    });
    if let Some((hwnd, rect, font_px, face)) = placed {
        editor::open(hwnd, rect, &request.text, request.color, font_px, &face);
    }
}

/// Closes the editor, saving (Enter, click elsewhere) or cancelling (Esc).
fn finish_editor(save: bool) {
    let text = if save { editor::text() } else { None };
    editor::close();
    let fx = with_app(|a| a.model.finish_editing(text)).unwrap_or_default();
    run_effects(fx);
}

// MARK: System events

/// The window is now on a monitor with another DPI. `suggested` is Windows' rect for it (None:
/// keep the top-left). False when the state was busy and nothing was done.
fn on_dpi_changed(dpi: u32, suggested: Option<RECT>) -> bool {
    let done = with_app(|a| {
        let new = dpi.max(48) as f64 / 96.0;
        if (new - a.model.window.dpi_scale).abs() < 1e-6 {
            return;
        }
        a.model.window.dpi_scale = new;
        if let Some(r) = suggested {
            a.model.window.origin = (r.left, r.top);
        }
        a.cursors.set_dpi(new);
        a.rescale_art();
        a.present();
        let mut p = POINT::default();
        unsafe {
            let _ = GetCursorPos(&mut p);
        }
        a.model.rebase_window_drag((p.x as f64, p.y as f64));
    });
    run_effects(Vec::new());
    done.is_some()
}

/// A monitor came or went: if the fridge is now off every screen, bring it back to the default spot.
fn on_display_change() {
    with_app(|a| {
        let monitors = shell::monitors();
        let w = a.model.window;
        if placement::body_visible(w.origin, w.scale(), &monitors) {
            return;
        }
        let Some(m) = placement::primary(&monitors) else { return };
        let dpi_changed = (m.dpi_scale - w.dpi_scale).abs() > 1e-6;
        a.model.window.dpi_scale = m.dpi_scale;
        a.model.window.origin = placement::default_origin(m, w.user_scale);
        if dpi_changed {
            a.cursors.set_dpi(m.dpi_scale);
            a.rescale_art();
        }
        a.present();
    });
    run_effects(Vec::new());
}

/// Light or dark mode, animation effects and battery saver may have changed.
fn on_setting_change() {
    with_app(|a| {
        let dark = shell::is_dark_mode();
        if dark != a.renderer.dark() {
            a.renderer.set_dark(dark);
            a.model.mark_dirty();
        }
        a.model.reduce_motion = shell::reduce_motion();
        a.model.low_power = shell::battery_saver();
    });
    run_effects(Vec::new());
}

fn set_paused(reason: PauseReason, on: bool) {
    if on && editing() {
        finish_editor(true);
    }
    let fx = with_app(|a| a.model.set_paused(reason, on)).unwrap_or_default();
    run_effects(fx);
}

unsafe fn on_power(event: u32, lparam: LPARAM) {
    match event {
        PBT_APMSUSPEND => set_paused(PauseReason::Sleep, true),
        PBT_APMRESUMESUSPEND | PBT_APMRESUMEAUTOMATIC => set_paused(PauseReason::Sleep, false),
        PBT_APMPOWERSTATUSCHANGE => {
            with_app(|a| a.model.low_power = shell::battery_saver());
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
                set_paused(PauseReason::DisplayOff, value == 0);
            } else if s.PowerSetting == GUID_POWER_SAVING_STATUS {
                with_app(|a| a.model.low_power = value != 0);
            }
        }
        _ => {}
    }
}

unsafe fn on_destroy(hwnd: HWND) {
    if editing() {
        finish_editor(true);
    }
    with_ticker(|t| t.stop_thread());
    let _ = RevokeDragDrop(hwnd);
    let _ = WTSUnRegisterSessionNotification(hwnd);
    with_app(|a| {
        a.sounds.stop_all();
        for h in a.power_notify.drain(..) {
            let _ = UnregisterPowerSettingNotification(h);
        }
        for id in a.tasks.keys() {
            let _ = KillTimer(Some(hwnd), *id);
        }
    });
}
