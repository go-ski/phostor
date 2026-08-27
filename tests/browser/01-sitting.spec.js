const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const H = require('./helpers');

// These run in order against one phostor instance and one work directory. The
// assertions are on the cumulative state on disk, which the R suite cannot
// observe.
test.describe.configure({ mode: 'serial' });

let ids;

test('the client starts without throwing', async ({ page }) => {
  // First, because a throw while the message handlers register takes the whole
  // client down with it: every other spec then fails waiting on a tree that
  // will never appear, which says nothing about what actually went wrong.
  // Shiny rejecting a handler that does not take exactly one argument is one
  // way to get there.
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));

  await page.goto('/');
  await page.waitForSelector('.ph-tree', { timeout: 20000 }).catch(() => {});
  expect(errors, 'the client threw while starting').toEqual([]);
  await expect(page.locator('.ph-tree')).toBeVisible();
});

test('the app loads and the tree matches the photo directory', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  ids = await H.photoIds(page);
  expect(ids.length).toBeGreaterThanOrEqual(4);
  // No banner: Chrome can record.
  expect(await page.locator('.ph-warn').count()).toBe(0);
  // Nothing is recording before the microphone is requested.
  expect(await page.getAttribute('body', 'data-ph-mic')).toBe(null);
  await expect(page.locator('.ph-rec')).not.toHaveClass(/\bon\b/);
});

test('the microphone check finds the fake device and shows a level', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('#mic_check_btn');
  await page.waitForSelector('#ph-mic-panel:visible');
  await H.micState(page, 'on');

  // enumerateDevices() found the synthetic input and filled the picker.
  await expect.poll(async () =>
    page.locator('#ph-mic-device option').count()).toBeGreaterThan(0);

  // The fake device emits a tone, so the meter must move off zero. This is
  // what shows audio is reaching the page.
  await expect.poll(async () =>
    page.$eval('#ph-level-fill', (e) => parseFloat(e.style.width) || 0),
    { timeout: 15000 }).toBeGreaterThan(0);

  // The advice comes from ph_mic_advice() on the R side.
  await expect(page.locator('#ph-mic-advice')).toContainText(/Microphone open|Speak/);
  await expect(page.locator('#ph-mic-detail')).toContainText(/audio\/(mp4|ogg|webm)/);

  // The three-second test recording uses the same MediaRecorder path a sitting
  // does, and returns a playable blob.
  await page.click('#ph-mic-test');
  await page.waitForFunction(
    () => parseInt(document.body.dataset.phTest || '0', 10) > 0,
    null, { timeout: 20000 });
  await expect(page.locator('#ph-test-note')).toContainText('kB');

  // Closing releases the microphone, so the browser's recording indicator
  // turns off.
  await page.click('#ph-mic-close');
  await H.micState(page, 'off');
});

test('a sitting records visits, and a revisit gets its own sidecar', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  ids = await H.photoIds(page);

  await page.click('#start');
  // The notice is modal: recording has started.
  await page.waitForSelector('.modal-content');
  await expect(page.locator('.modal-content')).toContainText('being recorded');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await expect(page.locator('.ph-rec')).toHaveClass(/\bon\b/);

  // Photograph 1: wait long enough for chunks to be uploaded.
  await H.waitForVisitChunks(page);

  await page.fill('#place', 'Elgol, Isle of Skye');
  await page.fill('#event', 'the 1974 camping trip');
  await page.fill('#when', 'summer 1974');

  await H.openPhoto(page, ids[1]);
  await H.waitForVisitChunks(page);
  await page.fill('#place', 'Prague');

  await H.openPhoto(page, ids[0]);          // a revisit
  await H.waitForVisitChunks(page);

  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');

  // --- and now the disk ----------------------------------------------------
  const ymls = H.visitFiles('.yml');
  expect(ymls.length).toBe(3);
  expect(ymls.some((f) => f.endsWith('visit-0002.yml'))).toBe(true);

  const audio = H.audioFiles();
  expect(audio.length).toBe(3);
  for (const f of audio) H.expectValidAudio(f);

  // No half-written takes remain.
  expect(H.visitFiles('.part').length).toBe(0);

  // A visit records the recording. What was typed is a fact about the
  // photograph, so it lives in its tags.yml and the sidecar reserves the keys.
  const first = fs.readFileSync(
    ymls.find((f) => f.endsWith('visit-0001.yml')), 'utf8');
  expect(first).toContain('transcript: ~');
  expect(first).toContain('place: ~');

  const firstDir = path.dirname(ymls.find((f) => f.endsWith('visit-0001.yml')));
  const tags = fs.readFileSync(path.join(firstDir, 'tags.yml'), 'utf8');
  expect(tags).toContain('Elgol, Isle of Skye');
  expect(tags).toContain('summer 1974');
});

