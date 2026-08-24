// Drives phostor's browser code: the microphone, MediaRecorder, the chunk
// upload and the playback clock. The R suite cannot reach any of it, because
// testServer() substitutes for the browser.
//
// Uses the installed Chrome (channel: 'chrome') rather than a bundled
// Chromium, and replaces the microphone with Chrome's synthetic device, so the
// tests do not use a real device, raise a permission prompt, or depend on
// macOS privacy settings.
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: __dirname,
  timeout: 60000,
  expect: { timeout: 15000 },
  // One worker: every spec drives the same phostor instance and work
  // directory and asserts on files, so they must not interleave.
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],
  use: { baseURL: process.env.PHOSTOR_URL || 'http://127.0.0.1:7699' },

  // phostor supports Chrome and Firefox, so both are tested. Safari is not a
  // project here because it is not supported: it records fragmented MP4, whose
  // chunks do not concatenate into a playable file.
  projects: [
    {
      name: 'chrome',
      use: {
        channel: 'chrome',          // the installed Chrome, not a download
        permissions: ['microphone'],
        launchOptions: {
          args: [
            // A synthetic microphone that is always present and emits a
            // tone, so recordings contain audio rather than silence.
            '--use-fake-device-for-media-stream',
            // Auto-grant getUserMedia: no prompt and no OS permission
            // check, which the tests must not depend on.
            '--use-fake-ui-for-media-stream',
            '--autoplay-policy=no-user-gesture-required'
          ]
        }
      }
    },
    {
      name: 'firefox',
      use: {
        browserName: 'firefox',
        launchOptions: {
          firefoxUserPrefs: {
            // Firefox's equivalents of the two Chrome flags above.
            'media.navigator.streams.fake': true,
            'media.navigator.permission.disabled': true,
            'media.autoplay.default': 0,
            'media.autoplay.blocking_policy': 0
          }
        }
      }
    }
  ]
});
