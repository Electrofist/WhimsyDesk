//! Sound through `waveOut` (PORT-SPEC section 8). The samples come from `drawer-core`: two
//! knocks played from memory, and the slide rumble streamed in short buffers while the drawer
//! moves. Every device is opened only while it plays and closed when done (`MM_WOM_DONE` comes to
//! the window), so nothing stays open at rest.

use drawer_core::sound::{synth_knock, SlideSynth, SAMPLE_RATE};
use drawer_core::{Knock, KnockKind};
use std::time::{Duration, Instant};
use windows::core::PSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::Media::Audio::{
    waveOutClose, waveOutOpen, waveOutPrepareHeader, waveOutReset, waveOutUnprepareHeader,
    waveOutWrite, CALLBACK_WINDOW, HWAVEOUT, WAVEFORMATEX, WAVEHDR, WAVE_MAPPER, WHDR_DONE,
    WHDR_INQUEUE,
};

const HEADER_SIZE: u32 = std::mem::size_of::<WAVEHDR>() as u32;
const WAVE_FORMAT_PCM: u16 = 1;

fn format() -> WAVEFORMATEX {
    WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_PCM,
        nChannels: 1,
        nSamplesPerSec: SAMPLE_RATE,
        nAvgBytesPerSec: SAMPLE_RATE * 2,
        nBlockAlign: 2,
        wBitsPerSample: 16,
        cbSize: 0,
    }
}

unsafe fn open_device(hwnd: HWND) -> Option<HWAVEOUT> {
    let mut d = HWAVEOUT::default();
    let r = waveOutOpen(
        Some(&mut d),
        WAVE_MAPPER,
        &format(),
        Some(hwnd.0 as usize),
        Some(0),
        CALLBACK_WINDOW,
    );
    (r == 0).then_some(d) // no audio device: stay silent
}

fn to_i16(x: f32) -> i16 {
    (x.clamp(-1.0, 1.0) * 32767.0) as i16
}

/// One knock: its samples, a scratch copy scaled to the requested volume, and the open device.
struct Voice {
    pcm: Vec<i16>,
    scaled: Vec<i16>,
    device: Option<HWAVEOUT>,
    header: Box<WAVEHDR>,
}

impl Voice {
    fn new(kind: KnockKind) -> Voice {
        let pcm = synth_knock(kind);
        Voice {
            scaled: pcm.clone(),
            pcm,
            device: None,
            header: Box::new(WAVEHDR::default()),
        }
    }
}

/// The sliding rumble: a few short buffers kept queued while the drawer moves.
struct Rumble {
    device: Option<HWAVEOUT>,
    headers: Vec<Box<WAVEHDR>>,
    bufs: Vec<Vec<i16>>,
    synth: SlideSynth,
    speed: f64,
    quiet_since: Option<Instant>,
    /// Reset requested: waiting for the queued buffers to come back before closing.
    closing: bool,
}

const RUMBLE_BUFFERS: usize = 3;
/// 25 ms each: short enough that the rumble follows the drawer closely.
const RUMBLE_SAMPLES: usize = (SAMPLE_RATE as usize) / 40;
/// The device is closed this long after the drawer comes to rest.
const QUIET_BEFORE_CLOSE: Duration = Duration::from_millis(350);

impl Rumble {
    fn new() -> Rumble {
        Rumble {
            device: None,
            headers: (0..RUMBLE_BUFFERS)
                .map(|_| Box::new(WAVEHDR::default()))
                .collect(),
            bufs: (0..RUMBLE_BUFFERS)
                .map(|_| vec![0i16; RUMBLE_SAMPLES])
                .collect(),
            synth: SlideSynth::new(),
            speed: 0.0,
            quiet_since: None,
            closing: false,
        }
    }

    unsafe fn queue(&mut self, i: usize) -> bool {
        let Some(d) = self.device else { return false };
        let mut samples = [0f32; RUMBLE_SAMPLES];
        self.synth.fill(&mut samples);
        for (o, s) in self.bufs[i].iter_mut().zip(samples) {
            *o = to_i16(s);
        }
        *self.headers[i] = WAVEHDR {
            lpData: PSTR(self.bufs[i].as_mut_ptr() as *mut u8),
            dwBufferLength: (RUMBLE_SAMPLES * 2) as u32,
            ..WAVEHDR::default()
        };
        waveOutPrepareHeader(d, &mut *self.headers[i], HEADER_SIZE) == 0
            && waveOutWrite(d, &mut *self.headers[i], HEADER_SIZE) == 0
    }

    /// The drawer's current speed. Starts the stream when it begins to move.
    unsafe fn set_speed(&mut self, hwnd: HWND, speed: f64) {
        self.speed = speed;
        self.synth.set_speed(speed);
        if speed > 0.0 {
            self.quiet_since = None;
            if self.device.is_none() {
                self.device = open_device(hwnd);
                self.closing = false;
                for i in 0..RUMBLE_BUFFERS {
                    if !self.queue(i) {
                        self.teardown();
                        return;
                    }
                }
            }
        }
    }

