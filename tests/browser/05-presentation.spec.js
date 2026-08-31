const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

const body = (page) => page.locator('body');
const inPresent = (page) => page.evaluate(() =>
  document.body.classList.contains('ph-present'));
const inFull = (page) => page.evaluate(() => !!document.fullscreenElement);
const photoWidth = async (page) =>
  Math.round((await page.locator('.ph-img-wrap').boundingBox()).width);
// Clicking the button is a server round trip, unlike the keys, so its effect
// is waited for rather than read straight back.

test('the Presentation button enters, and says how to leave', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  const narrow = await photoWidth(page);

  await page.click('#present');
  await expect(body(page)).toHaveClass(/ph-present/);
  // Full screen too: one mode, and the button gets it as well as the key,
  // which it could not while it went through the server.
  await expect.poll(() => inFull(page)).toBe(true);
  // The sidebar's column collapses with it, rather than leaving its width as
  // empty space down the left.
  expect(await photoWidth(page),
         'the sidebar column did not collapse').toBeGreaterThan(narrow);
  // The way out is on screen, because the sidebar that used to say it is now
  // hidden.
  await expect(page.locator('#ph-present-hint')).toHaveClass(/\bon\b/);
  await expect(page.locator('#ph-present-hint')).toBeVisible();
  // And it goes again, rather than sitting over the photograph.
  await expect(page.locator('#ph-present-hint'))
    .not.toHaveClass(/\bon\b/, { timeout: 6000 });
  expect(await inPresent(page)).toBe(true);
});

test('Escape leaves presentation, and never enters it', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  // Escape outside presentation does nothing.
  await page.keyboard.press('Escape');
  expect(await inPresent(page)).toBe(false);

  await page.keyboard.press('s');
  expect(await inPresent(page)).toBe(true);
  await page.keyboard.press('Escape');
  await expect.poll(() => inPresent(page)).toBe(false);
  await expect.poll(() => inFull(page)).toBe(false);
});

test('leaving full screen leaves presentation with it', async ({ page }) => {
  // The browser's own Escape and its own full-screen control both leave
  // without telling the page, so presentation must follow rather than be
  // stranded on with nothing hiding it.
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  await page.keyboard.press('s');
  await expect.poll(() => inFull(page)).toBe(true);

  await page.evaluate(() => document.exitFullscreen());
  await expect.poll(() => inPresent(page)).toBe(false);
  await expect(page.locator('.ph-tags')).toBeVisible();
});

test('f no longer does anything', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  await page.keyboard.press('f');
  await page.waitForTimeout(300);
  expect(await inFull(page)).toBe(false);
  expect(await inPresent(page)).toBe(false);
});

test('up and down move through the photographs like left and right', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  await H.openPhoto(page, ids[0]);
  await page.click('.ph-img-wrap');

  const shows = (i) => H.showing(page, ids[i]);

  await page.keyboard.press('ArrowDown');
  await shows(1);
  await page.keyboard.press('ArrowDown');
  await shows(2);
  await page.keyboard.press('ArrowUp');
  await shows(1);
  // Mixed with the other pair, they are the same movement.
  await page.keyboard.press('ArrowRight');
  await shows(2);
  await page.keyboard.press('ArrowLeft');
  await shows(1);

  // At the ends they stop rather than wrapping.
  await page.keyboard.press('ArrowUp');
  await shows(0);
  await page.keyboard.press('ArrowUp');
  await shows(0);
});

test('up and down move in presentation too', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  await H.openPhoto(page, ids[0]);
  await page.click('.ph-img-wrap');

  await page.keyboard.press('s');
  await expect(body(page)).toHaveClass(/ph-present/);
  await page.keyboard.press('ArrowDown');
  await H.showing(page, ids[1]);
  await page.keyboard.press('Escape');
});

test('the button still works after leaving with the key', async ({ page }) => {
  // The button used to hold its own idea of the state, so entering with it and
  // leaving with the key left the two disagreeing: the next click sent "off"
  // to a page already off, and appeared to do nothing.
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  await page.click('#present');
  await expect(body(page)).toHaveClass(/ph-present/);

  await page.click('.ph-img-wrap');
  await page.keyboard.press('s');
  expect(await inPresent(page)).toBe(false);

  await page.click('#present');
  await expect(body(page)).toHaveClass(/ph-present/);   // one click, not two
});

test('b folds away what is under the photograph', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  await expect(page.locator('.ph-tags')).toBeVisible();
  // The visits panel arrives in a later flush than the fields do, and it is
  // part of what b folds away. Measuring before it lands weighs one layout
  // against another and the heights never match.
  await page.waitForSelector('.ph-hist');
  const before = (await page.locator('.ph-img-wrap').boundingBox()).height;

  await page.keyboard.press('b');
  await expect(body(page)).toHaveClass(/ph-nobottom/);
  await expect(page.locator('.ph-tags')).toBeHidden();
  await expect(page.locator('.ph-hist-wrap')).toBeHidden();
  // The caption stays: a photograph on screen still says what it is.
  await expect(page.locator('#ph-cap')).toBeVisible();

  const after = (await page.locator('.ph-img-wrap').boundingBox()).height;
  expect(after, 'the photograph did not gain the space').toBeGreaterThan(before);

  await page.keyboard.press('b');
  await expect(page.locator('.ph-tags')).toBeVisible();
  expect((await page.locator('.ph-img-wrap').boundingBox()).height)
    .toBeCloseTo(before, 0);
});