test('the path reads in the order photographs were viewed', async () => {
  const rows = H.pathRows();
  expect(rows[0].event).toBe('start');
  expect(rows[rows.length - 1].event).toBe('end');
  // show and leave alternate. An audio visit finalizes only once the browser
  // has flushed its last chunk, so a leave row written at finalize time would
  // land after the next photograph's show.
  const ev = rows.slice(1, -1).map((r) => r.event);
  expect(ev).toEqual(['show', 'leave', 'show', 'leave', 'show', 'leave']);
  for (let i = 0; i < ev.length; i += 2) {
    expect(rows[i + 1].rel_path).toBe(rows[i + 2].rel_path);
  }
  expect(rows.filter((r) => r.event === 'leave').map((r) => r.visit))
    .toEqual(['1', '1', '2']);
});

test('discard throws away the take and starts the photograph again', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const before = H.visitFiles('.yml').length;

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await H.waitForVisitChunks(page);

  const key = await page.getAttribute('body', 'data-ph-visit');
  await page.click('#discard');
  // A fresh visit opens under a new key, so any chunk still in flight from the
  // old recorder arrives with a key the server no longer knows.
  await page.waitForFunction(
    (k) => document.body.dataset.phVisit && document.body.dataset.phVisit !== k,
    key, { timeout: 20000 });

  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');

  const rows = H.pathRows();
  expect(rows.some((r) => r.event === 'discard')).toBe(true);
  // The discarded take wrote nothing, and the replacement wrote one sidecar.
  expect(H.visitFiles('.yml').length).toBe(before + 1);
  expect(H.visitFiles('.part').length).toBe(0);
});

test('pause closes the visit and resume opens a new one', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await H.waitForVisitChunks(page);

  await page.click('#pause');
  await H.micState(page, 'off');
  await expect(page.locator('.ph-rec')).not.toHaveClass(/\bon\b/);
  // Pausing offers Resume; a microphone that never opened offers a retry.
  await expect(page.locator('#resume')).toBeVisible();

  await page.click('#resume');
  await H.micState(page, 'on');

  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');

  const ev = H.pathRows().map((r) => r.event);
  expect(ev).toContain('pause');
  expect(ev).toContain('resume');
});

// --- audio completeness -----------------------------------------------------
// The specs above prove each recording is a valid container. They do not prove it
// holds everything the microphone produced, which is how the dropped-final-
// chunk bug survived them.

test('every byte the microphone produced reached a file', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  // window.PH counts only this page's visits, so compare against the growth of
  // the store rather than its total, which includes the specs above.
  const storedBefore = H.bytesStored();

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');

  // Three visits, each long enough to cross at least one chunk boundary, so
  // there is both a mid-visit chunk and a tail flushed by stop().
  await H.waitForVisitChunks(page, 2);
  await H.openPhoto(page, ids[1]);
  await H.waitForVisitChunks(page, 2);
  await H.openPhoto(page, ids[2]);
  await H.waitForVisitChunks(page, 2);

  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');

  // MediaRecorder counts what it handed to the page; the filesystem counts what
  // was stored. A tail dropped at close makes stored fall short of produced.
  const produced = await H.bytesProduced(page);
  expect(produced).toBeGreaterThan(0);
  expect(H.bytesStored() - storedBefore).toBe(produced);

  // And nothing was reported as incomplete on screen.
  expect(await page.locator('.ph-warn-integrity').count()).toBe(0);
});

