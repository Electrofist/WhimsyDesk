import letters from './letters.js';

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
// The page colour, read from CSS so the pixel edge always matches the page behind it.
function paperRGB() {
  const m = getComputedStyle(document.documentElement).getPropertyValue('--paper').trim().match(/^#([0-9a-f]{6})$/i);
  return m ? [0, 2, 4].map(i => parseInt(m[1].slice(i, i + 2), 16)) : [247, 245, 238];
}
let PAPER = paperRGB();

/* ---------- Small noise helpers ---------- */
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
const bayer = [
  0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
  3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
].map(v => v / 64 - 0.5);
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const shade = (h, k) => `rgb(${hex(h).map(v => Math.round(v * k)).join(',')})`;

/* ---------- Torn paper ---------- */
// The hero sheet: a jagged bottom edge, a little different on every visit.
function tear() {
  const paper = $('#paper');
  const w = paper.offsetWidth, h = paper.offsetHeight;
  const room = 70;
  const pts = [], rim = [];
  let y = 0, x = 0;
  while (x <= w + 20) {
    y += (Math.random() - 0.5) * 9;
    y = clamp(y * 0.96, -room / 2, room / 2);
    pts.push([x, h - room / 2 + y - Math.random() * 5]);
    rim.push([x, h - room / 2 + y + 4 + Math.random() * 4]);
    x += 6 + Math.random() * 10;
  }
  const poly = arr => `polygon(0 0, ${w}px 0, ${arr.slice().reverse().map(([a, b]) => `${a.toFixed(1)}px ${b.toFixed(1)}px`).join(', ')})`;
  paper.style.setProperty('--tear', poly(pts));
  paper.style.setProperty('--tear-rim', poly(rim));
}

// A scrap torn on all four sides. The face sits a little inside the white rim.
function tornRect(w, h, inset) {
  const out = [];
  const edge = (x0, y0, x1, y1, nx, ny) => {
    const len = Math.hypot(x1 - x0, y1 - y0);
    let d = 0, wander = 0;
    while (d < len) {
      const t = d / len;
      wander = clamp(wander * 0.9 + (Math.random() - 0.5) * 2.6, -3, 3);
      const k = inset + 3 + wander + Math.random() * 2.2;
      out.push([x0 + (x1 - x0) * t + nx * k, y0 + (y1 - y0) * t + ny * k]);
      d += 5 + Math.random() * 9;
    }
  };
  edge(0, 0, w, 0, 0, 1);
  edge(w, 0, w, h, -1, 0);
  edge(w, h, 0, h, 0, -1);
  edge(0, h, 0, 0, 1, 0);
  return `polygon(${out.map(([a, b]) => `${a.toFixed(1)}px ${b.toFixed(1)}px`).join(',')})`;
}
const scrapObserver = new ResizeObserver(entries => entries.forEach(({ target: el }) => {
  const w = el.offsetWidth, h = el.offsetHeight;
  el.style.setProperty('--torn', tornRect(w, h, 3));
  el.style.setProperty('--torn-rim', tornRect(w, h, 0));
}));
$$('.scrap').forEach(el => scrapObserver.observe(el));
export { tornRect };

/* ---------- Cross-stitch and pixel art ---------- */
const colours = {
  g: '#5a8f3e', G: '#3f6e2e', y: '#f2c230', Y: '#e39a1f', b: '#7a4a25', B: '#4a2c17', p: '#7d55a8', P: '#a888cf',
  r: '#cf3b2c', R: '#9e2a20', w: '#fbf8f0', k: '#d98a3a', K: '#a85f22', n: '#2d2a26', c: '#f4e3b5', m: '#e88fa0',
  s: '#a9cbe6', S: '#8db8de', t: '#c99a5e', T: '#8d6638', o: '#ec7a2c', h: '#fbf3dc', l: '#7fb0d8', L: '#4f86b8', e: '#7aa36a', E: '#55844a', f: '#3f6e3a',
};
const motifs = {
  violets: ['............', '..PP....pp..', '.PppP..pPPp.', '.pPyp..pyPp.', '..pP....Pp..', '...g.....g..', '...g....g...', '....g..g....', '..GG.gg.GG..', '...GGggGG...', '....GggG....', '............'],
  jam: ['............', '...tttttt...', '...TTTTTT...', '..wwwwwwww..', '..wRrrrrRw..', '..wrrrrrrw..', '..wrcccrrw..', '..wrcccrrw..', '..wrrrrrrw..', '..wRrrrrRw..', '...wwwwww...', '............'],
  cat: ['............', '.K.......K..', '.kK.....Kk..', '.kkkkkkkkk..', '.kkwnkkwnkk.', '.kkkkmkkkkk.', '..kkkkkkkk..', '...kkkkkk...', '..kkkkkkkk.K', '..kkKkkKkkK.', '..kkkkkkkk..', '..KK....KK..'],
  teacup: ['............', '....w.w.....', '.....w.w....', '....w.w.....', '............', '.rrrrrrrr...', '.rwwwwwwrrr.', '.rwrrrrwr.r.', '.rwwwwwwrrr.', '..rwwwwr....', 'GGGGGGGGGG..', '............'],
  sun: ['............', '.....y......', '.y...y...y..', '..y.....y...', '....yyy.....', '...yYYYy....', 'yy.yYYYy.yy.', '...yYYYy....', '....yyy.....', '..y.....y...', '.y...y...y..', '.....y......'],
  hen: ['............', '......rr....', '.....www....', '....wwnwo...', '....wwww....', '..w.wwww....', '.wwwwwwww...', '.wwcwwwww...', '..wwwwww....', '...wwww.....', '....o.o.....', '...oo.oo....'],
  sunflower: ['............', '...y.yy.y...', '..yyyyyyyy..', '.yyyBBBByyy.', '..yBbbbbBy..', '.yyBbbbbByy.', '..yBbbbbBy..', '.yyyBBBByyy.', '..yyyyyyyy..', '...y.gy.y...', '..GG.g.GG...', '.....g......'],
};
const photo = ['SSSSSSSSSSSyyS', 'SSSSSSSSSSyyyy', 'SSwwwSSSSSSyyS', 'SwwwwwSSSSSSSS', 'ssssssssswwsss', 'sssssssswwwwss', 'sssEEssssssff', 'ssEeeEsssssfff', 'eeeeeeeeeeeefe', 'EeeeeerrreeeEe', 'EEeeeehhhEEEEE', 'llllllllllllll', 'LlLLLlLLLLlLLL'];

function crossStitch(rows) {
  let s = '';
  rows.forEach((row, y) => [...row].forEach((ch, x) => {
    const c = colours[ch];
    if (!c) return;
    s += `<path d="M${x + .18} ${y + .18}L${x + .82} ${y + .82}" stroke="${shade(c, .82)}"/><path d="M${x + .82} ${y + .18}L${x + .18} ${y + .82}" stroke="${c}"/>`;
  }));
  return `<svg viewBox="0 0 ${rows[0].length} ${rows.length}" stroke-width=".3" stroke-linecap="round">${s}</svg>`;
}
function pixels(rows, w, h) {
  const cw = w / rows[0].length, ch = h / rows.length;
  let s = '';
  rows.forEach((row, y) => [...row].forEach((k, x) => {
    if (colours[k]) s += `<rect x="${(x * cw).toFixed(2)}" y="${(y * ch).toFixed(2)}" width="${(cw + .3).toFixed(2)}" height="${(ch + .3).toFixed(2)}" fill="${colours[k]}"/>`;
  }));
  return s;
}
const pixelPhoto = $('.pixel-photo');
if (pixelPhoto) pixelPhoto.innerHTML = pixels(photo, 148, 142);

/* ---------- Loose files on the hero page ---------- */
const loose = $$('.loose__item').map((el, i) => ({ el, name: el.dataset.name, x: 0, y: 0, vx: 0, vy: 0, rot: 0, base: 0, w: 0, h: 0, held: false, i }));
const looseLayouts = {
  // Wide: two on each side of the text, sized to the margin.
  wide: { folder: ['l', .5, 140, 236, -12], photo: ['l', .72, 312, 166, 8], pdf: ['r', .42, 112, 162, 11], tape: ['r', .64, 330, 226, -8] },
  // Narrow: two peeking in from the top corners, the rest put away.
  narrow: { folder: ['x', -30, 72, 118, -14], pdf: ['xr', -24, 70, 90, 12] },
};
let heroW = 0, heroH = 0, looseLoop = 0, zTop = 10;

function placeLoose() {
  const hero = $('#hero');
  heroW = hero.offsetWidth; heroH = hero.offsetHeight;
  const wide = heroW >= 1100;
  const cfg = wide ? looseLayouts.wide : looseLayouts.narrow;
  const gutter = (heroW - 660) / 2;
  loose.forEach(it => {
    const c = cfg[it.name];
    it.el.style.display = c ? '' : 'none';
    if (!c) return;
    const [side, f, y, base, r] = c;
    const scale = wide ? 1 : clamp(heroW / 600, .75, 1.05);
    const looseScale = +($('#loose').dataset.scale || 1);   // a page can ask for smaller loose files
    it.w = (wide ? Math.min(base, gutter * .86) : base * scale) * looseScale;
    it.el.style.setProperty('--w', it.w + 'px');
    it.el.style.setProperty('--delay', -it.i * 1.7 + 's');
    it.h = it.el.offsetHeight || it.w;
    if (side === 'l') it.x = gutter * f - it.w / 2;
    else if (side === 'r') it.x = heroW - gutter * f - it.w / 2;
    else if (side === 'x') it.x = f;
    else it.x = heroW - it.w - f;
    it.y = y;
    it.vx = it.vy = 0;
    it.base = it.rot = r;
    draw(it);
  });
}
const draw = it => { it.el.style.transform = `translate3d(${it.x.toFixed(1)}px,${it.y.toFixed(1)}px,0) rotate(${it.rot.toFixed(2)}deg)`; };

function stepLoose() {
  let busy = false;
  loose.forEach(it => {
    if (it.el.style.display === 'none') return;
    if (!it.held) {
      it.x += it.vx; it.y += it.vy;
      it.vx *= 0.91; it.vy *= 0.91;
      const minX = -it.w * .45, maxX = heroW - it.w * .55, minY = 60, maxY = heroH - it.h * .7;
      if (it.x < minX) { it.x = minX; it.vx = -it.vx * .45; }
      if (it.x > maxX) { it.x = maxX; it.vx = -it.vx * .45; }
      if (it.y < minY) { it.y = minY; it.vy = -it.vy * .45; }
      if (it.y > maxY) { it.y = maxY; it.vy = -it.vy * .45; }
    }
    // Lean into the motion, then settle back to its resting angle.
    const target = it.base + clamp(it.vx * 1.4, -16, 16);
    it.rot += (target - it.rot) * 0.14;
    draw(it);
    if (it.held || Math.abs(it.vx) + Math.abs(it.vy) > .05 || Math.abs(target - it.rot) > .05) busy = true;
  });
  looseLoop = busy ? requestAnimationFrame(stepLoose) : 0;
}
const wakeLoose = () => { if (!looseLoop) looseLoop = requestAnimationFrame(stepLoose); };

loose.forEach(it => {
  let grab = null;
  it.el.addEventListener('pointerdown', e => {
    it.el.setPointerCapture(e.pointerId);
    it.held = true;
    it.el.classList.add('is-held');
    it.el.style.zIndex = ++zTop;
    grab = { dx: e.clientX - it.x, dy: e.clientY - it.y, t: performance.now() };
    it.vx = it.vy = 0;
    wakeLoose();
  });
  it.el.addEventListener('pointermove', e => {
    if (!grab) return;
    const now = performance.now(), dt = Math.max(8, now - grab.t);
    const nx = e.clientX - grab.dx, ny = e.clientY - grab.dy;
    // Velocity per frame, smoothed, so a flick carries on after release.
    it.vx = it.vx * .5 + (nx - it.x) / dt * 16 * .5;
    it.vy = it.vy * .5 + (ny - it.y) / dt * 16 * .5;
    it.x = nx; it.y = ny; grab.t = now;
  });
  const drop = () => {
    if (!grab) return;
    grab = null;
    it.held = false;
    it.el.classList.remove('is-held');
    if (reduce) it.vx = it.vy = 0;
    wakeLoose();
  };
  it.el.addEventListener('pointerup', drop);
  it.el.addEventListener('pointercancel', drop);
});

/* ---------- The painted sky, breaking into pixels ---------- */
// A separate, fully decoded copy of the painting for drawing into canvases. Safari can report
// the page's own image as complete before it is decoded, and then the canvases come out black.
const skyImg = new Image();
let skyReady = false;
skyImg.src = 'media/sky-1200.webp';
skyImg.decode().then(() => { skyReady = true; paintSkyPixels(); paintWallpaper(); }).catch(() => {});
// Match the CSS filter on the painting: saturate(1.35) brightness(1.04).
function grade(r, g, b) {
  const k = 1.35, l = 1.04;
  return [
    ((.213 + .787 * k) * r + (.715 - .715 * k) * g + (.072 - .072 * k) * b) * l,
    ((.213 - .213 * k) * r + (.715 + .285 * k) * g + (.072 - .072 * k) * b) * l,
    ((.213 - .213 * k) * r + (.715 - .715 * k) * g + (.072 + .928 * k) * b) * l,
  ].map(v => clamp(Math.round(v), 0, 255));
}
function paintSkyPixels() {
  const sky = $('#sky'), canvas = $('#sky-pixels');
  if (!skyReady) return;
  PAPER = paperRGB();
  const W = sky.offsetWidth, H = sky.offsetHeight;
  const B = W < 720 ? 8 : 12;                 // a small block; big blocks are twice the size
  const below = W < 720 ? 56 : 96;            // a few crumbs fall below the sky
  const zone = Math.min(W < 720 ? 170 : 240, H * .45);
  const cols = Math.ceil(W / B / 2) * 2, rows = Math.ceil((H + below) / B / 2) * 2, skyRows = Math.ceil(H / B);
  canvas.width = cols; canvas.height = rows;
  canvas.style.width = cols * B + 'px';
  canvas.style.height = rows * B + 'px';

  // The painting as shown (object-fit: cover, 50% 30%), averaged into small and big blocks.
  const iw = skyImg.naturalWidth, ih = skyImg.naturalHeight, k = Math.max(W / iw, H / ih);
  const dw = iw * k, dh = ih * k, ox = (W - dw) * .5, oy = (H - dh) * .3;
  const sample = n => {
    const c = document.createElement('canvas'), cw = Math.ceil(cols / n), ch = Math.ceil(skyRows / n);
    c.width = cw; c.height = ch;
    const x = c.getContext('2d');
    x.imageSmoothingQuality = 'high';
    x.drawImage(skyImg, ox / (B * n), oy / (B * n), dw / (B * n), dh / (B * n));
    return { d: x.getImageData(0, 0, cw, ch).data, cw, ch };
  };
  const small = sample(1), big = sample(2);

  // 0 clear, 1 big painted block, 2 small painted block, 3 paper.
  const mode = new Uint8Array(cols * rows);
  const seed = Math.random() * 100;
  for (let Y = 0; Y < rows / 2; Y++) for (let X = 0; X < cols / 2; X++) {
    const py = (Y * 2 + 1) * B;
    const t = (py - (H - zone)) / zone;
    if (t < -.35) continue;
    const v = t + (noise(X * .17 + seed, Y * .17) - .5) * .85;
    const m = py > H || v > .74 ? 3 : v > .3 ? 1 : 0;
    for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) mode[(Y * 2 + dy) * cols + X * 2 + dx] = m;
  }
  // Crumbs where paint meets paper, and a few strays below.
  const was = mode.slice();
  const at = (x, y) => (x < 0 || y < 0 || x >= cols || y >= rows) ? 0 : was[y * cols + x];
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const i = y * cols + x, py = (y + .5) * B, h = hash(x + 3, y + 5);
    if (was[i] === 3 && py > H) mode[i] = h < .045 * (1 - (py - H) / below) ? 2 : 3;
    else if (was[i] === 3 && [at(x, y - 1), at(x - 1, y), at(x + 1, y)].includes(1)) mode[i] = h < .32 ? 2 : 3;
    else if (was[i] === 1 && [at(x, y + 1), at(x - 1, y), at(x + 1, y)].includes(3)) mode[i] = h < .2 ? 3 : 1;
  }

  const ctx = canvas.getContext('2d');
  const out = ctx.createImageData(cols, rows);
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
    const m = mode[y * cols + x];
    if (!m) continue;
    let rgb = PAPER;
    if (m === 1) {
      const j = (Math.min(y >> 1, big.ch - 1) * big.cw + (x >> 1)) * 4;
      rgb = grade(big.d[j], big.d[j + 1], big.d[j + 2]);
    } else if (m === 2) {
      const sy = Math.min(y, skyRows - 1) - ((y + .5) * B > H ? 2 + (hash(x, y) * 8 | 0) : 0);
      const j = (Math.max(0, sy) * small.cw + x) * 4;
      rgb = grade(small.d[j], small.d[j + 1], small.d[j + 2]);
    } else if (y * B >= H) continue;   // below the sky the page itself is the paper; the last row straddling the edge is still covered
    const i = (y * cols + x) * 4;
    out.data[i] = rgb[0]; out.data[i + 1] = rgb[1]; out.data[i + 2] = rgb[2]; out.data[i + 3] = 255;
  }
  ctx.putImageData(out, 0, 0);
}