test('the two toggles do not disturb each other', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  await page.keyboard.press('b');
  await page.keyboard.press('s');            // into presentation
  await page.keyboard.press('Escape');       // and out again
  // The bottom was folded before presentation, and still is after it.
  await expect(body(page)).toHaveClass(/ph-nobottom/);
  await expect(page.locator('.ph-tags')).toBeHidden();
  await page.keyboard.press('b');
  await expect(page.locator('.ph-tags')).toBeVisible();
});

test('typing the letters does not trigger the toggles', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  // Emptied first: by the time the whole suite reaches here the field may
  // already hold tags an earlier spec typed, and this needs real keystrokes
  // rather than fill() so the b and s keys are actually pressed.
  await page.fill('#place', '');
  await page.click('#place');
  await page.keyboard.type('Bridge by the sea');
  await page.keyboard.press('ArrowUp');      // moves the cursor, not the photo
  await page.keyboard.press('ArrowDown');
  expect(await inPresent(page)).toBe(false);
  await expect(body(page)).not.toHaveClass(/ph-nobottom/);
  await expect(page.locator('#place')).toHaveValue('Bridge by the sea');
});

test('the recording indicator shares the line the title is on', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  // In the navbar, not in the bar above the photograph: that bar is what
  // presentation hides, and a full-width row carrying one pill was the space
  // presentation was losing at the top.
  await expect(page.locator('.navbar .ph-rec')).toBeVisible();
  expect(await page.locator('.ph-bar .ph-rec').count()).toBe(0);

  // On the title's line, and at the far end of it.
  const title = await page.locator('.bslib-page-title').boundingBox();
  const rec = await page.locator('.ph-rec').boundingBox();
  expect(Math.abs((rec.y + rec.height / 2) - (title.y + title.height / 2)),
         'the indicator is not on the title line').toBeLessThan(8);
  expect(rec.x, 'the indicator is not at the end of the line')
    .toBeGreaterThan(title.x + title.width);
});

test('presentation leaves one line of text above the photograph', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');
  // As above: the frame gives up height when the visits panel lands, so the
  // two measurements have to be of the same layout.
  await page.waitForSelector('.ph-hist');

  const before = (await page.locator('.ph-img-wrap').boundingBox()).height;

  await page.keyboard.press('s');
  await expect(body(page)).toHaveClass(/ph-present/);
  // The bar the indicator used to sit in goes with everything else.
  await expect(page.locator('.ph-bar')).toBeHidden();
  await expect(page.locator('.navbar .ph-rec')).toBeVisible();
  // The caption stays: a photograph on a wall of screen still says what it is.
  await expect(page.locator('#ph-cap')).toBeVisible();

  const nav = await page.locator('.navbar').boundingBox();
  const wrap = await page.locator('.ph-img-wrap').boundingBox();
  expect(nav.y, 'the title row is not at the top').toBeLessThan(2);
  expect(wrap.y - (nav.y + nav.height),
         'something is still between the title and the photograph')
    .toBeLessThan(4);
  expect(wrap.height, 'the photograph did not gain the row')
    .toBeGreaterThan(before);

  // Almost the whole window is photograph: one line of title above it and one
  // line of caption below, and nothing else.
  const vh = await page.evaluate(() => window.innerHeight);
  expect(vh - wrap.height, 'presentation is spending too much on chrome')
    .toBeLessThan(80);

  await page.keyboard.press('Escape');
});

test('the tree comes up closed', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  // Nothing open: the sidebar's first job is an overview of the collection.
  expect(await page.locator('.ph-tree details[open]').count()).toBe(0);

  // A photograph is on screen all the same -- it just does not open its
  // directory to say so. The row is still marked, so opening it later shows
  // where you were.
  const ids = await H.photoIds(page);
  await H.showing(page, ids[0]);
  await expect(page.locator(`#ph-p-${ids[0]}`)).toHaveClass(/ph-p-on/);
  await expect(page.locator(`#ph-p-${ids[0]}`)).toBeHidden();
});

test('moving to a photograph opens the directories above it', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  await page.click('.ph-img-wrap');

  await page.keyboard.press('ArrowDown');
  await H.showing(page, ids[1]);
  // Reached by keyboard rather than by clicking, so the tree has to open
  // itself or the highlight would be somewhere nobody can see.
  await expect(page.locator(`#ph-p-${ids[1]}`)).toBeVisible();
  await expect(page.locator(`#ph-p-${ids[1]}`)).toHaveClass(/ph-p-on/);
});
