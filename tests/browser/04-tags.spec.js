const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const H = require('./helpers');

test.describe.configure({ mode: 'serial' });

const tagsFile = (rel) => path.join(H.sidecars(), rel, 'tags.yml');

// rel_path of a photograph, by its tree id.
function relOf(id) {
  const ids = H.indexIds();
  return Object.keys(ids).find((k) => ids[k] === id);
}

// Open a photograph and wait until its fields really hold its tags. The app
// fills them from the server, so for a few milliseconds after the image
// appears they still show the previous photograph's text -- type into that
// window and the seeding overwrites what you typed. A person cannot type that
// fast; Playwright can, so it waits for the same stamp the app uses.
async function openTagged(page, id) {
  await H.openPhoto(page, id);
  const rel = relOf(id);
  await page.waitForFunction((r) => window.PH && window.PH.tagsFor === r, rel);
}

async function setTags(page, { place, event, when }) {
  if (place !== undefined) await page.fill('#place', place);
  if (event !== undefined) await page.fill('#event', event);
  if (when !== undefined) await page.fill('#when', when);
}

test('tags are kept with no session running', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  // The specs share one work directory, so earlier ones have already recorded
  // visits here. What matters is that tagging adds none.
  const visitsBefore = H.visitFiles('.yml').length;
  const badgeBefore = await page.locator(`#ph-p-${ids[0]} .ph-b`).count();

  // No Start session anywhere in this spec: the fields must work on their own.
  await openTagged(page, ids[0]);
  await setTags(page, { place: 'Elgol, Isle of Skye',
                        event: 'the 1974 camping trip', when: 'summer 1974' });

  await openTagged(page, ids[1]);            // leaving is what writes
  await expect.poll(() => fs.existsSync(tagsFile(relOf(ids[0]))))
    .toBe(true);

  const yml = fs.readFileSync(tagsFile(relOf(ids[0])), 'utf8');
  expect(yml).toContain('Elgol, Isle of Skye');
  expect(yml).toContain('summer 1974');
  // It says it is rewritten, unlike every other file in that directory.
  expect(yml).toContain('phostor rewrites this file');

  // Nothing was recorded, so nothing new claims to be a visit.
  expect(H.visitFiles('.yml').length).toBe(visitsBefore);
  expect(await page.locator(`#ph-p-${ids[0]} .ph-b`).count()).toBe(badgeBefore);
});

test('coming back to a photograph shows what was typed', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await openTagged(page, ids[0]);
  await expect(page.locator('#place')).toHaveValue('Elgol, Isle of Skye');
  await expect(page.locator('#when')).toHaveValue('summer 1974');

  // A different photograph does not inherit them.
  await openTagged(page, ids[2]);
  await expect(page.locator('#place')).toHaveValue('');
});

test('an edit on a revisit replaces what was there', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await openTagged(page, ids[0]);
  await setTags(page, { place: 'Camasunary' });
  await openTagged(page, ids[1]);

  await expect.poll(() => fs.readFileSync(tagsFile(relOf(ids[0])), 'utf8'))
    .toContain('Camasunary');
  // The other fields survived an edit that touched only one of them.
  const yml = fs.readFileSync(tagsFile(relOf(ids[0])), 'utf8');
  expect(yml).toContain('summer 1974');
});

test('clearing a field sticks rather than coming back', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await openTagged(page, ids[0]);
  await page.fill('#when', '');
  await openTagged(page, ids[1]);
  await openTagged(page, ids[0]);
  await expect(page.locator('#when')).toHaveValue('');
});

test('a name typed outside a session reaches the autocomplete', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  await openTagged(page, ids[3]);
  // selectize: type the name and press enter to create the chip.
  await page.click('#people + .selectize-control .selectize-input');
  await page.keyboard.type('Nana Vera');
  await page.keyboard.press('Enter');
  await openTagged(page, ids[0]);

  await expect.poll(() => fs.existsSync(tagsFile(relOf(ids[3])))).toBe(true);
  expect(fs.readFileSync(tagsFile(relOf(ids[3])), 'utf8')).toContain('Nana Vera');

  // The name is now offered on a photograph that has never seen it.
  // selectize replaces the <select>, so its options come from the instance
  // rather than from the DOM.
  await openTagged(page, ids[2]);
  await expect.poll(() => page.evaluate(() => {
    const el = document.getElementById('people');
    const sel = el && el.selectize;
    return sel ? Object.keys(sel.options) : [];
  })).toContain('Nana Vera');
});

test('paging fast off a tagged photograph does not smear its tags', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.ph-tree');
  const ids = await H.photoIds(page);

  // ids[0] carries tags from the specs above. Land on it, then leave
  // immediately with the keyboard -- no waiting for the fields to be seeded,
  // which is the window in which the previous photograph's text could be
  // written onto the next one.
  await openTagged(page, ids[0]);
  await page.click('.ph-img-wrap');            // focus off the fields
  for (let i = 0; i < 4; i++) await page.keyboard.press('ArrowRight');
  await page.waitForTimeout(1500);

  // None of the photographs paged through may have picked up ids[0]'s tags.
  for (let i = 1; i < Math.min(5, ids.length); i++) {
    const f = tagsFile(relOf(ids[i]));
    if (!fs.existsSync(f)) continue;
    expect(fs.readFileSync(f, 'utf8'),
           `${relOf(ids[i])} picked up another photograph's tags`)
      .not.toContain('Camasunary');
  }
});