/* ---------- The desktop ---------- */
const files = [
  { id: 'tax', name: 'Tax return 2025.pdf', kind: 'pdf' },
  { id: 'shot', name: 'Screenshot at 4.12 PM.png', kind: 'png' },
  { id: 'folder', name: 'Old projects', kind: 'folder' },
  { id: 'notes', name: 'notes.txt', kind: 'txt' },
];
const layouts = {
  wide: { dw: 1080, dh: 560, fh: 380, fridge: [800, 112], note: [470, 120],
    files: [[44, 50], [44, 160], [44, 280], [150, 50]] },
  narrow: { dw: 420, dh: 520, fh: 290, fridge: [222, 196], note: [36, 300],
    files: [[18, 44], [118, 44], [218, 44], [318, 44]] },
};
// Where stored files sit on the fridge's shelves, in the open picture's own pixels.
const slots = [[248, 440], [306, 440], [364, 440], [210, 108], [272, 108], [334, 108]];

const icons = {
  pdf: '<svg viewBox="0 0 56 64"><path d="M6 2h30l14 14v44a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z" fill="#fff"/><path d="M36 2v12a2 2 0 0 0 2 2h12" fill="#e6e6e3"/><rect x="4" y="40" width="46" height="13" fill="#e2483d"/><text x="27" y="50" font-size="9" font-family="-apple-system,sans-serif" font-weight="700" fill="#fff" text-anchor="middle">PDF</text><g fill="#c9cac5"><rect x="12" y="20" width="26" height="2.4" rx="1"/><rect x="12" y="26" width="30" height="2.4" rx="1"/><rect x="12" y="32" width="20" height="2.4" rx="1"/></g></svg>',
  png: '<svg viewBox="0 0 56 64"><path d="M6 2h30l14 14v44a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z" fill="#fff"/><path d="M36 2v12a2 2 0 0 0 2 2h12" fill="#e6e6e3"/><rect x="10" y="20" width="34" height="26" rx="2" fill="#bcd6ee"/><path d="M10 40l10-9 7 6 6-5 11 9v5H10z" fill="#5b8f5a"/><circle cx="35" cy="27" r="3.5" fill="#f7d26a"/></svg>',
  folder: '<svg viewBox="0 0 56 64"><path d="M2 16a3 3 0 0 1 3-3h15l5 5h26a3 3 0 0 1 3 3v31a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3z" fill="#5aa6e6"/><path d="M2 24a3 3 0 0 1 3-3h46a3 3 0 0 1 3 3v28a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3z" fill="#77bbf2"/></svg>',
  txt: '<svg viewBox="0 0 56 64"><path d="M6 2h30l14 14v44a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z" fill="#fff"/><path d="M36 2v12a2 2 0 0 0 2 2h12" fill="#e6e6e3"/><g fill="#9a9c96"><rect x="11" y="20" width="30" height="2.2" rx="1"/><rect x="11" y="26" width="33" height="2.2" rx="1"/><rect x="11" y="32" width="26" height="2.2" rx="1"/><rect x="11" y="38" width="31" height="2.2" rx="1"/><rect x="11" y="44" width="18" height="2.2" rx="1"/></g></svg>',
};

