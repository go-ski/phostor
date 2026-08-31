// Zoom. What is magnified is the display copy, rendered once at display_size,
// so these tests are about the transform and its clamp rather than about
// image quality: past the render's own pixels the picture goes soft, and that
// is a property of display_size, not of this code.
const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

const zoomed = async (page) => (await H.zoomOf(page)).state;

// Puts the pointer over the middle of the photograph and leaves it there, so
// a wheel event lands on the frame.
async function overPhoto(page) {
  // The frame gives up height when the visits panel lands, so a pointer placed
  // before that is no longer over the middle of anything.
  await page.waitForSelector('.ph-hist', { state: 'attached' });
  const b = await page.locator('.ph-img-wrap').boundingBox();
  await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
  return b;
}

// One drag across the frame, corner to corner in the direction given.
// Confined to the frame rather than a fixed number of pixels from its middle:
// a pointer moved outside the window is not reliably delivered, and by the
// time the whole suite reaches here the visits panel has squeezed the frame
// down to a couple of hundred pixels, where a fixed step leaves the window.
async function dragAcross(page, sx, sy) {
  await page.waitForSelector('.ph-hist', { state: 'attached' });
  const b = await page.locator('.ph-img-wrap').boundingBox();
  const m = 8;
  const near = { x: b.x + m, y: b.y + m };
  const far = { x: b.x + b.width - m, y: b.y + b.height - m };
  await page.mouse.move(sx > 0 ? near.x : far.x, sy > 0 ? near.y : far.y);
  await page.mouse.down();
  await page.mouse.move(sx > 0 ? far.x : near.x, sy > 0 ? far.y : near.y,
                        { steps: 6 });
  await page.mouse.up();
}

// Drag one way until the clamp stops it. Stopping when the photograph stops
// moving rather than after a computed number of drags: how far there is to go
// depends on the frame, and the frame depends on what is folded out below the
// photograph at the time.
async function toCorner(page, sx, sy) {
  let prev = null;
  for (let i = 0; i < 40; i++) {
    await dragAcross(page, sx, sy);
    const b = await H.photoBox(page);
    if (prev && Math.abs(b.x - prev.x) < 0.5 && Math.abs(b.y - prev.y) < 0.5) {
      return;
    }
    prev = b;
  }
}

// How much background is showing beside the photograph, if any. A string, so
// a failure names the edge and the size of the gap rather than saying false.
async function coverage(page) {
  const b = await H.photoBox(page);
  const gaps = [-b.x, -b.y, b.x + b.w - b.W, b.y + b.h - b.H];
  return gaps.every((g) => g >= -0.5) ? 'covered'
    : 'left/top/right/bottom gaps ' + gaps.map((g) => g.toFixed(1)).join(', ');
}
async function expectCovered(page, why) {
  await expect.poll(() => coverage(page), { message: why }).toBe('covered');
}

test('the wheel zooms the photograph, and says by how much', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await overPhoto(page);

  expect(await zoomed(page)).toBe(1);
  await page.mouse.wheel(0, -400);

  const z = await H.zoomOf(page);
  expect(z.state, 'the wheel did not zoom').toBeGreaterThan(1);
  // What the app believes and what the element carries must be the same
  // number: a magnification that never reached the DOM is not a zoom.
  expect(z.css).toBeCloseTo(z.state, 3);

  // The badge says the magnification, then gets out of the way.
  await expect(page.locator('#ph-zoom')).toHaveClass(/\bon\b/);
  await expect(page.locator('#ph-zoom')).toHaveText(/^\d+%$/);
  await expect(page.locator('#ph-zoom'))
    .not.toHaveClass(/\bon\b/, { timeout: 6000 });
});

test('the keys step in and out, and 0 goes back to fitted', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  await page.keyboard.press('+');
  const inOnce = await zoomed(page);
  expect(inOnce).toBeGreaterThan(1);

  await page.keyboard.press('+');
  expect(await zoomed(page)).toBeGreaterThan(inOnce);

  await page.keyboard.press('-');
  expect(await zoomed(page)).toBeCloseTo(inOnce, 3);

  await page.keyboard.press('0');
  const z = await H.zoomOf(page);
  expect(z.state).toBe(1);
  // Cleared rather than written as an identity: fitted is the element's own
  // layout, and getComputedStyle reads a cleared transform as 'none'.
  expect(z.css).toBe(1);
});

test('zoom stops at fitted and at the ceiling', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  // Out from fitted goes nowhere: fitted is the floor, not a starting point.
  for (let i = 0; i < 5; i++) await page.keyboard.press('-');
  expect(await zoomed(page)).toBe(1);

  for (let i = 0; i < 20; i++) await page.keyboard.press('+');
  const z = await H.zoomOf(page);
  expect(z.state, 'the ceiling is not 8x').toBe(8);
  expect(z.css).toBeCloseTo(8, 3);
});

