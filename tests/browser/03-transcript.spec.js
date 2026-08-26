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

// Plant a distinct transcript on every recorded visit, so the panel's text
// says which photograph it belongs to.
function plantAll() {
  const out = [];
  for (const yml of H.visitFiles('.yml')) {
    const dir = path.dirname(yml);
    const stem = path.basename(yml, '.yml');
    const rel = path.relative(H.sidecars(), dir).split(path.sep).join('/');
    const visit = parseInt(stem.replace('visit-', ''), 10);
    const id = H.indexIds()[rel];
    if (id === undefined) continue;
    const words = `spoken about photograph ${id} visit ${visit}`;
    fs.writeFileSync(path.join(dir, `${stem}.tsv`),
      ['start\tend\ttext',
       `0.000\t1.500\t${words}`,
       `1.500\t600.000\tand then a great deal more about photograph ${id}`,
      ].join('\n') + '\n');
    fs.writeFileSync(path.join(dir, `${stem}.txt`), words + '\n');
    out.push({ id, visit, words });
  }
  return out;
}

test('the panel follows the playback instead of staying behind', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  const planted = plantAll();
  expect(planted.length, 'nothing recorded to play back').toBeGreaterThan(1);

  await page.reload();
  await page.waitForSelector('#play');

  // Start somewhere that is not where the playback begins, which is the shape
  // of the bug: the panel used to stay on this one for the whole playback.
  const elsewhere = planted[planted.length - 1].id;
  await H.openPhoto(page, elsewhere);

  await page.click('#play');
  await page.waitForSelector('#play_stop');

  // Read in one evaluation: the playback advances on its own, so asking for
  // the photograph and the panel separately can straddle a change. And it has
  // to be a photograph other than the one we started on -- the playlist comes
  // back to that one, where a panel that never followed agrees by accident.
  // Both of those made an earlier version of this test pass against the bug.
  await expect.poll(() => page.evaluate((was) => {
    const panel = document.querySelector('.ph-hist');
    if (!panel) return 'no panel';
    const now = window.PH.current;
    if (now === was) return 'still on the starting photograph';
    return panel.dataset.photo === String(now)
      ? 'followed' : `panel is ${panel.dataset.photo}, playing ${now}`;
  }, elsewhere), { timeout: 30000 }).toBe('followed');

  // And it is really that photograph's words, not just its number.
  const state = await page.evaluate(() => ({
    id: window.PH.current,
    text: document.querySelector('.ph-hist').innerText,
  }));
  expect(state.text).toContain(`photograph ${state.id} `);

  if (await page.locator('#play_stop').count()) await page.click('#play_stop');
});

test('the words light up while the sitting plays back', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  const planted = plantAll();

  await page.reload();
  await page.waitForSelector('#play');
  // Start away from where the playback begins, and only look once it has moved
  // on. Otherwise the panel is the playing photograph's by coincidence and the
  // highlight would appear whether or not the panel ever followed.
  const elsewhere = planted[planted.length - 1].id;
  await H.openPhoto(page, elsewhere);

  await page.click('#play');
  await page.waitForSelector('#play_stop');
  await page.waitForFunction((was) => window.PH.current !== was, elsewhere,
                             { timeout: 30000 });

  // The playback audio is detached from the document, so this is the path that
  // does not go through the delegated timeupdate listener.
  //
  // One evaluation again: a phrase lit in a panel belonging to some other
  // photograph is exactly the bug, so the two have to be read together.
  await expect.poll(() => page.evaluate((was) => {
    const panel = document.querySelector('.ph-hist');
    if (!panel) return 'no panel';
    const now = window.PH.current;
    if (now === was) return 'still on the starting photograph';
    if (panel.dataset.photo !== String(now)) return 'panel has not followed';
    return panel.querySelector('.ph-ph.on') ? 'lit' : 'nothing lit yet';
  }, elsewhere), { timeout: 30000 }).toBe('lit');

  if (await page.locator('#play_stop').count()) await page.click('#play_stop');
  // Stopping takes the highlight with it.
  await expect.poll(() => page.locator('.ph-ph.on').count()).toBe(0);
});