const screen = $('#screen'), wrap = $('#screen-wrap'), fridge = $('#fridge'), shelf = $('#shelf');
let L = layouts.wide, S = 1;
const state = new Map(files.map(f => [f.id, { stored: false, el: null, shelfEl: null, x: 0, y: 0 }]));

function buildFiles() {
  const holder = $('#files');
  files.forEach(f => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'file';
    b.innerHTML = icons[f.kind] + `<span>${f.name}</span>`;
    b.setAttribute('aria-label', `${f.name}. Press to put it in the fridge.`);
    holder.appendChild(b);
    state.get(f.id).el = b;
    enableDrag(b, f);

    const s = document.createElement('button');
    s.type = 'button';
    s.className = 'stored';
    s.innerHTML = icons[f.kind];
    s.tabIndex = -1;
    s.setAttribute('aria-label', `${f.name}, in the fridge. Press to put it back on the desktop.`);
    s.addEventListener('click', e => {
      e.stopPropagation();
      if (s.dataset.dragged) { delete s.dataset.dragged; return; }   // that was a drag, not a tap
      putBack(f);
    });
    shelf.appendChild(s);
    state.get(f.id).shelfEl = s;
    enablePullOut(s, f);
  });
}

// Drag a file off the shelf and out of the fridge: it lands on the desktop where you let go.
// Let go over the fridge again and it goes back in. A tap still puts it back where it came from.
function enablePullOut(s, f) {
  let start = null;
  s.addEventListener('pointerdown', e => {
    if (!fridge.classList.contains('is-open')) return;
    start = { px: e.clientX, py: e.clientY, out: false };
    s.setPointerCapture(e.pointerId);
  });
  s.addEventListener('pointermove', e => {
    if (!start) return;
    const st = state.get(f.id), el = st.el;
    if (!start.out) {
      if (Math.hypot(e.clientX - start.px, e.clientY - start.py) < 6) return;
      start.out = true;
      s.dataset.dragged = '1';
      st.stored = false;
      delete s.dataset.full;
      el.classList.remove('is-stored');
      el.classList.add('is-dragging');
      s.style.opacity = '0';   // hidden but still holding the pointer; the shelf closes up on release
    }
    // Follow the pointer, in the desktop's own unscaled pixels.
    const r = screen.getBoundingClientRect();
    el.style.left = (e.clientX - r.left) / S - el.offsetWidth / 2 + 'px';
    el.style.top = (e.clientY - r.top) / S - 34 + 'px';
    clearTimeout(closeTimer);
    fridge.classList.toggle('is-near', inside(e.clientX, e.clientY, fridgeRect()));
  });
  const end = e => {
    if (!start) return;
    const out = start.out; start = null;
    if (!out) return;
    const st = state.get(f.id), el = st.el;
    el.classList.remove('is-dragging');
    fridge.classList.remove('is-near');
    s.style.opacity = '';
    relayoutShelf();
    if (e.type !== 'pointercancel' && inside(e.clientX, e.clientY, fridgeRect())) { store(f); return; }
    if (e.type === 'pointercancel') { place(el, [st.x, st.y]); }
    else {
      // Keep it on the desktop.
      const x = parseFloat(el.style.left), y = parseFloat(el.style.top);
      st.x = clamp(x, 0, L.dw - el.offsetWidth); st.y = clamp(y, 30, L.dh - 90);
      place(el, [st.x, st.y]);
    }
    update();
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => setOpen(false), reduce ? 300 : 700);
  };
  s.addEventListener('pointerup', end);
  s.addEventListener('pointercancel', end);
}

