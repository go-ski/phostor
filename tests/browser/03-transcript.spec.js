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
  if (H.sessionCount() === 0) await H.recordShortSession(page);
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
  if (H.sessionCount() === 0) await H.recordShortSession(page);
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
  if (H.sessionCount() === 0) await H.recordShortSession(page);
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
  if (H.sessionCount() === 0) await H.recordShortSession(page);
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

test('the words light up while the session plays back', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSession(page);
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

test('a phrase can be told who said it', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSession(page);
  const { id, visit } = plantTranscript();

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-ph`);

  // A chip marks where the voice changed, and nothing is named yet, so every
  // phrase is a change of its own and every one offers a chip reading "+".
  const chips = page.locator(`#ph-tx-${visit} .ph-spk`);
  await expect(chips).toHaveCount(PHRASES.length);
  await expect(chips.first()).toHaveText('+');

  await chips.first().click();
  await page.waitForSelector('.modal-content');
  await expect(page.locator('.modal-content')).toContainText('Who said this?');
  await page.click('#speaker_name + .selectize-control .selectize-input');
  await page.keyboard.type('Nana Vera');
  await page.keyboard.press('Enter');
  await page.click('#speaker_save');

  // The chip carries the name, and it is on disk as a person's answer.
  await expect(page.locator(`#ph-tx-${visit} .ph-spk`).first())
    .toHaveText('Nana Vera');
  const f = H.visitFiles('-speakers.tsv')[0];
  expect(f, 'no labels file was written').toBeDefined();
  const rows = fs.readFileSync(f, 'utf8').trim().split('\n');
  expect(rows[0]).toBe('start\tend\tspeaker\tsource\tconfidence');
  expect(rows[1]).toContain('Nana Vera');
  expect(rows[1]).toContain('manual');
});

test('a name can be taken off again', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const { id, visit } = plantTranscript();
  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-spk`);

  await page.locator(`#ph-tx-${visit} .ph-spk`).first().click();
  await page.waitForSelector('.modal-content');
  await page.click('#speaker_clear');
  await expect(page.locator(`#ph-tx-${visit} .ph-spk`).first()).toHaveText('+');
});

test('a name given on one photograph is offered on the next', async ({ page }) => {
  // The blank slate: the picker used to read only the photograph on screen, so
  // a name had to be retyped on every one of them.
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSession(page);
  const planted = plantAll();
  expect(planted.length).toBeGreaterThan(1);

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, planted[0].id);
  await page.waitForSelector(`#ph-tx-${planted[0].visit} .ph-spk`);
  await page.locator(`#ph-tx-${planted[0].visit} .ph-spk`).first().click();
  await page.waitForSelector('.modal-content');
  await page.click('#speaker_name + .selectize-control .selectize-input');
  await page.keyboard.type('Uncle Stefan');
  await page.keyboard.press('Enter');
  await page.click('#speaker_save');
  await expect(page.locator('.modal-content')).toHaveCount(0);

  // A different photograph of the same session: the name is on offer.
  await H.openPhoto(page, planted[1].id);
  await page.waitForSelector(`#ph-tx-${planted[1].visit} .ph-spk`);
  await page.locator(`#ph-tx-${planted[1].visit} .ph-spk`).first().click();
  await page.waitForSelector('.modal-content');
  await expect.poll(() => page.evaluate(() => {
    const el = document.getElementById('speaker_name');
    return el && el.selectize ? Object.keys(el.selectize.options) : [];
  })).toContain('Uncle Stefan');
  await page.click('.modal-footer button:has-text("Cancel")');
});

