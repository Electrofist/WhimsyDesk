#!/usr/bin/env python3
"""Generates the fog sprite sequence and the asset catalog around it.

Output: Assets/Assets.xcassets/Fog/fog_00.imageset ... fog_39.imageset, each with
fog_NN.png (1x) and fog_NN@2x.png (2x), plus Contents.json files.

Frames are authored as straight alpha with a smoothly varying pale cyan color. PNG has no
premultiplied flag; Xcode's asset compiler (actool) stores catalog images premultiplied, and
the app draws them through Core Animation, which composites premultiplied. The script checks
that no pixel has color where alpha is zero, so there is no dark fringe either way.

Run: python3 tools/gen_fog.py   (needs numpy and Pillow)
"""
import json
import pathlib
import sys

import numpy as np
from PIL import Image

FRAMES = 40
W2, H2 = 512, 384          # 2x size. 1x is exactly half.
ROOT = pathlib.Path(__file__).resolve().parent.parent / "Assets" / "Assets.xcassets"


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def make_texture(size, seed):
    return np.random.default_rng(seed).random((size, size)).astype(np.float32)


def sample(tex, x, y):
    """Bilinear sample with smooth weights and wraparound. x, y in texture pixels."""
    h, w = tex.shape
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = x - x0
    fy = y - y0
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    x0 %= w
    y0 %= h
    x1 = (x0 + 1) % w
    y1 = (y0 + 1) % h
    a = tex[y0, x0] * (1 - fx) + tex[y0, x1] * fx
    b = tex[y1, x0] * (1 - fx) + tex[y1, x1] * fx
    return a * (1 - fy) + b * fy


TEXTURES = [make_texture(256, 100 + i) for i in range(6)]


def box_blur(a, r):
    """Separable box blur with edge clamping. Three passes approximate a gaussian."""
    if r < 1:
        return a
    k = 2 * r + 1
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (r + 1, r)
        c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
        if axis == 0:
            a = (c[k:, :] - c[:-k, :]) / k
        else:
            a = (c[:, k:] - c[:, :-k]) / k
        a = a.astype(np.float32)
    return a


def gaussish(a, r):
    for _ in range(3):
        a = box_blur(a, r)
    return a


def fbm(u, v, t):
    """Soft billows. Four octaves, each churning slowly in its own direction."""
    total = np.zeros_like(u)
    amp = 0.6
    norm = 0.0
    freq = 1.15
    for i, tex in enumerate(TEXTURES[:4]):
        ang = 1.7 * i + 0.4
        dx = 0.22 * np.cos(ang) * t * (1 + i)
        dy = 0.22 * np.sin(ang) * t * (1 + i)
        total += amp * sample(tex, (u * freq + dx) * 8.0, (v * freq + dy) * 8.0)
        norm += amp
        amp *= 0.5
        freq *= 2.0
    return total / norm