// The desktop wallpaper: the same sky, as the computer would draw it, in a few dithered blues.
const wallPalette = ['#1f3149', '#2a4362', '#36577e', '#4b6f98', '#6a8db3', '#98b2cc'].map(hex);
function paintWallpaper() {
  if (!skyReady) return;
  const c = $('#wallpaper'), P = 4;
  const W = Math.ceil(L.dw / P), H = Math.ceil(L.dh / P);
  c.width = W; c.height = H;
  const ctx = c.getContext('2d');
  const iw = skyImg.naturalWidth, ih = skyImg.naturalHeight, k = Math.max(W / iw, H / ih);
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(skyImg, (W - iw * k) / 2, (H - ih * k) * .35, iw * k, ih * k);
  const img = ctx.getImageData(0, 0, W, H), d = img.data;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const lum = (d[i] * .3 + d[i + 1] * .55 + d[i + 2] * .15) / 255;
    // Stretch the painting's soft range, keep the top darker so labels read.
    let v = clamp((lum - .55) * 2.1 + .38 + (y / H) * .12, 0, 1) + bayer[(y % 8) * 8 + (x % 8)] * .15;
    const [r, g, b] = wallPalette[clamp(Math.round(v * (wallPalette.length - 1)), 0, wallPalette.length - 1)];
    d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
}

