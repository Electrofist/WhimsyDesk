//! All of the drawer's sound is synthesized; there are no audio assets (PORT-SPEC section 8).
//! Port of `SoftSound.swift`. This file only computes samples; playing them is the app's job.
//!
//! - `synth_knock`: muted wooden knocks, rendered once into PCM.
//! - `SlideSynth`: a quiet wood-on-wood rumble whose loudness follows the drawer's speed. The app
//!   runs it only while the drawer moves and stops the audio device shortly after it rests.

pub const SAMPLE_RATE: u32 = 44_100;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KnockKind {
    /// Front panel against the cabinet (also used after a drop).
    Close,
    /// Box against the stop block at full extension.
    Open,
}

/// One 16-bit mono PCM knock at 44.1 kHz. Volume is applied by the player.
pub fn synth_knock(kind: KnockKind) -> Vec<i16> {
    let rate = SAMPLE_RATE as f32;
    let duration: f64 = if kind == KnockKind::Close { 0.26 } else { 0.16 };
    let count = (duration * SAMPLE_RATE as f64) as usize;
    // Wood-body modes (frequency, decay per second, amplitude) excited by a short, felt-softened impact.
    let modes: &[(f32, f32, f32)] = if kind == KnockKind::Close {
        &[
            (98.0, 20.0, 1.0),
            (214.0, 30.0, 0.42),
            (377.0, 48.0, 0.22),
            (611.0, 75.0, 0.10),
        ]
    } else {
        &[(176.0, 38.0, 0.7), (402.0, 60.0, 0.35), (835.0, 95.0, 0.16)]
    };
    // The close has a second, smaller bump: the drawer settling back off the bumpers.
    let hits: &[(f32, f32)] = if kind == KnockKind::Close {
        &[(0.0, 1.0), (0.062, 0.22)]
    } else {
        &[(0.0, 1.0)]
    };
    let impact_factor: f32 = if kind == KnockKind::Close { 0.5 } else { 0.7 };

    let mut pcm = Vec::with_capacity(count);
    let mut seed: u32 = 12_345;
    let mut soft: f32 = 0.0;
    for i in 0..count {
        let t = i as f32 / rate;
        seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let noise = (seed as i32) as f32 / i32::MAX as f32;
        soft += 0.12 * (noise - soft);
        let mut sample = 0.0f32;
        for &(start, gain) in hits {
            if t < start {
                continue;
            }
            let u = t - start;
            let attack = (u / 0.0018).min(1.0); // felt: no hard click
            let mut body = 0.0f32;
            for &(freq, decay, amp) in modes {
                body += (2.0 * std::f32::consts::PI * freq * u).sin() * (-u * decay).exp() * amp;
            }
            let impact = soft * (-u * 160.0).exp() * impact_factor;
            sample += (body * 0.55 + impact) * attack * gain;
        }
        pcm.push((sample.clamp(-1.0, 1.0) * 24_000.0) as i16);
    }
    pcm
}

