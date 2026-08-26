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
