const { test, expect } = require('@playwright/test');
const H = require('./helpers');

// Runs last on purpose: it stops the phostor instance the other specs share.
// run.sh kills the server with `|| true`, so a process that has already gone
// is not an error, and each browser gets its own instance.
//
// Playwright runs spec files in name order, so this one must keep the highest
// number. A new spec numbered above it cannot reach the server at all: every
// one of its tests fails on ERR_CONNECTION_REFUSED, saying nothing about
// itself.
test('Quit asks first, and can be cancelled', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  await page.click('#quit');
  await expect(page.locator('.modal-content')).toContainText('Quit phostor?');
  await page.click('.modal-footer button:has-text("Cancel")');
  await expect(page.locator('.modal-content')).toHaveCount(0);

  // Still running: the tree is there and the server answers.
  await expect(page.locator('.ph-tree')).toBeVisible();
});

test('Quit stops phostor and says so', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');

  await page.click('#quit');
  await page.waitForSelector('.modal-content');
  await page.click('.modal-footer button:has-text("Quit")');

  // The page says what happened rather than leaving Shiny's disconnect grey.
  await page.waitForSelector('body[data-ph-quit]', { timeout: 20000 });
  await expect(page.locator('.ph-stopped')).toContainText('phostor has stopped');

  // And the server really is gone.
  await expect.poll(async () => {
    try {
      await page.request.get(process.env.PHOSTOR_URL || 'http://127.0.0.1:7699',
                             { timeout: 2000 });
      return 'answered';
    } catch (e) {
      return 'gone';
    }
  }, { timeout: 20000 }).toBe('gone');
});
