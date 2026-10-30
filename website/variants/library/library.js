import objects from '../../objects.js';
import letters from '../../letters.js';

// The library variant. The cards and the spotlight come from objects.js, so new objects need no new design.
// Adapted pieces in House rules and Make your own are credited in CREDITS.md.
const SPOTLIGHT = 'mailbox';   // the one object shown large at the top; change the id to feature another
const PAGE = 12;               // cards shown before "Show more"
// A real screenshot of each object on a desktop, for its card. Objects without one show their art.
const SHOTS = {
  fridge: 'media/shots/fridge.webp',
  mailbox: 'media/shots/mailbox.webp',
};
// A short film for the spotlight, when there is one. Without it the spotlight shows the object's art.
const SPOTLIGHT_MEDIA = {
  mailbox: {
    video: 'media/spotlight/mailbox.mp4',
    poster: 'media/spotlight/mailbox-poster.webp',
    label: 'Desktop Mailbox on a Mac desktop: a letter arrives through the slot, opens, and is put away.',
  },
};

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const grid = $('#lib-grid'), count = $('#lib-count'), empty = $('#lib-empty'), search = $('#lib-search');
const more = $('#lib-more'), sortBy = $('#lib-sort');

let items = objects.map(o => ({ ...o, ready: Boolean(o.download) }));

// ?many fills the grid with example cards, to check how the library looks with 50+ objects.
const many = new URLSearchParams(location.search).has('many');
if (many) {
  const real = items.slice();
  const words = ['Toaster', 'Plant Pot', 'Toolbox', 'Oven', 'Birdhouse', 'Record Player', 'Bookshelf', 'Lunchbox', 'Piggy Bank', 'Bread Bin', 'Typewriter', 'Tackle Box'];
  for (let i = 0; items.length < 54; i++) {
    const o = real[i % real.length];
    items.push({ ...o, id: `example-${i}`, name: `Example ${words[i % words.length]}`, example: true,
      accent: ['#E0A94A', '#6CCBF0', '#D8432F', '#7BAE5A', '#9C7BD8', '#E58FB0', '#4E8FD0'][i % 7], added: `2026-0${1 + (i % 9)}-1${i % 9}` });
  }
}