function layout() {
  L = innerWidth < 720 ? layouts.narrow : layouts.wide;
  screen.classList.toggle('is-narrow', L === layouts.narrow);
  const availW = Math.min(innerWidth - 32, L.dw);
  // Wide screens show a generous desktop that rises past the fold; phones fit the width.
  S = innerWidth < 720 ? availW / L.dw : Math.min(availW / L.dw, 0.88);
  for (const el of [wrap, screen]) {
    el.style.setProperty('--dw', L.dw);
    el.style.setProperty('--dh', L.dh);
  }
  wrap.style.setProperty('--s', S);
  screen.style.setProperty('--fh', L.fh);
  place(fridge, L.fridge);
  place($('#note'), L.note);
  files.forEach((f, i) => {
    const st = state.get(f.id);
    [st.x, st.y] = L.files[i];
    place(st.el, L.files[i]);
  });
  relayoutShelf();
}
const place = (el, [x, y]) => { el.style.left = x + 'px'; el.style.top = y + 'px'; };

function fridgeRect() {
  const r = fridge.getBoundingClientRect();
  return { l: r.left + r.width * 0.08, r: r.right - r.width * 0.08, t: r.top + r.height * 0.02, b: r.bottom - r.height * 0.04 };
}
const inside = (x, y, q) => x > q.l && x < q.r && y > q.t && y < q.b;