test('a visit shorter than one chunk still records its audio', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  const before = H.audioFiles().length;

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');

  // Leave before a single chunk interval has elapsed. Everything recorded is
  // in the tail that stop() flushes, so if that tail is lost the visit has no
  // audio at all rather than merely a short file.
  await page.waitForFunction(() => !!document.body.dataset.phVisit);
  await H.openPhoto(page, ids[1]);

  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');

  const audio = H.audioFiles();
  expect(audio.length).toBeGreaterThan(before);
  for (const f of audio.slice(before)) H.expectValidAudio(f, 64);
  expect(H.visitFiles('.part').length).toBe(0);
});

// --- the protocol under interference ----------------------------------------
// A sitting cannot be repeated, so the ways a recorder can be taken away
// mid-visit matter as much as the happy path.

test('checking the microphone mid-sitting does not cut the recording', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  const storedBefore = H.bytesStored();

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await H.waitForVisitChunks(page, 2);

  // Reopening the microphone here would hand the page a second MediaStream and
  // end the tracks the live recorder is reading, stopping it with nothing on
  // screen to say so. The check must meter the stream the sitting already has.
  await page.click('#mic_check_btn');
  await page.waitForSelector('#ph-mic-panel:visible');
  await expect(page.locator('#ph-mic-sitting')).toBeVisible();
  await expect(page.locator('#ph-mic-device')).toBeDisabled();
  await page.click('#ph-mic-close');

  // Still the same visit, still recording: its chunk count keeps climbing.
  const n = await page.evaluate(() =>
    parseInt(document.body.dataset.phVisitChunks || '0', 10));
  await H.waitForVisitChunks(page, n + 2);

  await H.openPhoto(page, ids[1]);
  await H.waitForVisitChunks(page, 2);
  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');

  const produced = await H.bytesProduced(page);
  expect(produced).toBeGreaterThan(0);
  expect(H.bytesStored() - storedBefore).toBe(produced);
  expect(await page.locator('.ph-warn-integrity').count()).toBe(0);
});

test('a visit whose recorder never reports stopping still finalises', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  const before = H.audioFiles().length;

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await H.waitForVisitChunks(page, 2);

  // Break the one signal the close path waits on. Unbounded, that wait leaves
  // the visit unfinalised for ever: End sitting never answers and the .part is
  // never renamed.
  await page.evaluate(() => { window.PH.rec.onstop = function () {}; });

  await H.openPhoto(page, ids[1]);
  await H.waitForVisitChunks(page, 1);
  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")',
                             { timeout: 30000 });
  await page.click('.modal-footer button');

  expect(H.audioFiles().length).toBeGreaterThan(before);
  expect(H.visitFiles('.part').length).toBe(0);
});

test('a recorder that cannot start says so instead of showing REC', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await page.click('#start');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await H.waitForVisitChunks(page, 1);

  // Take the stream away, the way an unplugged interface or a revoked
  // permission does. The next visit gets no recorder at all, and the server
  // has already opened a .part for it.
  await page.evaluate(() => { window.PH.stream = null; });
  await H.openPhoto(page, ids[1]);

  // The bar must stop claiming to record, and say what to do about it.
  await H.micState(page, 'error');
  await expect(page.locator('.ph-rec')).not.toHaveClass(/\bon\b/);
  await expect(page.locator('#sitting_info')).toContainText(/microphone/i);

  await page.click('#stop_sitting');
  await page.waitForSelector('.modal-content:has-text("Sitting ended")');
  await page.click('.modal-footer button');
  expect(H.visitFiles('.part').length).toBe(0);
});