/* ---------- Dithered covers ---------- */
// Each object gets a soft dithered field in its own accent colour. It needs no extra art.
const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map(v => v / 16 - 0.5);
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
function seeded(str) {
  let h = 2166136261;
  for (const c of str) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return () => ((h = Math.imul(h ^ (h >>> 15), 2246822507), h = Math.imul(h ^ (h >>> 13), 3266489909), (h ^= h >>> 16) >>> 0) / 4294967296);
}
function paintCover(canvas, accent, id) {
  const W = 64, H = 44;
  canvas.width = W; canvas.height = H;
  const ctx = canvas.getContext('2d'), img = ctx.createImageData(W, H);
  const [r, g, b] = hex(accent);
  const tint = t => [r + (255 - r) * t, g + (255 - g) * t, b + (255 - b) * t];
  const pal = [0.93, 0.84, 0.72, 0.56, 0.38].map(tint);
  const rand = seeded(id);
  const blobs = Array.from({ length: 3 }, () => ({ x: rand(), y: rand() * 0.9, r: 0.22 + rand() * 0.3, w: 0.45 + rand() * 0.45 }));
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const u = x / W, v = y / H;
    let f = 0.12 + v * 0.12;
    for (const bl of blobs) {
      const d = ((u - bl.x) ** 2 + ((v - bl.y) * 0.7) ** 2) / (bl.r * bl.r);
      f += bl.w * Math.exp(-d);
    }
    f += bayer[(y % 4) * 4 + (x % 4)] * 0.22;
    const c = pal[Math.max(0, Math.min(pal.length - 1, Math.round(f * (pal.length - 1))))];
    const i = (y * W + x) * 4;
    img.data[i] = c[0]; img.data[i + 1] = c[1]; img.data[i + 2] = c[2]; img.data[i + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
}
const paintField = paintCover;

/* ---------- Cards ---------- */
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const macos = v => 'macOS ' + String(v).replace(/\.0$/, '') + '+';

function card(o) {
  const wide = o.aspect > 2.2;
  const action = o.ready
    ? `<a class="card__get" href="${esc(o.download)}" aria-label="Download ${esc(o.name)}">Get</a>`
    : `<span class="card__soon">Soon</span>`;
  return `<article class="card" style="--accent:${esc(o.accent)}" data-id="${esc(o.id)}">
    <div class="card__cover${SHOTS[o.id] ? ' has-shot' : ''}">
      ${SHOTS[o.id] ? `<img class="card__shot" src="${esc(SHOTS[o.id])}" alt="" loading="lazy">`
        : o.art ? `<img class="card__art${wide ? ' is-wide' : ''}" src="${esc(o.art)}" alt="" loading="lazy">` : ''}
      <div class="card__front"><span class="card__label">${o.ready ? 'Free' : 'Coming soon'} · v${esc(o.version)}</span></div>
    </div>
    <div class="card__body">
      <h3 class="card__name"><a href="${esc(o.source)}">${esc(o.name)}</a></h3>
      <p class="card__tag">${esc(o.tagline)}</p>
      <div class="card__foot">
        <span class="card__by">by ${esc(o.author)}</span>
        ${action}
      </div>
    </div>
  </article>`;
}

/* ---------- Spotlight ---------- */
// Some objects bring something extra to their spotlight. The mailbox shows one of its letters.
const shortLetters = letters.filter(l => l.body.length <= 340);
let letterAt = 0;
const extras = {
  mailbox: () => {
    const l = shortLetters[letterAt % shortLetters.length];
    return `<figure class="spot-letter">
      <blockquote>${l.body.split('\n\n').map(p => `<p>${esc(p)}</p>`).join('')}</blockquote>
      <figcaption><b>${esc(l.from)}</b>, ${esc(l.title.replace(/^To /, 'to '))}</figcaption>
      <button type="button" class="spot-letter__next" id="spot-next">Another letter</button>
    </figure>`;
  },
};

function renderSpotlight() {
  const o = items.find(x => x.id === SPOTLIGHT) || items[0];
  const el = $('#spotlight');
  el.style.setProperty('--accent', o.accent);
  const action = o.ready
    ? `<a class="button" href="${esc(o.download)}">Download ${esc(o.name)}</a>`
    : `<span class="spotlight__soon">Coming soon</span>`;
  const media = SPOTLIGHT_MEDIA[o.id];
  const cover = media
    ? `<div class="spotlight__cover spotlight__cover--video">
        <div class="spotlight__screen">
          <video class="spotlight__video" muted loop playsinline preload="metadata" poster="${esc(media.poster)}" aria-label="${esc(media.label)}">
            <source src="${esc(media.video)}" type="video/mp4">
          </video>
          <button class="spotlight__play" type="button" aria-label="Pause the video" data-state="playing">
            <svg class="spotlight__icon-pause" viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3.5v9M11 3.5v9"/></svg>
            <svg class="spotlight__icon-play" viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3.2l8 4.8-8 4.8z"/></svg>
          </button>
        </div>
      </div>`
    : `<div class="spotlight__cover"><canvas aria-hidden="true"></canvas>
      ${o.art ? `<img class="spotlight__art" src="${esc(o.art)}" alt="${esc(o.name)}" loading="lazy">` : ''}
    </div>`;
  el.innerHTML = `
    ${cover}
    <div class="spotlight__body">
      <p class="spotlight__label">In the spotlight</p>
      <h3 class="spotlight__name" id="spot-title">${esc(o.name)}</h3>
      <p class="spotlight__by">by ${esc(o.author)} · ${esc(macos(o.minMacOS))} · Free</p>
      <p class="spotlight__desc">${esc(o.description)}</p>
      ${extras[o.id] ? extras[o.id]() : ''}
      <div class="spotlight__actions">${action}<a class="quiet" href="${esc(o.source)}">View source</a></div>
    </div>`;
  const canvas = el.querySelector('canvas');
  if (canvas) paintCover(canvas, o.accent, o.id + '-spot');
  if (media) playWhenVisible(el.querySelector('.spotlight__video'), el.querySelector('.spotlight__play'));
  el.querySelector('#spot-next')?.addEventListener('click', () => { letterAt++; renderLetterOnly(); });
}

// The video plays only while it is on screen, never with reduced motion, and can always be paused.
function playWhenVisible(video, button) {
  let paused = reduce;              // the visitor's choice, not just whether it is on screen
  const show = () => {
    button.dataset.state = paused ? 'paused' : 'playing';
    button.setAttribute('aria-label', paused ? 'Play the video' : 'Pause the video');
  };
  let visible = false, rescued = false;
  // Safari plays video only from servers that answer partial requests. Some local preview servers do not,
  // so if nothing has loaded after a moment, fetch the whole (small) file and play it from memory.
  const rescue = () => {
    if (rescued || video.readyState > 0) return;
    rescued = true;
    fetch(video.currentSrc || video.querySelector('source').src)
      .then(r => r.blob())
      .then(b => { video.src = URL.createObjectURL(b); if (visible && !paused) start(); })
      .catch(() => {});
  };
  // Some browsers refuse to start a video on their own. Then the button shows Play, and a click starts it.
  const start = () => video.play().catch(err => {
    if (err && err.name === 'NotAllowedError') { paused = true; show(); }
  });
  const sync = () => {
    if (visible && !paused) { start(); setTimeout(rescue, 1500); }
    else video.pause();
  };
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; sync(); }, { threshold: 0.4 }).observe(video);
  button.addEventListener('click', () => { paused = !paused; show(); sync(); });
  show();
}
function renderLetterOnly() {
  const el = $('#spotlight'), fig = el.querySelector('.spot-letter');
  const next = () => {
    fig.outerHTML = extras.mailbox();
    const btn = el.querySelector('#spot-next');
    btn.addEventListener('click', () => { letterAt++; renderLetterOnly(); });
    btn.focus({ preventScroll: true });
  };
  if (reduce) return next();
  fig.animate([{ opacity: 1 }, { opacity: 0, transform: 'translateY(-6px)' }], { duration: 160, fill: 'forwards' }).finished.then(() => {
    next();
    el.querySelector('.spot-letter').animate([{ opacity: 0, transform: 'translateY(6px)' }, { opacity: 1, transform: 'none' }], { duration: 260, easing: 'ease-out' });
  });
}