    unsafe fn teardown(&mut self) {
        if let Some(d) = self.device.take() {
            waveOutReset(d);
            for h in self.headers.iter_mut() {
                waveOutUnprepareHeader(d, &mut **h, HEADER_SIZE);
            }
            waveOutClose(d);
        }
        self.closing = false;
        self.quiet_since = None;
    }

    /// A buffer finished playing: refill it, or wind down once the drawer has been still a while.
    unsafe fn on_done(&mut self, device: isize, header: isize) -> bool {
        let Some(d) = self.device else { return false };
        if d.0 as isize != device {
            return false;
        }
        if self.closing {
            if self.headers.iter().all(|h| h.dwFlags & WHDR_INQUEUE == 0) {
                self.teardown();
            }
            return true;
        }
        let Some(i) = self
            .headers
            .iter()
            .position(|h| &**h as *const WAVEHDR as isize == header)
        else {
            return true;
        };
        waveOutUnprepareHeader(d, &mut *self.headers[i], HEADER_SIZE);
        if self.speed > 0.0 {
            self.quiet_since = None;
        } else {
            let since = *self.quiet_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= QUIET_BEFORE_CLOSE {
                self.closing = true;
                waveOutReset(d); // returns every queued buffer, each with its own MM_WOM_DONE
                if self.headers.iter().all(|h| h.dwFlags & WHDR_INQUEUE == 0) {
                    self.teardown();
                }
                return true;
            }
        }
        if !self.queue(i) {
            self.teardown();
        }
        true
    }
}

pub struct Sounds {
    hwnd: HWND,
    knocks: [Voice; 2],
    rumble: Rumble,
}

fn index(kind: KnockKind) -> usize {
    match kind {
        KnockKind::Close => 0,
        KnockKind::Open => 1,
    }
}

impl Sounds {
    pub fn new(hwnd: HWND) -> Sounds {
        Sounds {
            hwnd,
            knocks: [Voice::new(KnockKind::Close), Voice::new(KnockKind::Open)],
            rumble: Rumble::new(),
        }
    }

    /// A knock at the requested volume. Retriggering a knock restarts it.
    pub fn knock(&mut self, k: Knock) {
        let hwnd = self.hwnd;
        let v = &mut self.knocks[index(k.kind)];
        let volume = k.volume.clamp(0.0, 1.0);
        unsafe {
            let device = match v.device {
                Some(d) => {
                    waveOutReset(d);
                    waveOutUnprepareHeader(d, &mut *v.header, HEADER_SIZE);
                    d
                }
                None => match open_device(hwnd) {
                    Some(d) => {
                        v.device = Some(d);
                        d
                    }
                    None => return,
                },
            };
            for (o, s) in v.scaled.iter_mut().zip(&v.pcm) {
                *o = (*s as f32 * volume) as i16;
            }
            *v.header = WAVEHDR {
                lpData: PSTR(v.scaled.as_mut_ptr() as *mut u8),
                dwBufferLength: (v.scaled.len() * 2) as u32,
                ..WAVEHDR::default()
            };
            if waveOutPrepareHeader(device, &mut *v.header, HEADER_SIZE) != 0
                || waveOutWrite(device, &mut *v.header, HEADER_SIZE) != 0
            {
                waveOutUnprepareHeader(device, &mut *v.header, HEADER_SIZE);
                waveOutClose(device);
                v.device = None;
            }
        }
    }

    /// The drawer's speed (zero when parked); drives the rumble.
    pub fn set_slide_speed(&mut self, speed: f64) {
        let hwnd = self.hwnd;
        unsafe { self.rumble.set_speed(hwnd, speed) }
    }

    /// MM_WOM_DONE: a buffer came back. `device` is the handle (wParam), `header` the buffer (lParam).
    pub fn on_done(&mut self, device: isize, header: isize) {
        unsafe {
            if self.rumble.on_done(device, header) {
                return;
            }
            for v in self.knocks.iter_mut() {
                let Some(d) = v.device else { continue };
                if d.0 as isize != device {
                    continue;
                }
                let flags = v.header.dwFlags;
                if flags & WHDR_DONE != 0 && flags & WHDR_INQUEUE == 0 {
                    waveOutUnprepareHeader(d, &mut *v.header, HEADER_SIZE);
                    waveOutClose(d);
                    v.device = None;
                }
            }
        }
    }

    pub fn stop_all(&mut self) {
        unsafe {
            self.rumble.speed = 0.0;
            self.rumble.synth.silence();
            self.rumble.teardown();
            for v in self.knocks.iter() {
                if let Some(d) = v.device {
                    waveOutReset(d);
                }
            }
        }
    }
}

impl Drop for Sounds {
    fn drop(&mut self) {
        unsafe {
            self.rumble.teardown();
            for v in self.knocks.iter_mut() {
                if let Some(d) = v.device.take() {
                    waveOutReset(d);
                    waveOutUnprepareHeader(d, &mut *v.header, HEADER_SIZE);
                    waveOutClose(d);
                }
            }
        }
    }
}
