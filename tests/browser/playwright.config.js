// Drives phostor's browser half: the microphone, MediaRecorder, the chunk
// upload and the playback clock -- none of which the R suite can reach, because
// testServer() fakes the browser entirely.
//
// Uses the Chrome already installed on the machine (channel: 'chrome') rather
// than downloading a bundled Chromium, and replaces the microphone with
// Chrome's synthetic device so the tests never touch a real one, never raise a
// permission prompt, and never depend on macOS privacy settings -- which is
// exactly what broke the first real sitting.
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: __dirname,
  timeout: 60000,
  expect: { timeout: 15000 },
  // One worker: every spec drives the same phostor instance and the same work
  // directory, and asserts on files. They must not interleave.
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
            // A synthetic microphone that is always present and emits a tone,
            // so recordings carry real bytes rather than silence.
            '--use-fake-device-for-media-stream',
            // Auto-grant getUserMedia: no prompt, no OS involvement -- which
            // is the whole point, since an OS-level denial is what broke the
            // first real sitting.
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