/* ---------- The grid ---------- */
let filter = 'all', shown = PAGE;
const sorters = {
  picked: (a, b) => (b.ready - a.ready) || a.name.localeCompare(b.name),
  new: (a, b) => (b.added || '').localeCompare(a.added || '') || a.name.localeCompare(b.name),
  name: (a, b) => a.name.localeCompare(b.name),
};

function render() {
  const q = search.value.trim().toLowerCase();
  const list = items
    .filter(o => (filter === 'all' || (filter === 'ready') === o.ready) &&
      (!q || `${o.name} ${o.tagline} ${o.description} ${o.author}`.toLowerCase().includes(q)))
    .sort(sorters[sortBy.value]);
  const page = list.slice(0, shown);
  grid.innerHTML = page.map(card).join('');
  count.textContent = `${list.length} ${list.length === 1 ? 'object' : 'objects'}${many ? ', with examples' : ''}`;
  more.hidden = list.length <= shown;
  more.textContent = `Show more (${list.length - shown} left)`;
  empty.hidden = list.length > 0;
}

document.querySelectorAll('.chip').forEach(chip => chip.addEventListener('click', () => {
  filter = chip.dataset.filter;
  shown = PAGE;
  document.querySelectorAll('.chip').forEach(c => c.setAttribute('aria-pressed', String(c === chip)));
  render();
}));
search.addEventListener('input', () => { shown = PAGE; render(); });
sortBy.addEventListener('change', () => { shown = PAGE; render(); });
more.addEventListener('click', () => {
  const before = shown;
  shown += PAGE;
  render();
  grid.children[before]?.querySelector('a')?.focus({ preventScroll: true });
});