test('dragging pans, and the photograph cannot leave the frame', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  // All the way in, rather than a few steps: how tall the frame is depends on
  // what is folded out below the photograph, and by the time the whole suite
  // reaches here that is a panel of recorded visits. A few steps can leave the
  // photograph letterboxed, and a letterboxed axis is centred by the clamp --
  // correctly -- so there would be nothing to pan.
  for (let i = 0; i < 20; i++) await page.keyboard.press('+');
  expect(await zoomed(page)).toBe(8);

  const before = await H.photoBox(page);
  expect(before.w, 'the photograph does not cover the frame')
    .toBeGreaterThan(before.W);
  expect(before.h).toBeGreaterThan(before.H);

  await dragAcross(page, 1, 1);
  const after = await H.photoBox(page);
  expect(after.x, 'the drag did not pan').toBeGreaterThan(before.x);
  expect(after.y).toBeGreaterThan(before.y);

  // Into each corner in turn. The clamp must hold at both: the frame stays
  // covered rather than showing background beside the photograph. Read after
  // the coverage poll, so the frame has settled -- it can still be changing
  // size while the visits panel below fills itself in.
  await toCorner(page, 1, 1);
  await expectCovered(page, 'the photograph was dragged clear of the frame');
  const near = await H.photoBox(page);
  expect(near.x, 'the near corner was not reached').toBeCloseTo(0, 1);
  expect(near.y).toBeCloseTo(0, 1);

  await toCorner(page, -1, -1);
  await expectCovered(page, 'the photograph was dragged clear of the frame');
  const far = await H.photoBox(page);
  expect(far.x + far.w, 'the far corner was not reached').toBeCloseTo(far.W, 1);
  expect(far.y + far.h).toBeCloseTo(far.H, 1);
});

test('a change in the frame re-clamps the photograph', async ({ page }) => {
  // The frame grows and shrinks for reasons that are not window resizes: the
  // b key, presentation, and the visits panel filling itself in a few seconds
  // after a photograph is left. A pan clamped to the frame it was made in has
  // to be re-clamped to the new one, or the photograph is left with
  // background showing beside it and no way to know why.
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  for (let i = 0; i < 20; i++) await page.keyboard.press('+');
  await toCorner(page, 1, 1);
  await expectCovered(page, 'the corner was not covered to begin with');

  await page.keyboard.press('b');                       // the frame grows
  await expect(page.locator('.ph-tags')).toBeHidden();
  await expectCovered(page, 'growing the frame left it uncovered');

  await page.keyboard.press('b');                       // and back again
  await expect(page.locator('.ph-tags')).toBeVisible();
  await expectCovered(page, 'shrinking the frame left it uncovered');
});

test('a single click on the photograph is still just a click', async ({ page }) => {
  // Clicking the frame is how focus is taken off the tag fields, here and in
  // the app, so it must not start a pan or a zoom.
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  await page.click('.ph-img-wrap');
  expect(await zoomed(page)).toBe(1);

  // Zoomed in, a click must not pan either -- a pan begins only once the
  // pointer has actually moved.
  await page.keyboard.press('+');
  await page.keyboard.press('+');
  const z = await zoomed(page);
  const before = await H.photoBox(page);
  await page.click('.ph-img-wrap');
  expect(await zoomed(page)).toBeCloseTo(z, 3);
  const after = await H.photoBox(page);
  expect(after.x).toBeCloseTo(before.x, 1);
  expect(after.y).toBeCloseTo(before.y, 1);
});

test('a new photograph arrives fitted', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);
  await page.click('.ph-img-wrap');

  for (let i = 0; i < 4; i++) await page.keyboard.press('+');
  expect(await zoomed(page)).toBeGreaterThan(1);

  await page.keyboard.press('ArrowDown');
  await H.showing(page, ids[1]);
  const z = await H.zoomOf(page);
  expect(z.state, 'the zoom carried over to the next photograph').toBe(1);
  expect(z.css).toBe(1);
});

test('zoom works inside presentation', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  await page.click('.ph-img-wrap');

  await page.keyboard.press('s');
  await expect(page.locator('body')).toHaveClass(/ph-present/);

  await overPhoto(page);
  await page.mouse.wheel(0, -400);
  expect(await zoomed(page)).toBeGreaterThan(1);

  await page.keyboard.press('Escape');
  await expect(page.locator('body')).not.toHaveClass(/ph-present/);
  // Leaving presentation resizes the frame; the magnification survives it.
  expect(await zoomed(page)).toBeGreaterThan(1);
});
