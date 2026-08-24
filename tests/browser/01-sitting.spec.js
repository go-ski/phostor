const { test, expect } = require('@playwright/test');
const fs = require('fs');
const H = require('./helpers');

// These run in order against one phostor instance and one work directory: the
// point is the cumulative state on disk, which is what the R suite cannot see.
test.describe.configure({ mode: 'serial' });

let ids;

test('the app loads and the tree matches the photo directory', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  ids = await H.photoIds(page);
  expect(ids.length).toBeGreaterThanOrEqual(4);
  // No banner: Chrome can record.
  expect(await page.locator('.ph-warn').count()).toBe(0);
  // Nothing is recording before anyone asks.
  expect(await page.getAttribute('body', 'data-ph-mic')).toBe(null);
  await expect(page.locator('.ph-rec')).not.toHaveClass(/\bon\b/);
});

test('the microphone check finds the fake device and shows a level', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('#mic_check_btn');
  await page.waitForSelector('#ph-mic-panel:visible');
  await H.micState(page, 'on');

  // enumerateDevices() must have found the synthetic input and filled the picker.
  await expect.poll(async () =>
    page.locator('#ph-mic-device option').count()).toBeGreaterThan(0);

  // The fake device emits a tone, so the meter must move off zero. This is the
  // only assertion that proves audio is genuinely flowing into the page.
  await expect.poll(async () =>
    page.$eval('#ph-level-fill', (e) => parseFloat(e.style.width) || 0),
    { timeout: 15000 }).toBeGreaterThan(0);

  // The advice comes from ph_mic_advice() on the R side.
  await expect(page.locator('#ph-mic-advice')).toContainText(/Microphone open|Speak/);
  await expect(page.locator('#ph-mic-detail')).toContainText('audio/webm');

  // The three-second test recording exercises the same MediaRecorder path a
  // sitting uses, and hands back a playable blob.
  await page.click('#ph-mic-test');
  await page.waitForFunction(
    () => parseInt(document.body.dataset.phTest || '0', 10) > 0,
    null, { timeout: 20000 });
  await expect(page.locator('#ph-test-note')).toContainText('kB');

  // Closing releases the microphone, so the browser's recording indicator goes
  // out rather than staying on for the rest of the evening.
  await page.click('#ph-mic-close');
  await H.micState(page, 'off');
});

test('a sitting records visits, and a revisit gets its own sidecar', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  ids = await H.photoIds(page);

  await page.click('#start');
  // The consent banner is deliberately modal: the room is being recorded.
  await page.waitForSelector('.modal-content');
  await expect(page.locator('.modal-content')).toContainText('being recorded');
  await page.click('.modal-footer button');
  await H.micState(page, 'on');
  await expect(page.locator('.ph-rec')).toHaveClass(/\bon\b/);

  // Photograph 1: talk over it long enough for chunks to flow.
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

  const webms = H.visitFiles('.webm');
  expect(webms.length).toBe(3);
  for (const f of webms) H.expectValidWebm(f);

  // No half-written takes left behind.
  expect(H.visitFiles('.part').length).toBe(0);

  const first = fs.readFileSync(
    ymls.find((f) => f.endsWith('visit-0001.yml')), 'utf8');
  expect(first).toContain('Elgol, Isle of Skye');
  expect(first).toContain('transcript: ~');
});

test('the path reads in the order the evening took', async () => {
  const rows = H.pathRows();
  expect(rows[0].event).toBe('start');
  expect(rows[rows.length - 1].event).toBe('end');
  // show and leave must strictly alternate. An audio visit finalizes only once
  // the browser has flushed its last chunk, so a leave row written at finalize
  // time would land after the next photograph's show.
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
  // old recorder lands on a key the server no longer knows.
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