renderSpotlight();
render();

/* ======================================================================
   House rules
   ====================================================================== */
// The ticks draw in one after another when the board comes into view (after Bencho's Checklist),
// and one highlight slides to the row under the pointer (after Motion Primitives' Animated Background).
const board = $('#rules-board');
if (board) {
  const rows = $$('.rule', board), hl = $('.rules__hl', board);
  rows.forEach((r, i) => r.style.setProperty('--d', `${i * 140}ms`));
  if (reduce || !('IntersectionObserver' in window)) rows.forEach(r => r.classList.add('is-done'));
  else {
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return;
      rows.forEach(r => r.classList.add('is-done'));
      io.disconnect();
    }, { threshold: 0.35 });
    io.observe(board);
  }
  const moveTo = row => {
    hl.style.height = row.offsetHeight + 'px';
    hl.style.transform = `translateY(${row.offsetTop + 8}px)`;
  };
  rows.forEach(r => r.addEventListener('pointerenter', e => {
    if (e.pointerType !== 'mouse') return;
    if (!board.classList.contains('is-hovering')) {
      hl.style.transition = 'none';
      moveTo(r);
      void hl.offsetWidth;
      hl.style.transition = '';
      board.classList.add('is-hovering');
    } else moveTo(r);
  }));
  board.addEventListener('pointerleave', () => board.classList.remove('is-hovering'));
}

/* ======================================================================
   Make your own
   ====================================================================== */

/* ---------- Stepper: after Arc's Stepper ---------- */
const tabs = $$('.stepper__head'), stepItems = $$('.stepper__item');
function setStep(n, focus) {
  stepItems.forEach((li, i) => li.dataset.status = i < n ? 'complete' : i === n ? 'current' : 'upcoming');
  tabs.forEach((t, i) => {
    t.setAttribute('aria-selected', String(i === n));
    t.tabIndex = i === n ? 0 : -1;
    $('#' + t.getAttribute('aria-controls')).hidden = i !== n;
  });
  if (focus) tabs[n].focus();
}
tabs.forEach((t, i) => {
  t.addEventListener('click', () => setStep(i));
  t.addEventListener('keydown', e => {
    const n = { ArrowDown: i + 1, ArrowRight: i + 1, ArrowUp: i - 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
    if (n === undefined) return;
    e.preventDefault();
    setStep((n + tabs.length) % tabs.length, true);
  });
});

/* ---------- The stage ---------- */
const stageObj = $('#stage-obj'), artClosed = $('#art-closed'), artOpen = $('#art-open'), stageTag = $('#stage-tag');
paintField($('#stage canvas'), '#A3B020', 'stage');
stageObj.addEventListener('click', () => {
  const open = !stageObj.classList.contains('is-open');
  stageObj.classList.toggle('is-open', open);
  stageObj.setAttribute('aria-pressed', String(open));
  stageObj.setAttribute('aria-label', `Your object. ${open ? 'Open. Press to close.' : 'Closed. Press to open.'}`);
  $('.stage__hint').textContent = open ? 'Click it to close' : 'Click it to open';
});

/* ---------- Drop your pictures: after Arc's File Dropzone ---------- */
// The pictures are read in the browser and shown on the stage. Nothing is uploaded.
const drop = $('#drop'), input = $('#drop-input'), fileList = $('#drop-files'), err = $('#drop-error'), reset = $('#drop-reset');
let urls = [];
const showError = text => { err.textContent = text; err.hidden = !text; };
const kb = n => n > 1e6 ? (n / 1e6).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1e3)) + ' KB';

