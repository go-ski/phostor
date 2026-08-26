const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

const body = (page) => page.locator('body');
const inPresent = (page) => page.evaluate(() =>
  document.body.classList.contains('ph-present'));
// Clicking the button is a server round trip, unlike the keys, so its effect
// is waited for rather than read straight back.

test('the Presentation button enters, and says how to leave', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  await page.click('#present');
  await expect(body(page)).toHaveClass(/ph-present/);
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
  expect(await inPresent(page)).toBe(false);
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
  expect(await inPresent(page)).toBe(false);
  await expect(body(page)).not.toHaveClass(/ph-nobottom/);
  await expect(page.locator('#place')).toHaveValue('Bridge by the sea');
});
