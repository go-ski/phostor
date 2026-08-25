const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

// The fake device emits a tone, not speech, so no real transcript can be made
// here. These specs plant one instead: what is under test is the panel that
// displays it and the clock that follows it, not the transcriber, which the R
// suite covers against actual speech.
const PHRASES = [
  { t0: 0.000, t1: 2.500, text: 'This was taken down by the river' },
  { t0: 2.500, t1: 5.250, text: "that is Kate's dog, #4 in the litter" },
  { t0: 5.250, t1: 7.000, text: 'and the car we drove up in' },
];

// Plant a transcript beside the first recorded visit, and return the tree id
// of the photograph it belongs to.
function plantTranscript() {
  const ymls = H.visitFiles('.yml');
  expect(ymls.length, 'no recorded visit to attach a transcript to')
    .toBeGreaterThan(0);
  const yml = ymls[0];
  const dir = path.dirname(yml);
  const stem = path.basename(yml, '.yml');
  const rel = path.relative(H.sidecars(), dir);

  fs.writeFileSync(path.join(dir, `${stem}.tsv`),
    ['start\tend\ttext',
     ...PHRASES.map((p) => `${p.t0.toFixed(3)}\t${p.t1.toFixed(3)}\t${p.text}`),
    ].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, `${stem}.txt`),
    PHRASES.map((p) => p.text).join(' ') + '\n');

  const visit = parseInt(stem.replace('visit-', ''), 10);
  // rel_path uses forward slashes in index.tsv, as on disk here.
  const id = H.indexIds()[rel.split(path.sep).join('/')];
  expect(id, `no catalogue row for ${rel}`).toBeDefined();
  return { id, visit };
}

// Drive the follow-along without loading audio: the handler reads
// currentTime off the event target, so an overridable property and a
// synthetic event exercise exactly the path a playing recording takes.
async function seekTo(page, visit, t) {
  await page.evaluate(([v, time]) => {
    const a = document.getElementById('ph-a-' + v);
    if (!Object.getOwnPropertyDescriptor(a, 'currentTime')) {
      let now = 0;
      Object.defineProperty(a, 'currentTime',
        { get: () => now, set: (x) => { now = x; }, configurable: true });
    }
    a.currentTime = time;
    a.dispatchEvent(new Event('timeupdate'));
  }, [visit, t]);
}

test('a transcript appears under the photograph it belongs to', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  const { id, visit } = plantTranscript();

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);

  // Every phrase is on screen, carrying the times the highlight needs.
  const spans = page.locator(`#ph-tx-${visit} .ph-ph`);
  await expect(spans).toHaveCount(PHRASES.length);
  await expect(spans.first()).toHaveAttribute('data-t0', '0.000');
  await expect(spans.nth(1)).toHaveText(PHRASES[1].text);
  // The panel is open without being clicked: reading is the point of it.
  await expect(spans.first()).toBeVisible();
  // And the recording is there to play.
  await expect(page.locator(`#ph-a-${visit}`)).toHaveCount(1);
});

test('the words light up as the recording reaches them', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  const { id, visit } = plantTranscript();

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-ph`);

  const lit = () => page.$$eval(`#ph-tx-${visit} .ph-ph`,
    (els) => els.findIndex((e) => e.classList.contains('on')));

  await seekTo(page, visit, 1.0);
  await expect.poll(lit).toBe(0);
  await seekTo(page, visit, 3.0);
  await expect.poll(lit).toBe(1);
  await seekTo(page, visit, 6.0);
  await expect.poll(lit).toBe(2);

  // A gap between two phrases holds the earlier one rather than blinking off.
  await seekTo(page, visit, 2.4);
  await expect.poll(lit).toBe(0);

  // Past the end, nothing is lit.
  await seekTo(page, visit, 30);
  await expect.poll(lit).toBe(-1);
});

test('clicking a phrase seeks the recording to it', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  const { id, visit } = plantTranscript();

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-ph`);
  // Make currentTime writable and play() a no-op: this asserts where the
  // click seeks to, not that the browser can decode a tone.
  await page.evaluate((v) => {
    const a = document.getElementById('ph-a-' + v);
    let now = 0;
    Object.defineProperty(a, 'currentTime',
      { get: () => now, set: (x) => { now = x; }, configurable: true });
    a.play = () => Promise.resolve();
  }, visit);

  await page.locator(`#ph-tx-${visit} .ph-ph`).nth(2).click();
  const at = await page.evaluate(
    (v) => document.getElementById('ph-a-' + v).currentTime, visit);
  expect(at).toBeCloseTo(PHRASES[2].t0, 3);
});
