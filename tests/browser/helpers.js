const fs = require('fs');
const path = require('path');
const { expect } = require('@playwright/test');

const WORK = process.env.PHOSTOR_WORK;
const PHOTOS = process.env.PHOSTOR_PHOTOS;

if (!WORK) throw new Error('PHOSTOR_WORK is not set; run tests/browser/run.sh');

const sidecars = () => path.join(WORK, 'sidecars');

// Every visit sidecar in the project, as repo-relative paths.
function visitFiles(ext) {
  const out = [];
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.startsWith('visit-') && e.name.endsWith(ext)) out.push(p);
    }
  };
  walk(sidecars());
  return out.sort();
}

// The newest sitting's path.tsv, parsed into rows.
function pathRows() {
  const sdir = path.join(WORK, 'sessions');
  if (!fs.existsSync(sdir)) return [];
  const sessions = fs.readdirSync(sdir).sort();
  if (!sessions.length) return [];
  const f = path.join(sdir, sessions[sessions.length - 1], 'path.tsv');
  if (!fs.existsSync(f)) return [];
  const lines = fs.readFileSync(f, 'utf8').trim().split('\n');
  const head = lines[0].split('\t');
  return lines.slice(1).map((l) => {
    const c = l.split('\t');
    return Object.fromEntries(head.map((h, i) => [h, c[i]]));
  });
}

// A WebM file begins with the EBML magic 1A 45 DF A3. There is no ffmpeg on
// this machine, so the header is the check that the chunks the browser sent
// really did concatenate into a playable container rather than a pile of bytes.
function expectValidWebm(file, minBytes = 512) {
  const buf = fs.readFileSync(file);
  expect(buf.length, `${path.basename(file)} is too small`).toBeGreaterThan(minBytes);
  expect(
    Array.from(buf.subarray(0, 4)),
    `${path.basename(file)} does not start with the EBML magic`
  ).toEqual([0x1a, 0x45, 0xdf, 0xa3]);
  // The Opus identification header sits in the track's CodecPrivate. Finding it
  // proves the concatenated chunks carry a real Opus stream, not merely a
  // container header followed by rubble -- and needs no ffmpeg to check.
  expect(
    buf.includes(Buffer.from('OpusHead')),
    `${path.basename(file)} carries no Opus stream`
  ).toBe(true);
}

// Wait for the mic to reach a state, using the app's own DOM hooks rather than
// a sleep. body[data-ph-mic] is off | arming | on | error.
async function micState(page, state) {
  await page.waitForSelector(`body[data-ph-mic="${state}"]`);
}

// Chunks are acknowledged one at a time by the server, and the app counts them
// on <body>. Wait on the PER-VISIT count, never the global one: when a visit
// closes, its recorder flushes a final chunk, which would otherwise satisfy a
// global "wait for one more" and let the spec navigate away before the next
// photograph has recorded anything at all.
async function waitForVisitChunks(page, atLeast = 1) {
  await page.waitForFunction(
    (n) => parseInt(document.body.dataset.phVisitChunks || '0', 10) >= n,
    atLeast,
    { timeout: 30000 }
  );
}

// How many sittings this project holds.
function sessionCount() {
  const d = path.join(WORK, 'sessions');
  return fs.existsSync(d) ? fs.readdirSync(d).length : 0;
}

// Record a short sitting, so a spec that needs one to exist can stand alone
// rather than depending on which file Playwright happened to run first.
async function recordShortSitting(page) {
  const ids = await photoIds(page);
  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await micState(page, 'on');
  await waitForVisitChunks(page);
  await openPhoto(page, ids[1]);
  await waitForVisitChunks(page);
  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');
}

// The tree rows, in the order the app shows them.
async function photoIds(page) {
  return page.$$eval('.ph-p', (els) =>
    els.map((e) => parseInt(e.id.replace('ph-p-', ''), 10))
  );
}

async function openPhoto(page, id) {
  await page.click(`#ph-p-${id}`);
  await page.waitForFunction(
    (i) => document.getElementById('ph-photo').src.includes(`/display/${i}.jpg`),
    id
  );
}

module.exports = { WORK, PHOTOS, sidecars, visitFiles, pathRows,
                   expectValidWebm, micState, waitForVisitChunks, photoIds,
                   openPhoto, sessionCount, recordShortSitting };