def frame(i):
    t = i / (FRAMES - 1)
    ys, xs = np.mgrid[0:H2, 0:W2].astype(np.float32)
    x = xs / (W2 - 1)
    y = ys / (H2 - 1)          # 0 top, 1 bottom

    ease = 1 - (1 - t) ** 2.2   # fast burst, slow spread

    # Advect the noise field: features grow outward from the center and sink downward,
    # so the cloud rolls out instead of sliding past a fixed window.
    spread = 1.0 / (1.0 + 1.1 * ease)
    nx = 0.5 + (x - 0.5) * spread
    ny = (y - 0.55 * ease) * spread + 0.2

    warp = fbm(nx * 0.8 + 3.1, ny * 0.8 + 1.7, t * 0.5)
    n = fbm(nx + (warp - 0.5) * 0.10, ny + (warp - 0.5) * 0.08, t)
    n = smoothstep(0.22, 0.80, n)

    # A cold plume sinks and spreads: an expanding ellipse whose center falls.
    cy = 0.16 + 0.34 * ease
    rx = 0.20 + 0.62 * ease
    ry = 0.14 + 0.32 * ease
    d = np.sqrt(((x - 0.5) / rx) ** 2 + ((y - cy) / ry) ** 2)
    plume = 1.0 - smoothstep(0.15, 1.0, d)

    # Fog also pools along the bottom and slides out sideways.
    side = 1.0 - smoothstep(0.0, 0.5, np.abs(x - 0.5) / (0.25 + 0.75 * ease))
    pool = (smoothstep(0.45, 0.88, y) * (1 - smoothstep(0.93, 1.0, y))
            * smoothstep(0.05, 0.45, t) * (0.35 + 0.65 * side))

    env = np.maximum(plume, pool * 0.9)
    env = gaussish(env, 14)

    # Time envelope: starts and ends at zero so the layer can pop in and out invisibly.
    life = smoothstep(0.0, 0.16, t) * (1.0 - smoothstep(0.42, 1.0, t)) ** 1.25

    density = np.clip(n * env, 0, 1)
    density = gaussish(density, 5)          # melt any remaining hard edges into vapor
    alpha = np.clip(density * life * 0.78, 0, 0.62)

    # Fade at the canvas edges so the sprite has no visible rectangle.
    edge = (smoothstep(0.0, 0.18, x) * smoothstep(0.0, 0.18, 1 - x)
            * smoothstep(0.0, 0.22, 1 - y) * smoothstep(0.0, 0.16, y))
    alpha *= edge

    # Color: pale cyan-white, slightly bluer where thin and whiter where dense.
    k = np.clip(density * 1.6, 0, 1)
    thin = np.array([0.70, 0.86, 0.97], dtype=np.float32)
    dense = np.array([0.95, 0.985, 1.0], dtype=np.float32)
    rgb = thin[None, None, :] * (1 - k[..., None]) + dense[None, None, :] * k[..., None]
    return rgb.astype(np.float32), alpha.astype(np.float32)


def downsample_premultiplied(rgb, alpha):
    """2x2 box filter in premultiplied space, so edges do not pick up dark or light fringes."""
    pm = rgb * alpha[..., None]
    h, w = alpha.shape
    pm = pm.reshape(h // 2, 2, w // 2, 2, 3).mean(axis=(1, 3))
    a = alpha.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
    safe = np.maximum(a, 1e-6)
    straight = pm / safe[..., None]
    straight[a < 1e-6] = 0.0
    return straight, a


def to_png(rgb, alpha, path):
    a8 = np.clip(np.rint(alpha * 255), 0, 255).astype(np.uint8)
    c8 = np.clip(np.rint(rgb * 255), 0, 255).astype(np.uint8)
    c8[a8 == 0] = 0                       # no color where fully transparent
    img = np.dstack([c8, a8])
    Image.fromarray(img, "RGBA").save(path, optimize=True)


def check_no_fringe(path):
    arr = np.asarray(Image.open(path).convert("RGBA"))
    bad = ((arr[..., 3] == 0) & (arr[..., :3].sum(axis=-1) != 0)).sum()
    if bad:
        raise SystemExit(f"{path}: {bad} pixels carry color at zero alpha")


def contents_json(i):
    name = f"fog_{i:02d}"
    return {
        "images": [
            {"filename": f"{name}.png", "idiom": "universal", "scale": "1x"},
            {"filename": f"{name}@2x.png", "idiom": "universal", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }


def main():
    fog_dir = ROOT / "Fog"
    fog_dir.mkdir(parents=True, exist_ok=True)
    (ROOT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    (fog_dir / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))

    total = 0
    for i in range(FRAMES):
        rgb, alpha = frame(i)
        name = f"fog_{i:02d}"
        d = fog_dir / f"{name}.imageset"
        d.mkdir(exist_ok=True)
        p2 = d / f"{name}@2x.png"
        p1 = d / f"{name}.png"
        to_png(rgb, alpha, p2)
        rgb1, a1 = downsample_premultiplied(rgb, alpha)
        to_png(rgb1, a1, p1)
        (d / "Contents.json").write_text(json.dumps(contents_json(i), indent=2))
        check_no_fringe(p1)
        check_no_fringe(p2)
        total += p1.stat().st_size + p2.stat().st_size
        peak = float(alpha.max())
        print(f"{name}: peak alpha {peak:.2f}", file=sys.stderr if i % 8 else sys.stdout)
    print(f"wrote {FRAMES} frames, {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
