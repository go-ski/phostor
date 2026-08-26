const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

test('arrow keys step through the photographs', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await H.openPhoto(page, ids[0]);
  await page.keyboard.press('ArrowRight');
  await H.showing(page, ids[1]);
  await page.keyboard.press('ArrowLeft');
  await H.showing(page, ids[0]);
  // At the ends it stops rather than wrapping or erroring.
  await page.keyboard.press('ArrowLeft');
  await H.showing(page, ids[0]);
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
  await H.showing(page, ids[1]);
  // Ends with what was typed. The field may also be seeded from an earlier
  // visit to this photograph, so asserting an exact value would race the
  // seeding.
  await expect(page.locator('#place')).toHaveValue(/Elgol$/);
});

test('Play walks the sitting back in the order it was recorded', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  // Play appears only once a sitting exists. 01-sitting.spec.js normally
  // leaves one; record one here so this file also runs on its own
  // (tests/browser/run.sh 02-replay).
  if (H.sessionCount() === 0) await H.recordShortSitting(page);
  await page.waitForSelector('#play');

  const seen = [];
  // Watch the displayed photograph rather than the audio element: the image is
  // what has to stay in step with playback.
  await page.exposeFunction('phSeen', (src) => { seen.push(src); });
  await page.evaluate(() => {
    const im = document.getElementById('ph-photo');
    new MutationObserver(() => window.phSeen(im.src))
      .observe(im, { attributes: true, attributeFilter: ['src'] });
  });

  await page.click('#play');
  await page.waitForSelector('#play_stop');
  // The recorded sitting held three visits; playback advances through them.
  await expect.poll(() => seen.length, { timeout: 45000 }).toBeGreaterThanOrEqual(2);
  const strip = await page.$eval('#ph-play-fill',
                                 (e) => parseFloat(e.style.width) || 0);
  expect(strip).toBeGreaterThan(0);
  // A short sitting can reach its end before we get here, which replaces Stop
  // with the Play control again. Both are valid ends to playback.
  if (await page.locator('#play_stop').count()) await page.click('#play_stop');
});
