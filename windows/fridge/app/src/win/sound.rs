//! The two door clicks through `waveOut`. Each sound has its own voice, so an open click and a
//! seal click can overlap; retriggering a sound restarts it. A voice opens the audio device only
//! while it plays and closes it when done (MM_WOM_DONE to the window), so nothing stays open at rest.

use crate::model::Sound;
use crate::wav::Wav;
use windows::core::PSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::Media::Audio::{
    waveOutClose, waveOutOpen, waveOutPrepareHeader, waveOutReset, waveOutUnprepareHeader, waveOutWrite, CALLBACK_WINDOW,
    HWAVEOUT, WAVEFORMATEX, WAVEHDR, WAVE_MAPPER, WHDR_DONE, WHDR_INQUEUE,
};

struct Voice {
    wav: Option<Wav>,
    device: Option<HWAVEOUT>,
    header: Box<WAVEHDR>,
}

pub struct Sounds {
    hwnd: HWND,
    voices: [Voice; 2],
}

const HEADER_SIZE: u32 = std::mem::size_of::<WAVEHDR>() as u32;

impl Sounds {
    pub fn new(hwnd: HWND, open: Option<Wav>, seal: Option<Wav>) -> Sounds {
        let voice = |wav| Voice { wav, device: None, header: Box::new(WAVEHDR::default()) };
        Sounds { hwnd, voices: [voice(open), voice(seal)] }
    }

    pub fn play(&mut self, sound: Sound) {
        let index = match sound {
            Sound::Open => 0,
            Sound::Seal => 1,
        };
        let hwnd = self.hwnd;
        let v = &mut self.voices[index];
        let Some(wav) = v.wav.as_ref() else { return };
        unsafe {
            let device = match v.device {
                Some(d) => {
                    // Already playing: start again from the top.
                    waveOutReset(d);
                    waveOutUnprepareHeader(d, &mut *v.header, HEADER_SIZE);
                    d
                }
                None => {
                    let format = WAVEFORMATEX {
                        wFormatTag: wav.format_tag,
                        nChannels: wav.channels,
                        nSamplesPerSec: wav.sample_rate,
                        nAvgBytesPerSec: wav.byte_rate,
                        nBlockAlign: wav.block_align,
                        wBitsPerSample: wav.bits_per_sample,
                        cbSize: 0,
                    };
                    let mut d = HWAVEOUT::default();
                    let r = waveOutOpen(Some(&mut d), WAVE_MAPPER, &format, Some(hwnd.0 as usize), Some(0), CALLBACK_WINDOW);
                    if r != 0 {
                        return; // no audio device: stay silent
                    }
                    v.device = Some(d);
                    d
                }
            };
            *v.header = WAVEHDR {
                lpData: PSTR(wav.data.as_ptr() as *mut u8),
                dwBufferLength: wav.data.len() as u32,
                ..WAVEHDR::default()
            };
            if waveOutPrepareHeader(device, &mut *v.header, HEADER_SIZE) != 0 || waveOutWrite(device, &mut *v.header, HEADER_SIZE) != 0 {
                waveOutUnprepareHeader(device, &mut *v.header, HEADER_SIZE);
                waveOutClose(device);
                v.device = None;
            }
        }
    }

    /// MM_WOM_DONE: a buffer finished (or was reset). Close the device unless it was restarted.
    pub fn on_done(&mut self, device: isize) {
        for v in self.voices.iter_mut() {
            let Some(d) = v.device else { continue };
            if d.0 as isize != device {
                continue;
            }
            let flags = v.header.dwFlags;
            if flags & WHDR_DONE != 0 && flags & WHDR_INQUEUE == 0 {
                unsafe {
                    waveOutUnprepareHeader(d, &mut *v.header, HEADER_SIZE);
                    waveOutClose(d);
                }
                v.device = None;
            }
        }
    }

    pub fn stop_all(&mut self) {
        for v in self.voices.iter_mut() {
            if let Some(d) = v.device {
                unsafe {
                    waveOutReset(d);
                }
            }
        }
    }
}

impl Drop for Sounds {
    fn drop(&mut self) {
        for v in self.voices.iter_mut() {
            if let Some(d) = v.device.take() {
                unsafe {
                    waveOutReset(d);
                    waveOutUnprepareHeader(d, &mut *v.header, HEADER_SIZE);
                    waveOutClose(d);
                }
            }
        }
    }
}