function useArt(closed, open) {
  urls.forEach(u => URL.revokeObjectURL(u));
  urls = [];
  const c = URL.createObjectURL(closed), o = open ? URL.createObjectURL(open) : c;
  urls.push(c); if (open) urls.push(o);
  artClosed.src = c;
  artOpen.src = o;
  stageObj.classList.remove('is-open', 'is-landing');
  void stageObj.offsetWidth;
  stageObj.classList.add('is-landing');
  stageTag.textContent = open ? 'Your object' : 'Your object (add open.png to see it open)';
  fileList.innerHTML = [[closed, 'closed', c], [open, 'open', o]].filter(([f]) => f).map(([f, role, u]) =>
    `<li class="drop__file"><img src="${u}" alt=""><span>${esc(f.name)}<small>${kb(f.size)}</small></span><b class="drop__role">${role}.png</b></li>`).join('');
  reset.hidden = false;
  // Both pictures should be the same size, so the object does not jump when it opens.
  if (open) Promise.all([c, o].map(src => new Promise(r => { const im = new Image(); im.onload = () => r([im.naturalWidth, im.naturalHeight]); im.onerror = () => r([0, 0]); im.src = src; })))
    .then(([a, b]) => showError(a[0] !== b[0] || a[1] !== b[1] ? `They are different sizes (${a[0]} x ${a[1]} and ${b[0]} x ${b[1]}). Make both the same size.` : ''));
}
function handle(files) {
  const pics = files.filter(f => f.type.startsWith('image/'));
  if (!pics.length) return showError('Those are not pictures. Drop two PNG files.');
  showError('');
  let closed = pics.find(f => /closed|shut/i.test(f.name));
  let open = pics.find(f => /open/i.test(f.name) && f !== closed);
  if (!closed) closed = pics.find(f => f !== open) || pics[0];
  if (!open) open = pics.find(f => f !== closed) || null;
  useArt(closed, open);
}
['dragenter', 'dragover'].forEach(t => drop.addEventListener(t, e => {
  e.preventDefault();
  drop.classList.add('is-dragging');
  const r = drop.getBoundingClientRect();
  drop.style.setProperty('--mx', `${e.clientX - r.left}px`);
  drop.style.setProperty('--my', `${e.clientY - r.top}px`);
}));
drop.addEventListener('dragleave', e => { if (!drop.contains(e.relatedTarget)) drop.classList.remove('is-dragging'); });
drop.addEventListener('drop', e => { e.preventDefault(); drop.classList.remove('is-dragging'); handle([...e.dataTransfer.files]); });
input.addEventListener('change', () => { handle([...input.files]); input.value = ''; });
reset.addEventListener('click', () => {
  urls.forEach(u => URL.revokeObjectURL(u));
  urls = [];
  artClosed.src = 'media/template/closed.png';
  artOpen.src = 'media/template/open.png';
  stageObj.classList.remove('is-open');
  stageTag.textContent = 'The template crate';
  fileList.innerHTML = '';
  showError('');
  reset.hidden = true;
});

/* ---------- Copy commands ---------- */
document.addEventListener('click', async e => {
  const btn = e.target.closest('.copy');
  if (!btn) return;
  const code = btn.closest('.code').querySelector('code').textContent;
  const text = code.split('\n').filter(l => !l.trim().startsWith('#')).join('\n');
  const label = $('.copy__label', btn);
  try { await navigator.clipboard.writeText(text); label.textContent = 'Copied'; }
  catch { label.textContent = 'Select it'; }
  btn.classList.add('is-done');
  setTimeout(() => { label.textContent = 'Copy'; btn.classList.remove('is-done'); }, 1600);
});