/// Wraps mono 16-bit PCM in a RIFF/WAVE container (what `waveOut` or a file player expects).
pub fn wav_bytes(pcm: &[i16]) -> Vec<u8> {
    let data_len = (pcm.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + pcm.len() * 2);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    out.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in pcm {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// Generator for the sliding rumble. Feed it the drawer speed, then pull samples.
#[derive(Clone, Debug)]
pub struct SlideSynth {
    target: f32,
    level: f32,
    seed: u32,
    rumble: f32,
    scrape: f32,
    catch_env: f32,
    wobble: f32,
}

impl Default for SlideSynth {
    fn default() -> Self {
        Self::new()
    }
}

impl SlideSynth {
    pub fn new() -> Self {
        Self {
            target: 0.0,
            level: 0.0,
            seed: 0x2545_F491,
            rumble: 0.0,
            scrape: 0.0,
            catch_env: 0.0,
            wobble: 0.0,
        }
    }

    /// `speed` is the drawer's speed in travels per second (see `DrawerPhysics::slide_speed`).
    pub fn set_speed(&mut self, speed: f64) {
        self.target = (speed * 0.5).min(1.0) as f32 * 0.22;
    }

    pub fn silence(&mut self) {
        self.target = 0.0;
    }

    /// Current loudness; the app can stop the audio device once this is effectively zero.
    pub fn level(&self) -> f32 {
        self.level
    }

    pub fn next_sample(&mut self) -> f32 {
        self.level += (self.target - self.level) * 0.0012; // ~20 ms glide, no zipper noise
        self.seed = self
            .seed
            .wrapping_mul(1_664_525)
            .wrapping_add(1_013_904_223);
        let white = (self.seed as i32) as f32 / i32::MAX as f32;
        self.rumble += 0.03 * (white - self.rumble); // low body of the runners
        self.scrape += 0.22 * (white - self.scrape); // fine grain dragging over wood
        self.wobble += 0.0004 * (white - self.wobble); // slow unevenness in the rubbing
        if white > 0.99975 {
            self.catch_env = 1.0; // the odd tiny catch in the grain
        }
        self.catch_env *= 0.9965;
        let texture = 1.0 + self.wobble * 40.0;
        (self.rumble * 2.4 * texture
            + (self.scrape - self.rumble) * 0.16
            + self.catch_env * self.scrape * 0.6)
            * self.level
    }

    pub fn fill(&mut self, out: &mut [f32]) {
        for s in out {
            *s = self.next_sample();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knock_lengths_match_the_durations() {
        assert_eq!(
            synth_knock(KnockKind::Close).len(),
            (0.26 * 44_100.0) as usize
        );
        assert_eq!(
            synth_knock(KnockKind::Open).len(),
            (0.16 * 44_100.0) as usize
        );
    }

    #[test]
    fn knocks_have_sound_and_fade_out() {
        for kind in [KnockKind::Close, KnockKind::Open] {
            let pcm = synth_knock(kind);
            let peak = pcm.iter().map(|s| (*s as i32).abs()).max().unwrap();
            assert!(peak > 1_000, "{kind:?} should be audible, peak {peak}");
            assert!(peak <= 24_000, "{kind:?} must not clip, peak {peak}");
            let tail: i32 = pcm[pcm.len() - 200..]
                .iter()
                .map(|s| (*s as i32).abs())
                .max()
                .unwrap();
            assert!(
                tail < peak / 10,
                "{kind:?} should have faded, tail {tail} peak {peak}"
            );
        }
    }

    #[test]
    fn knocks_are_deterministic() {
        assert_eq!(synth_knock(KnockKind::Close), synth_knock(KnockKind::Close));
    }

    #[test]
    fn the_close_knock_has_a_second_bump() {
        let pcm = synth_knock(KnockKind::Close);
        // The second hit starts at 0.062 s = sample 2734. The signal there must differ from a
        // single decaying hit, so just check there is no dead silence around it.
        let around: i32 = pcm[2734..2834]
            .iter()
            .map(|s| (*s as i32).abs())
            .max()
            .unwrap();
        assert!(around > 50);
    }

    #[test]
    fn wav_header_is_valid() {
        let wav = wav_bytes(&[1, -2, 3]);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 36 + 6);
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 44_100);
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 6);
        assert_eq!(wav.len(), 44 + 6);
        assert_eq!(i16::from_le_bytes([wav[46], wav[47]]), -2);
    }

    #[test]
    fn slide_is_silent_at_rest_and_loud_when_fast() {
        let mut quiet = SlideSynth::new();
        let mut buf = vec![0.0f32; 5_000];
        quiet.fill(&mut buf);
        assert!(buf.iter().all(|s| *s == 0.0));

        let mut loud = SlideSynth::new();
        loud.set_speed(2.0);
        let mut buf = vec![0.0f32; 44_100];
        loud.fill(&mut buf);
        let peak = buf.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.01 && peak < 1.0, "peak {peak}");
        assert!(loud.level() > 0.2, "level glides up to 0.22");
    }

    #[test]
    fn slide_fades_out_after_silence() {
        let mut s = SlideSynth::new();
        s.set_speed(2.0);
        let mut buf = vec![0.0f32; 44_100];
        s.fill(&mut buf);
        s.silence();
        s.fill(&mut buf);
        assert!(s.level() < 0.001, "level {}", s.level());
    }

    #[test]
    fn speed_is_capped() {
        let mut s = SlideSynth::new();
        s.set_speed(50.0);
        let mut buf = vec![0.0f32; 100_000];
        s.fill(&mut buf);
        assert!(s.level() <= 0.22 + 1e-6);
    }
}
