//! The frame clock. A thread that sleeps until the next frame and posts one message to the window.
//! It runs only while something moves; at rest it waits on a condition variable with no timer
//! armed at all (quiet at rest). `std::thread::sleep` uses a high-resolution waitable timer on
//! Windows 10 1803 and later, so 120 Hz pacing is accurate.

use super::util::{hwnd_from_isize, hwnd_to_isize};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

#[derive(Default)]
struct State {
    running: bool,
    hz: u32,
    /// A tick is posted and not handled yet: do not pile more up behind it.
    pending: bool,
    quit: bool,
}

pub struct Ticker {
    shared: Arc<(Mutex<State>, Condvar)>,
}

impl Ticker {
    pub fn start(hwnd: HWND, message: u32) -> Ticker {
        let shared = Arc::new((Mutex::new(State { hz: 60, ..State::default() }), Condvar::new()));
        let thread_shared = shared.clone();
        let target = hwnd_to_isize(hwnd);
        std::thread::Builder::new()
            .name("frame clock".into())
            .spawn(move || run(thread_shared, target, message))
            .expect("frame clock thread");
        Ticker { shared }
    }

    /// Start, stop or change rate. Cheap to call after every event.
    pub fn set(&self, running: bool, hz: u32) {
        let (lock, cv) = &*self.shared;
        let mut s = lock.lock().unwrap();
        let wake = running && !s.running;
        s.running = running;
        s.hz = hz.max(1);
        if wake {
            cv.notify_one();
        }
    }

    pub fn is_running(&self) -> bool {
        self.shared.0.lock().unwrap().running
    }

    /// The window handled a tick; the next one may be posted.
    pub fn handled(&self) {
        self.shared.0.lock().unwrap().pending = false;
    }

    pub fn stop_thread(&self) {
        let (lock, cv) = &*self.shared;
        lock.lock().unwrap().quit = true;
        cv.notify_one();
    }
}

fn run(shared: Arc<(Mutex<State>, Condvar)>, hwnd: isize, message: u32) {
    let (lock, cv) = &*shared;
    let mut next: Option<Instant> = None;
    loop {
        let hz = {
            let mut s = lock.lock().unwrap();
            while !s.running && !s.quit {
                next = None;
                s = cv.wait(s).unwrap();
            }
            if s.quit {
                return;
            }
            s.hz
        };
        let period = Duration::from_secs_f64(1.0 / hz as f64);
        let now = Instant::now();
        let due = match next {
            Some(t) if t > now => t,
            // First frame, or we fell behind: start counting from now.
            _ => now + period,
        };
        std::thread::sleep(due.saturating_duration_since(Instant::now()));
        next = Some(due + period);
        let mut s = lock.lock().unwrap();
        if s.running && !s.pending {
            s.pending = true;
            drop(s);
            unsafe {
                if PostMessageW(Some(hwnd_from_isize(hwnd)), message, WPARAM(0), LPARAM(0)).is_err() {
                    lock.lock().unwrap().pending = false;
                }
            }
        }
    }
}
