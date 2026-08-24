const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

test('arrow keys step through the photographs', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await H.openPhoto(page, ids[0]);
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(
    (i) => document.getElementById('ph-photo').src.includes(`/display/${i}.jpg`),
    ids[1]);
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(
    (i) => document.getElementById('ph-photo').src.includes(`/display/${i}.jpg`),
    ids[0]);
  // At the ends it must simply stop rather than wrap or error.
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(
    (i) => document.getElementById('ph-photo').src.includes(`/display/${i}.jpg`),
    ids[0]);
});

test('s hides the sidebar for presentation', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');
  await page.keyboard.press('s');
  await expect(page.locator('body')).toHaveClass(/ph-present/);
  await page.keyboard.press('s');
  await expect(page.locator('body')).not.toHaveClass(/ph-present/);
});

test('typing in a field does not steal the arrow keys', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  await H.openPhoto(page, ids[1]);
  await page.click('#place');
  await page.keyboard.type('Elgol');
  await page.keyboard.press('ArrowLeft');   // moves the cursor, not the photo
  await expect(page.locator('#ph-photo'))
    .toHaveAttribute('src', new RegExp(`display/${ids[1]}\\.jpg$`));
  // Ends with what was typed: the field may also have been seeded from an
  // earlier visit to this photograph, which is deliberate and is not what this
  // test is about. Asserting an exact value would be racing the seed.
  await expect(page.locator('#place')).toHaveValue(/Elgol$/);
});

test('Play walks the sitting back in the order it was recorded', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  // Play only appears once there is something to play. 01-sitting.spec.js
  // normally leaves one behind; record one here so this file also stands on
  // its own (tests/browser/run.sh 02-replay).
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  await page.waitForSelector('#play');

  const seen = [];
  // Watch the displayed photograph rather than the audio element: the image is
  // what the room sees, and it is what has to stay in step.
  await page.exposeFunction('phSeen', (src) => { seen.push(src); });
  await page.evaluate(() => {
    const im = document.getElementById('ph-photo');
    new MutationObserver(() => window.phSeen(im.src))
      .observe(im, { attributes: true, attributeFilter: ['src'] });
  });

  await page.click('#play');
  await page.waitForSelector('#play_stop');
  // The recorded sitting held three visits; playback must advance through them.
  await expect.poll(() => seen.length, { timeout: 45000 }).toBeGreaterThanOrEqual(2);
  const strip = await page.$eval('#ph-play-fill',
                                 (e) => parseFloat(e.style.width) || 0);
  expect(strip).toBeGreaterThan(0);
  await page.click('#play_stop');
});
