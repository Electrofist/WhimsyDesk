#!/usr/bin/env node
// Gathers WhimsyDesk's GitHub numbers and writes them, encrypted, to website/stats/data.json.
// The stats page decrypts them in the browser with the password; the password is never stored.
//
//   STATS_PASSWORD='...' node scripts/stats-snapshot.mjs
//
// Needs the GitHub CLI signed in with push access (traffic numbers are private to the owner).
// GitHub keeps only 14 days of traffic, so each run merges into the history already in data.json.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = 'Electrofist/WhimsyDesk';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'website', 'stats', 'data.json');
const ITERATIONS = 600000;
const { subtle } = globalThis.crypto;

const password = process.env.STATS_PASSWORD;
if (!password) {
  console.error('Set STATS_PASSWORD to the stats page password.');
  process.exit(1);
}

function api(path, accept) {
  const args = ['api', '--paginate', path];
  if (accept) args.push('-H', `Accept: ${accept}`);
  const text = execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  // --paginate glues JSON arrays together as "][": join them into one array.
  return JSON.parse(text.trim().replace(/\]\s*\[/g, ','));
}

// --- encryption: PBKDF2-SHA256 key, AES-GCM, the same recipe the page uses to decrypt ---
const b64 = (buf) => Buffer.from(buf).toString('base64');
const unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));

async function keyFor(salt) {
  const base = await subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
  return subtle.deriveKey({ name: 'PBKDF2', salt, iterations: ITERATIONS, hash: 'SHA-256' },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

async function encrypt(obj) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await subtle.encrypt({ name: 'AES-GCM', iv }, await keyFor(salt), new TextEncoder().encode(JSON.stringify(obj)));
  return { v: 1, kdf: 'PBKDF2-SHA256', iterations: ITERATIONS, salt: b64(salt), iv: b64(iv), data: b64(ct) };
}

async function decrypt(file) {
  const plain = await subtle.decrypt({ name: 'AES-GCM', iv: unb64(file.iv) }, await keyFor(unb64(file.salt)), unb64(file.data));
  return JSON.parse(new TextDecoder().decode(plain));
}

// --- which object and platform a download belongs to ---
const OBJECTS = [
  ['Desktop-Vending-Machine-Keypad', 'Vending Machine Keypad'],
  ['Desktop-Vending-Machine', 'Vending Machine'],
  ['Desktop-Fridge', 'Fridge'],
  ['Desktop-Drawer', 'Drawer'],
  ['Desktop-Mailbox', 'Mailbox'],
];
function classify(name) {
  const hit = OBJECTS.find(([prefix]) => name.startsWith(prefix));
  if (!hit) return null;
  const windows = /Setup|Windows/i.test(name) || name.endsWith('.exe');
  if (name.endsWith('.sha256')) return null;
  return { object: hit[1], platform: windows ? 'Windows' : 'Mac' };
}

// --- previous history, so traffic older than 14 days is kept ---
let history = { views: {}, clones: {}, downloads: {}, referrers: {} };
if (existsSync(OUT)) {
  try {
    history = { ...history, ...(await decrypt(JSON.parse(readFileSync(OUT, 'utf8')))).history };
  } catch {
    console.error('Could not read the old data.json with this password. Starting a fresh history.');
  }
}

const repo = api(`repos/${REPO}`);
const views = api(`repos/${REPO}/traffic/views`);
const clones = api(`repos/${REPO}/traffic/clones`);
const referrers = api(`repos/${REPO}/traffic/popular/referrers`);
const paths = api(`repos/${REPO}/traffic/popular/paths`);
const releases = api(`repos/${REPO}/releases?per_page=100`);
const stars = api(`repos/${REPO}/stargazers?per_page=100`, 'application/vnd.github.star+json');

const today = new Date().toISOString().slice(0, 10);

// Daily traffic: a day's count can still grow, so keep the larger number.
for (const d of views.views) {
  const day = d.timestamp.slice(0, 10), old = history.views[day];
  history.views[day] = { count: Math.max(d.count, old?.count ?? 0), uniques: Math.max(d.uniques, old?.uniques ?? 0) };
}
for (const d of clones.clones) {
  const day = d.timestamp.slice(0, 10), old = history.clones[day];
  history.clones[day] = { count: Math.max(d.count, old?.count ?? 0), uniques: Math.max(d.uniques, old?.uniques ?? 0) };
}
// Referrers are a 14-day window: keep today's snapshot so the page can show how they change.
history.referrers[today] = referrers.map((r) => ({ source: r.referrer, count: r.count, uniques: r.uniques }));

// Downloads: GitHub counts per file, and a re-uploaded file starts again from zero,
// so keep the highest count ever seen for each file.
const files = [];
for (const rel of releases) {
  for (const a of rel.assets) {
    const c = classify(a.name);
    if (!c) continue;
    const id = `${rel.tag_name}/${a.name}`;
    const best = Math.max(a.download_count, history.downloads[id]?.count ?? 0);
    history.downloads[id] = { count: best, object: c.object, platform: c.platform };
    files.push({ release: rel.tag_name, name: a.name, count: a.download_count, ...c });
  }
}

const snapshot = {
  updated: new Date().toISOString(),
  repo: {
    stars: repo.stargazers_count, forks: repo.forks_count, watchers: repo.subscribers_count,
    openIssues: repo.open_issues_count,
  },
  traffic14: { views: views.count, uniques: views.uniques, clones: clones.count, cloners: clones.uniques },
  referrers: referrers.map((r) => ({ source: r.referrer, count: r.count, uniques: r.uniques })),
  paths: paths.map((p) => ({ path: p.path, title: p.title, count: p.count, uniques: p.uniques })),
  stars: stars.map((s) => ({ at: s.starred_at, who: s.user.login })),
  files,
  history,
};

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify(await encrypt(snapshot)) + '\n');
const total = Object.values(history.downloads).reduce((n, d) => n + d.count, 0);
console.log(`Wrote ${OUT}: ${Object.keys(history.views).length} days of views, ${total} downloads, ${repo.stargazers_count} stars.`);