let closeTimer;
function setOpen(open) {
  fridge.classList.toggle('is-open', open);
  fridge.setAttribute('aria-pressed', String(open));
  fridge.setAttribute('aria-label', open ? 'Fridge. Open. Press to close.' : 'Fridge. Closed. Press to open.');
  [...shelf.children].forEach(s => (s.tabIndex = open && s.dataset.full ? 0 : -1));
}

function enableDrag(el, f) {
  let start = null;
  el.addEventListener('pointerdown', e => {
    const st = state.get(f.id);
    start = { px: e.clientX, py: e.clientY, x: st.x, y: st.y, moved: false };
    el.setPointerCapture(e.pointerId);
  });
  el.addEventListener('pointermove', e => {
    if (!start) return;
    const dx = (e.clientX - start.px) / S, dy = (e.clientY - start.py) / S;
    if (!start.moved && Math.hypot(dx, dy) < 4) return;
    start.moved = true;
    el.classList.add('is-dragging');
    el.style.left = start.x + dx + 'px';
    el.style.top = start.y + dy + 'px';
    const near = inside(e.clientX, e.clientY, fridgeRect());
    clearTimeout(closeTimer);
    fridge.classList.toggle('is-near', near);
    setOpen(near);
  });
  const end = e => {
    if (!start) return;
    const s = start; start = null;
    el.classList.remove('is-dragging');
    fridge.classList.remove('is-near');
    // The page scrolled instead: put the file back, do not store it.
    if (e.type === 'pointercancel') { el.style.left = s.x + 'px'; el.style.top = s.y + 'px'; setOpen(false); return; }
    if (!s.moved) return store(f);                       // a click or tap also stores it
    if (inside(e.clientX, e.clientY, fridgeRect())) store(f);
    else { el.style.left = s.x + 'px'; el.style.top = s.y + 'px'; setOpen(false); }
  };
  el.addEventListener('pointerup', end);
  el.addEventListener('pointercancel', end);
}

function store(f) {
  const st = state.get(f.id);
  if (st.stored) return;
  st.stored = true;
  st.shelfEl.dataset.full = '1';
  st.el.classList.add('is-stored');
  setOpen(true);
  relayoutShelf();
  update();
  clearTimeout(closeTimer);
  closeTimer = setTimeout(() => setOpen(false), reduce ? 400 : 1100);   // the door swings shut
}

function putBack(f) {
  const st = state.get(f.id);
  if (!st.stored) return;
  st.stored = false;
  delete st.shelfEl.dataset.full;
  st.el.classList.remove('is-stored');
  place(st.el, [st.x, st.y]);
  relayoutShelf();
  update();
  st.el.focus({ preventScroll: true });
}

// Stored files fill the shelf slots in the order they went in.
function relayoutShelf() {
  const k = L.fh / 800, r = 1.264, ox = (422 - 445 * r) * k, oy = (795 - 640 * r) * k;
  let i = 0;
  files.forEach(f => {
    const s = state.get(f.id).shelfEl;
    if (!s.dataset.full) { s.style.visibility = 'hidden'; return; }
    const [sx, sy] = slots[i++];
    s.style.visibility = '';
    s.style.left = ox + sx * k * r - 17 + 'px';
    s.style.top = oy + sy * k * r - 40 + 'px';
  });
  setOpen(fridge.classList.contains('is-open'));
}

function update() {
  const n = [...state.values()].filter(s => s.stored).length;
  const text = n === 0 ? 'Drag a file into the fridge.'
    : n === files.length ? 'Desktop clear! Open the fridge to get them back.'
    : `${n} in the fridge. ${files.length - n} to go.`;
  $('#note-text').textContent = text;
  $('#status').textContent = text;
}

fridge.addEventListener('click', () => {
  clearTimeout(closeTimer);
  setOpen(!fridge.classList.contains('is-open'));
});

function tick() {
  const d = new Date();
  const time = d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  $('#clock').textContent = L === layouts.narrow ? time
    : d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' }) + '  ' + time;
}

/* ---------- The drawer gets a tug ---------- */
$('#drawer-pull')?.addEventListener('click', e => {
  const el = e.currentTarget;
  el.classList.add('is-tugged');
  setTimeout(() => el.classList.remove('is-tugged'), 140);
});