test('naming a phrase says why the names will not spread', async ({ page }) => {
  // Only meaningful where tuneR is absent -- which is the machine this is
  // about: the label must save and the app must say why nothing else happened,
  // rather than doing nothing in silence. Where the package is installed the
  // case cannot be staged at all.
  test.skip(H.hasTuneR(), 'tuneR is installed, so it can spread and says nothing');
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSession(page);
  const { id, visit } = plantTranscript();
  // Earlier specs in this file have named phrases on this very visit. This one
  // is about the notice, not about what they left behind, so it starts clean.
  for (const f of H.visitFiles('-speakers.tsv')) fs.unlinkSync(f);

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-spk`);
  await expect(page.locator(`#ph-tx-${visit} .ph-spk`).first()).toHaveText('+');

  // The picker says it too, at the moment you are thinking about names.
  await page.locator(`#ph-tx-${visit} .ph-spk`).first().click();
  await page.waitForSelector('.modal-content');
  await expect(page.locator('.modal-content')).toContainText('tuneR');

  await page.click('#speaker_name + .selectize-control .selectize-input');
  await page.keyboard.type('Nana Vera');
  await page.keyboard.press('Enter');
  await page.click('#speaker_save');

  await expect(page.locator('.shiny-notification')).toContainText('tuneR');
  // And the name was saved regardless: never raising is still the rule.
  await expect(page.locator(`#ph-tx-${visit} .ph-spk`).first())
    .toHaveText('Nana Vera');
});

// Name a phrase through the dialog, given its chip.
async function nameVia(page, chip, name) {
  await chip.click();
  await page.waitForSelector('.modal-content');
  await page.click('#speaker_name + .selectize-control .selectize-input');
  await page.keyboard.type(name);
  await page.keyboard.press('Enter');
  await page.click('#speaker_save');
  await page.waitForSelector('.modal-content', { state: 'detached' });
}

test('one voice carrying on gets one chip, not one per sentence', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSession(page);
  const { id, visit } = plantTranscript();
  for (const f of H.visitFiles('-speakers.tsv')) fs.unlinkSync(f);

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-spk`);

  const chips = page.locator(`#ph-tx-${visit} .ph-spk`);
  await expect(chips).toHaveCount(3);

  await nameVia(page, chips.first(), 'Nana Vera');
  await expect(chips.first()).toHaveText('Nana Vera');
  // The same person again: the second sentence stops carrying a chip, because
  // nobody changed.
  await nameVia(page, chips.nth(1), 'Nana Vera');
  await expect(chips).toHaveCount(2);
  await expect(chips.first()).toHaveText('Nana Vera');
  await expect(chips.nth(1)).toHaveText('+');

  // The run is a person's own answer throughout, so it is filled rather than
  // dashed, and carries that voice's colour.
  await expect(chips.first()).toHaveClass(/\bs1\b/);
  await expect(chips.first()).not.toHaveClass(/\bguess\b/);

  // A different voice is a change, so a chip comes back -- in its own colour.
  await nameVia(page, chips.nth(1), 'Uncle Stefan');
  await expect(chips).toHaveCount(2);
  await expect(chips.nth(1)).toHaveText('Uncle Stefan');
  await expect(chips.nth(1)).toHaveClass(/\bs2\b/);
});

test('Same as above takes a chip away', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const { id, visit } = plantTranscript();
  for (const f of H.visitFiles('-speakers.tsv')) fs.unlinkSync(f);

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-spk`);
  const chips = page.locator(`#ph-tx-${visit} .ph-spk`);
  await nameVia(page, chips.first(), 'Nana Vera');

  await chips.nth(1).click();
  await page.waitForSelector('.modal-content');
  await expect(page.locator('#speaker_same')).toContainText('Nana Vera');
  await page.click('#speaker_same');
  await page.waitForSelector('.modal-content', { state: 'detached' });
  await expect(chips).toHaveCount(2);

  // Written as a person's answer, so tidying the transcript also teaches.
  const f = H.visitFiles('-speakers.tsv')[0];
  const rows = fs.readFileSync(f, 'utf8').trim().split('\n');
  expect(rows.length).toBe(3);
  expect(rows.filter((r) => r.includes('manual')).length).toBe(2);
});

