// Make your own and the footer. library.js still runs the page: it opens the crate, reads the dropped
// pictures and copies commands. This file switches the steps between the three ways of building and paints
// the footer: the page's white crumbles into a pixel dusk, the same way the hero's sky meets the page.

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const narrow = matchMedia('(max-width: 720px)');

/* ---------- How you build it ---------- */
function setPath(p) {
  $$('#make [data-for]').forEach(el => el.hidden = el.dataset.for !== p);
}
$$('#mk-paths input').forEach(r => r.addEventListener('change', () => { if (r.checked) setPath(r.value); }));
setPath($('#mk-paths input:checked')?.value || 'phoenix');

/* ---------- The footer ---------- */
const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map(v => v / 16 - 0.5);
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const SKY = ['#15180b', '#1b1f0f', '#222612', '#2b2d14', '#393516', '#4d4119', '#6a521f', '#8c6627', '#b07d33', '#d0963f'].map(hex);
const HILL_BACK = ['#2c2f16', '#33361a', '#3b3d1c'].map(hex);
const HILL_FRONT = ['#181b0c', '#1d2110', '#232713'].map(hex);
function rand(seed) { let s = seed >>> 0; return () => ((s = Math.imul(s ^ (s >>> 15), 2246822507) + 0x6d2b79f5 >>> 0) / 4294967296); }
function hash(x, y) {
  let h = x * 374761393 + y * 668265263;
  h = (h ^ (h >>> 13)) * 1274126177;
  return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
}
function noise(x, y) {
  const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
  const s = t => t * t * (3 - 2 * t);
  const a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1);
  return a + (b - a) * s(xf) + (c - a) * s(yf) + (a - b - c + d) * s(xf) * s(yf);
}
function paperRGB() {
  const m = getComputedStyle(document.documentElement).getPropertyValue('--paper').trim().match(/^#([0-9a-f]{6})$/i);
  return m ? [0, 2, 4].map(i => parseInt(m[1].slice(i, i + 2), 16)) : [255, 255, 255];
}

function paintDusk() {
  const c = $('#dk-dusk-wall');
  if (!c) return;
  const small = narrow.matches;
  const box = c.parentElement, P = 4;
  const W = Math.ceil(box.offsetWidth / P), H = Math.ceil(box.offsetHeight / P);
  if (!W || !H) return;
  c.width = W; c.height = H;
  const ctx = c.getContext('2d'), img = ctx.createImageData(W, H), d = img.data, r = rand(7);

  // The dusk: sky, sun glow, two hills. The hills sit just above the footer links.
  const ground = $('#dk-ground');
  const horizon = ground ? (ground.offsetTop - (small ? 120 : 170)) / P : H * 0.6;
  const sunX = W * 0.68, k = 7 / 5;
  const back = x => horizon - k * (3 + 4 * Math.sin(x * 0.045 / k + 1) + 2 * Math.sin(x * 0.11 / k));
  const front = x => horizon + 110 / P - k * (3 * Math.sin(x * 0.03 / k + 2.2) + 2 * Math.sin(x * 0.09 / k + .5));
  const top = (small ? 170 : 250) / P;           // stars only below the crumbling edge
  const stars = new Set();
  for (let i = 0; i < W * H * 0.0009; i++) stars.add(Math.floor(r() * W) + Math.floor(top + r() * (horizon * 0.55 - top)) * W);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const dth = bayer[(y % 4) * 4 + (x % 4)];
    let col;
    if (y > front(x)) col = HILL_FRONT[Math.max(0, Math.min(2, Math.round(1 - (y - front(x)) / (14 * k) + dth)))];
    else if (y > back(x)) col = HILL_BACK[Math.max(0, Math.min(2, Math.round(2 - (y - back(x)) / (6 * k) + dth)))];
    else {
      const t = Math.max(0, y / horizon);
      const glow = Math.exp(-(((x - sunX) / (W * 0.32)) ** 2) - (((y - horizon) / (H * 0.28)) ** 2));
      const f = t ** 2.2 * 0.58 + glow * 0.34 + dth * 0.14;
      col = SKY[Math.max(0, Math.min(SKY.length - 1, Math.round(f * (SKY.length - 1))))];
      if (stars.has(y * W + x) && f < 0.3) col = [222, 219, 190];
    }
    const i = (y * W + x) * 4;
    d[i] = col[0]; d[i + 1] = col[1]; d[i + 2] = col[2]; d[i + 3] = 255;
  }

  // The edge: blocks of page white eat into the dusk, big blocks of flat colour sit where they meet,
  // and a few small crumbs of dusk drift up into the white. Same recipe as the hero's sky.
  const E = small ? 2 : 3;                       // a small block, in canvas pixels (8 or 12 px)
  const crumbs = (small ? 56 : 90) / P;          // all white, a few crumbs
  const zone = (small ? 170 : 250) / P;          // where white and dusk meet
  const cols = Math.ceil(W / E / 2) * 2, rows = Math.ceil((crumbs + zone) / E / 2) * 2;
  const PAPER = paperRGB();
  const at = (x, y) => { const i = (Math.min(H - 1, Math.max(0, y)) * W + Math.min(W - 1, Math.max(0, x))) * 4; return [d[i], d[i + 1], d[i + 2]]; };
  const avg = (x0, y0, n) => {
    let R = 0, G = 0, B = 0, c2 = 0;
    for (let y = y0; y < y0 + n; y++) for (let x = x0; x < x0 + n; x++) { const p = at(x, y); R += p[0]; G += p[1]; B += p[2]; c2++; }
    return [R / c2, G / c2, B / c2].map(Math.round);
  };
  // 0 dusk as painted, 1 big flat block, 2 small crumb, 3 white.
  const mode = new Uint8Array(cols * rows), seed = Math.random() * 100;
  for (let Y = 0; Y < rows / 2; Y++) for (let X = 0; X < cols / 2; X++) {
    const py = (Y * 2 + 1) * E;
    const t = (py - crumbs) / zone;
    const v = 1 - t + (noise(X * .17 + seed, Y * .17) - .5) * 1.1;
    const m = py < crumbs || v > .74 ? 3 : v > .3 ? 1 : 0;
    for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) mode[(Y * 2 + dy) * cols + X * 2 + dx] = m;
  }
  const was = mode.slice();
  const nb = (x, y) => (x < 0 || y < 0 || x >= cols || y >= rows) ? 0 : was[y * cols + x];
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const i = y * cols + x, py = (y + .5) * E, h = hash(x + 3, y + 5);
    if (was[i] === 3 && py < crumbs) mode[i] = h < .05 * (py / crumbs) ? 2 : 3;
    else if (was[i] === 3 && [nb(x, y + 1), nb(x - 1, y), nb(x + 1, y)].includes(1)) mode[i] = h < .32 ? 2 : 3;
    else if (was[i] === 1 && [nb(x, y - 1), nb(x - 1, y), nb(x + 1, y)].includes(3)) mode[i] = h < .2 ? 3 : 1;
  }
  const fill = (x0, y0, n, col) => {
    for (let y = y0; y < Math.min(H, y0 + n); y++) for (let x = x0; x < Math.min(W, x0 + n); x++) {
      const i = (y * W + x) * 4; d[i] = col[0]; d[i + 1] = col[1]; d[i + 2] = col[2];
    }
  };
  const bigCol = new Map();
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const m = mode[y * cols + x];
    if (!m) continue;
    let col = PAPER;
    if (m === 1) {
      const key = (y >> 1) * cols + (x >> 1);
      if (!bigCol.has(key)) bigCol.set(key, avg((x >> 1) * 2 * E, (y >> 1) * 2 * E, 2 * E));
      col = bigCol.get(key);
    } else if (m === 2) {
      col = avg(x * E, Math.round(crumbs + zone * .6) + (hash(x, y) * 6 | 0) * E, E);   // a crumb carries the dusk's colour up
    }
    fill(x * E, y * E, E, col);
  }
  ctx.putImageData(img, 0, 0);
}
paintDusk();
let resizeT = 0, lastW = innerWidth;
addEventListener('resize', () => {
  if (innerWidth === lastW) return;
  lastW = innerWidth;
  clearTimeout(resizeT);
  resizeT = setTimeout(paintDusk, 150);
});
// Repaint when the footer changes height.
const dusk = $('.dk-dusk');
if (dusk) new ResizeObserver(() => { clearTimeout(resizeT); resizeT = setTimeout(paintDusk, 120); }).observe(dusk);