/* ---------- The care label swings when brushed ---------- */
(() => {
  const label = $('#label');
  if (!label) return;
  let a = 0, v = 0, raf = 0, lastX = null;
  const step = () => {
    v += -a * 0.045 - v * 0.06;
    a += v;
    label.style.setProperty('--swing', a.toFixed(3) + 'deg');
    raf = Math.abs(a) + Math.abs(v) > 0.005 ? requestAnimationFrame(step) : 0;
  };
  label.addEventListener('pointermove', e => {
    if (reduce || e.pointerType !== 'mouse') return;
    if (lastX !== null) v += clamp((e.clientX - lastX) * 0.012, -0.4, 0.4);
    lastX = e.clientX;
    if (!raf) raf = requestAnimationFrame(step);
  });
  label.addEventListener('pointerleave', () => (lastX = null));
})();

/* ---------- Letters ---------- */
function postmarkSVG(place, date) {
  const ring = place ? `${place}${date ? ' · ' + date : ''}`.toUpperCase() : '';
  const year = (date.match(/\d{4}/) || [''])[0];
  const waves = [38, 52, 66, 80].map(y => `<path d="M0 ${y} q 9 -6 18 0 t 18 0 t 18 0 t 18 0 t 18 0 t 18 0" fill="none" stroke="#4a3f5c" stroke-width="2.4"/>`).join('');
  return `${waves}<circle cx="160" cy="60" r="50"/><circle cx="160" cy="60" r="37"/>
    <path id="pm-ring" d="M160 60m-43 0a43 43 0 1 1 86 0a43 43 0 1 1-86 0" fill="none" stroke="none"/>
    ${ring ? `<text><textPath href="#pm-ring" textLength="262" lengthAdjust="spacing">${ring} · </textPath></text>` : ''}
    ${year ? `<text x="160" y="69" text-anchor="middle" class="postmark__mid">${year}</text>` : ''}`;
}
let letterIndex = 0;
function showLetter(i) {
  const l = letters[i];
  $('#env-from').textContent = 'From ' + l.from;
  $('#env-to').textContent = l.title;
  $('#stamp').innerHTML = `<div class="stamp__art" style="--tint:${l.tint}">${crossStitch(motifs[l.motif])}</div>`;
  $('#postmark').innerHTML = postmarkSVG(l.place, l.date);
  $('#postmark').setAttribute('viewBox', '0 0 220 120');
  $('#letter-from').innerHTML = `<b></b><span></span>`;
  $('#letter-from b').textContent = l.from;
  $('#letter-from span').textContent = l.title;
  const body = $('#letter-body');
  body.replaceChildren(...l.body.split('\n\n').map(p => Object.assign(document.createElement('p'), { textContent: p })));
  $('#letter-source').textContent = l.source;
  $('#letter-count').textContent = `${i + 1} of ${letters.length}`;
}
$('#next-letter')?.addEventListener('click', async () => {
  letterIndex = (letterIndex + 1) % letters.length;
  const env = $('#envelope'), let_ = $('#letter');
  if (reduce) return showLetter(letterIndex);
  const out = { duration: 260, easing: 'cubic-bezier(.4,0,1,1)', fill: 'forwards' };
  await Promise.all([
    let_.animate([{ transform: 'rotate(1.6deg)' }, { transform: 'translate(40px,-24px) rotate(6deg)', opacity: 0 }], out).finished,
    env.animate([{ transform: 'rotate(-5deg)' }, { transform: 'translate(-30px,20px) rotate(-9deg)', opacity: 0 }], out).finished,
  ]);
  showLetter(letterIndex);
  const inn = { duration: 520, easing: 'cubic-bezier(.2,1.3,.4,1)', fill: 'forwards' };
  env.animate([{ transform: 'translate(0,-40px) rotate(-1deg)', opacity: 0 }, { transform: 'rotate(-5deg)', opacity: 1 }], inn);
  let_.animate([{ transform: 'translate(0,-50px) rotate(-2deg)', opacity: 0 }, { transform: 'rotate(1.6deg)', opacity: 1 }], { ...inn, delay: 90 })
    .finished.then(a => { env.getAnimations().concat(let_.getAnimations()).forEach(x => x.cancel()); });
});
if ($('#desk')) showLetter(0);

