#!/usr/bin/env python3
"""Synthesizes the two one-shot sounds. No loops, no hum.

Assets/Sounds/open_click.wav : a soft, light latch click when the door starts to open.
Assets/Sounds/seal_click.wav : a gentle magnetic seal when the door closes fully.

Run: python3 tools/gen_sounds.py   (needs numpy)
"""
import pathlib
import wave

import numpy as np

SR = 44100
OUT = pathlib.Path(__file__).resolve().parent.parent / "Assets" / "Sounds"


def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def lowpass(x, cutoff):
    """One-pole low-pass, enough to soften noise bursts."""
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def ring(freq, decay, seconds, phase=0.0):
    t = t_axis(seconds)
    return np.sin(2 * np.pi * freq * t + phase) * np.exp(-t * decay)


def fade(x, in_ms=1.0, out_ms=12.0):
    n_in = max(1, int(SR * in_ms / 1000))
    n_out = max(1, int(SR * out_ms / 1000))
    x = x.copy()
    x[:n_in] *= np.linspace(0, 1, n_in)
    x[-n_out:] *= np.linspace(1, 0, n_out)
    return x


def normalize(x, peak_db):
    peak = 10 ** (peak_db / 20)
    return x / max(np.abs(x).max(), 1e-9) * peak


def write_wav(path, x):
    pcm = np.clip(x, -1, 1)
    pcm = (pcm * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def open_click():
    rng = np.random.default_rng(3)
    n = int(SR * 0.09)
    tick_noise = highpass(lowpass(rng.standard_normal(n), 5200), 1800)
    tick_noise *= np.exp(-t_axis(0.09) * 260)
    body = ring(1450, 90, 0.09) * 0.6 + ring(2300, 140, 0.09) * 0.25
    x = tick_noise * 0.9 + body
    return normalize(fade(x, 0.5, 20), -10)


def seal_click():
    rng = np.random.default_rng(11)
    n = int(SR * 0.22)
    thump = ring(118, 26, 0.22) * 1.0 + ring(176, 40, 0.22) * 0.35
    thump *= np.minimum(1.0, t_axis(0.22) / 0.002)           # 2 ms attack, no click from a hard start
    rubber = highpass(lowpass(rng.standard_normal(n), 3200), 700)
    rubber *= np.exp(-t_axis(0.22) * 120)
    # The magnet "kiss": a tiny second tick a few ms after the thump.
    kiss = np.zeros(n)
    k = int(SR * 0.014)
    tick = highpass(lowpass(rng.standard_normal(int(SR * 0.03)), 4200), 1500) * np.exp(-t_axis(0.03) * 230)
    kiss[k:k + len(tick)] += tick * 0.5
    x = thump * 0.9 + rubber * 0.35 + kiss
    return normalize(fade(x, 0.5, 40), -9)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in (("open_click.wav", open_click()), ("seal_click.wav", seal_click())):
        write_wav(OUT / name, data)
        print(f"{name}: {len(data) / SR * 1000:.0f} ms, peak {np.abs(data).max():.2f}")


if __name__ == "__main__":
    main()