test('a sentence holding two voices can be divided', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const { id, visit } = plantTranscript();
  for (const f of H.visitFiles('-speakers.tsv')) fs.unlinkSync(f);
  for (const f of H.visitFiles('-edits.tsv')) fs.unlinkSync(f);

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-ph`);
  const phrases = page.locator(`#ph-tx-${visit} .ph-ph`);
  await expect(phrases).toHaveCount(PHRASES.length);

  // Double-click opens the correction dialog; single click seeks the audio,
  // which is why it takes the second one.
  await phrases.first().dblclick();
  await page.waitForSelector('.modal-content');
  await expect(page.locator('.modal-content')).toContainText('Correct this phrase');

  await page.fill('#phrase_before', 'This was taken');
  await page.fill('#phrase_after', 'down by the river');
  await page.fill('#phrase_split_at', '1.2');
  await page.click('#phrase_split');

  // Dividing a sentence is only ever done because the voice changed, so it
  // goes straight on to ask who the second half was.
  await page.waitForSelector('.modal-content');
  await expect(page.locator('.modal-content')).toContainText('Who said this?');
  await page.click('#speaker_name + .selectize-control .selectize-input');
  await page.keyboard.type('Uncle Stefan');
  await page.keyboard.press('Enter');
  await page.click('#speaker_save');
  await page.waitForSelector('.modal-content', { state: 'detached' });

  await expect(phrases).toHaveCount(PHRASES.length + 1);
  await expect(phrases.nth(0)).toHaveText('This was taken');
  await expect(phrases.nth(1)).toHaveText('down by the river');

  // The correction is in its own file: visit-NNNN.tsv belongs to the
  // transcriber and is never rewritten, so `transcribe --force` cannot undo
  // this and this cannot undo that.
  const f = H.visitFiles('-edits.tsv')[0];
  expect(f, 'no edits file was written').toBeDefined();
  const rows = fs.readFileSync(f, 'utf8').trim().split('\n');
  expect(rows[0]).toBe('orig\tstart\tend\ttext');
  expect(rows[1]).toBe('0.000\t0.000\t1.200\tThis was taken');
  expect(rows[2]).toBe('0.000\t1.200\t2.500\tdown by the river');

  const tsv = H.visitFiles('.tsv')
    .filter((x) => /^visit-\d+\.tsv$/.test(path.basename(x)));
  expect(fs.readFileSync(tsv[0], 'utf8')).toContain(PHRASES[0].text);
});

test('the dialog never arrives with a name nobody chose', async ({ page }) => {
  // A <select> whose selected value is not among its options falls back to the
  // first one. With names already known, opening this on an unnamed phrase
  // used to arrive with whoever sorts first already chosen, and Save then
  // attributed the phrase to them. A hand label is ground truth and the voices
  // are learned from it, so a name nobody typed is worse here than elsewhere.
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  if (H.sessionCount() === 0) await H.recordShortSession(page);
  const { id, visit } = plantTranscript();
  for (const f of H.visitFiles('-speakers.tsv')) fs.unlinkSync(f);
  for (const f of H.visitFiles('-edits.tsv')) fs.unlinkSync(f);

  await page.reload();
  await page.waitForSelector('.ph-tree');
  await H.openPhoto(page, id);
  await page.waitForSelector(`#ph-tx-${visit} .ph-spk`);
  const chips = page.locator(`#ph-tx-${visit} .ph-spk`);
  await nameVia(page, chips.first(), 'Aaron');

  // A different phrase, with a name now in the picker.
  await chips.nth(1).click();
  await page.waitForSelector('.modal-content');
  expect(await page.evaluate(
    () => document.getElementById('speaker_name').value)).toBe('');
  await page.click('.modal-footer button:has-text("Cancel")');
  await page.waitForSelector('.modal-content', { state: 'detached' });

  // And nothing was written for it.
  const rows = fs.readFileSync(H.visitFiles('-speakers.tsv')[0], 'utf8')
    .trim().split('\n');
  expect(rows.length).toBe(2);
  expect(rows[1]).toContain('Aaron');

  // A divided phrase outlives this file, and the later ones assert on the same
  // work directory. The label files are left alone -- the specs above this one
  // make those too, and they are part of what the rest expect to find.
  for (const f of H.visitFiles('-edits.tsv')) fs.unlinkSync(f);
});