/* ---------- Cross-stitch meadow along the foot ---------- */
const flowerHeads = {
  sunflower: { rows: ['.yyy.', 'yBbBy', 'ybBby', 'yBbBy', '.yyy.'], stem: [8, 13] },
  poppy: { rows: ['r.r', 'rnr', '.r.'], stem: [5, 9] },
  corn: { rows: ['.l.', 'LlL', '.l.'], stem: [4, 8] },
  cosmos: { rows: ['.m.', 'mym', '.m.'], stem: [3, 7] },
};
const meadowColours = { ...colours, l: '#7aa0e0', L: '#4a78c8', b: '#5a3518', B: '#7a4a25' };
let meadow = null;
function buildMeadow() {
  const c = $('#meadow'), box = c.parentElement;
  const W = box.offsetWidth, H = box.offsetHeight, dpr = Math.min(2, devicePixelRatio || 1);
  const C = W < 720 ? 7 : 9;
  const cols = Math.ceil(W / C), rows = Math.floor(H / C);
  c.width = W * dpr; c.height = H * dpr;
  const grass = [];
  for (let x = 0; x < cols; x++) {
    const h = 2 + Math.round(noise(x * .3, 4) * 3) + (hash(x, 9) < .18 ? 2 + Math.floor(hash(x, 2) * 3) : 0);
    grass.push(h);
  }
  const flowers = [];
  const types = Object.keys(flowerHeads);
  for (let x = 2 + Math.floor(Math.random() * 4); x < cols - 3; x += 4 + Math.floor(Math.random() * 7)) {
    const type = types[Math.floor(Math.random() * types.length)];
    const [a, b] = flowerHeads[type].stem;
    const stem = Math.min(rows - 6, a + Math.floor(Math.random() * (b - a)));
    const leaves = [[2 + Math.floor(Math.random() * 3), Math.random() < .5 ? -1 : 1]];
    if (stem > 7) leaves.push([5 + Math.floor(Math.random() * 2), -leaves[0][1]]);
    flowers.push({ x, type, stem, leaves, sway: 0, vel: 0, target: 0 });
  }
  const sparks = Array.from({ length: Math.round(cols / 30) }, () => [Math.floor(Math.random() * cols), 2 + Math.floor(Math.random() * Math.max(1, rows - 18))]);
  meadow = { c, ctx: c.getContext('2d'), W, H, C, cols, rows, dpr, grass, flowers, sparks, raf: 0 };
  drawMeadow();
}
function stitch(ctx, x, y, C, col) {
  const a = C * .2, b = C * .8;
  ctx.strokeStyle = shade(col, .8);
  ctx.beginPath(); ctx.moveTo(x + a, y + a); ctx.lineTo(x + b, y + b); ctx.stroke();
  ctx.strokeStyle = col;
  ctx.beginPath(); ctx.moveTo(x + b, y + a); ctx.lineTo(x + a, y + b); ctx.stroke();
}
function drawMeadow() {
  const m = meadow, { ctx, C, rows } = m;
  ctx.setTransform(m.dpr, 0, 0, m.dpr, 0, 0);
  ctx.clearRect(0, 0, m.W, m.H);
  ctx.lineWidth = C * .32;
  ctx.lineCap = 'round';
  const cell = (cx, cy, col) => stitch(ctx, cx * C, (rows - 1 - cy) * C, C, col);
  m.sparks.forEach(([x, y]) => {
    [[0, 1], [0, -1], [1, 0], [-1, 0], [0, 0]].forEach(([dx, dy]) => cell(x + dx, rows - 1 - y + dy, '#f1be5b'));
  });
  m.flowers.forEach(f => {
    const off = k => Math.round(f.sway * (k / f.stem) ** 2);
    for (let k = 0; k < f.stem; k++) cell(f.x + off(k), k, k % 3 ? '#4b7f34' : '#5a8f3e');
    f.leaves.forEach(([k, side]) => { cell(f.x + off(k) + side, k, '#6ea24a'); cell(f.x + off(k) + side * 2, k + 1, '#6ea24a'); });
    const head = flowerHeads[f.type].rows, hw = head[0].length;
    head.forEach((row, r) => [...row].forEach((ch, i) => {
      const col = meadowColours[ch];
      if (col) cell(f.x + off(f.stem) - (hw >> 1) + i, f.stem + head.length - 1 - r, col);
    }));
  });
  m.grass.forEach((h, x) => {
    for (let k = 0; k < h; k++) cell(x, k, ['#5a8f3e', '#4b7f34', '#6ea24a', '#3f6e2e'][(x * 7 + k * 3) % 4]);
  });
}
function stepMeadow() {
  const m = meadow;
  let busy = false;
  m.flowers.forEach(f => {
    f.vel += (f.target - f.sway) * .08 - f.vel * .16;
    f.sway += f.vel;
    f.target *= .9;
    if (Math.abs(f.vel) + Math.abs(f.target) + Math.abs(f.sway) > .02) busy = true;
  });
  drawMeadow();
  m.raf = busy ? requestAnimationFrame(stepMeadow) : 0;
}
$('.foot').addEventListener('pointermove', e => {
  if (!meadow || reduce) return;
  const r = meadow.c.getBoundingClientRect();
  if (e.clientY < r.top - 60) return;
  const px = e.clientX - r.left;
  meadow.flowers.forEach(f => {
    const dx = (f.x + .5) * meadow.C - px;
    if (Math.abs(dx) < 70) f.target = clamp(Math.sign(dx) * (70 - Math.abs(dx)) / 22, -2.4, 2.4);
  });
  if (!meadow.raf) meadow.raf = requestAnimationFrame(stepMeadow);
});

/* ---------- Start ---------- */
function measure() {
  tear();
  layout();
  const paper = $('#paper');
  $('#sky').style.setProperty('--sky-top', paper.offsetHeight - 120 + 'px');
  placeLoose();
  paintSkyPixels();
  paintWallpaper();
  buildMeadow();
}
buildFiles();
measure();
tick();
setInterval(tick, 30000);
let rt, lastW = innerWidth;
addEventListener('resize', () => {
  clearTimeout(rt);
  // Phones resize the viewport while scrolling; only redo the page when the width changes.
  rt = setTimeout(() => { if (innerWidth !== lastW) { lastW = innerWidth; measure(); } else layout(); }, 120);
});
document.fonts?.ready.then(measure);
