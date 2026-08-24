# phostor

**An app that adds stories to photos.**

People look at photographs on a screen and talk about them: who is in them,
where they were taken, what was happening, how everyone is related. phostor
displays the photographs, records that conversation, and writes each visit to
disk.

- The folder tree of a read-only photo directory is the sidebar. Click any
  photograph to show it.
- Start a sitting and the microphone stays live. Segments start and stop by
  themselves as photographs change, so nobody has to remember to press anything.
- Every visit to a photograph writes its own sidecar file holding the audio,
  the names given, and a place, event and date.
- Returning to a photograph later adds a second visit. Nothing is overwritten,
  and the earlier audio can be played back and corrected.
- The order photographs were viewed in is logged as it happens.
- **Play** replays a sitting: the same photographs, in the same order, with the
  same audio.

**The photo directory is never written to.** phostor refuses to start if its
work directory is the same as, inside, or contains the photographs.

## Requirements

```sh
brew install vips exiftool
```

`vipsthumbnail` (part of libvips) is the only hard requirement: it renders the
display copies. `exiftool` is optional; without it, capture dates and
dimensions are blank.

R packages: `yaml`, `base64enc`; plus `shiny`, `bslib` and `htmltools` for the
app, and `pkgload` to run `exec/phostor` against an uninstalled source tree.

**Use Chrome or Firefox.** Recording needs `MediaRecorder` with Opus in WebM.
Both support it, and both are tested end to end. Safari does not: it records
fragmented MP4, whose chunks do not concatenate into a playable file.
`ph_app()` opens a browser that can record in preference to the system default,
and reports which one it opened.

### If recording fails, check the operating system first

macOS grants microphone access per application, underneath the permission the
web page asks for. A browser can be allowed by the page and refused by the
system, and what reaches the page is `NotFoundError`, which does not indicate
the cause.

Press **Check microphone** in the app before starting. It names the browser,
lists the input devices it can see, shows a level meter that moves when you
speak, and records three seconds to play back. If something is wrong, it
reports what to change.

The usual fix:

> **System Settings → Privacy & Security → Microphone** → switch your browser
> on → **quit the browser completely and open it again.** macOS applies the
> change only on relaunch.

`ph_preflight()` reports which browsers are installed, which one your system
would open, and whether it can record.

## Quick start

```r
install.packages("devtools")
devtools::install_github("go-ski/phostor")
```

```r
library(phostor)

ph_init("~/phostor/family", photo_root = "~/family-photos")
ph_preflight()          # are the tools here?
ph_go("~/phostor/family")   # index, render, and open the app
```

`ph_go()` is index + render + launch. The three are also separate, because only
the first two need repeating when photographs are added:

```r
ph_index()        # scan the directory, read capture dates, write index.tsv
ph_render_all()   # pre-render a display copy and a thumbnail for each
ph_app()          # open the app
ph_status()       # what this project holds
```

From the terminal, once the launcher is on your PATH:

```sh
ln -s "$(Rscript -e 'cat(system.file("exec", "phostor", package = "phostor"))')" ~/bin/phostor

phostor init --work ~/phostor/family --photos ~/family-photos
phostor go   --work ~/phostor/family
```

## Running a sitting

0. **Check microphone** first. The level meter should move when you speak. If
   there is more than one input, select the right one: a virtual device (Teams,
   Zoom) or a disconnected phone will record silence.
1. **Start sitting.** The browser asks for the microphone, and a dialog states
   that recording has started. A red **REC** badge stays on screen while the
   microphone is live. If the microphone does not open, the app reports why and
   offers **Try the microphone again**.
2. **Show photographs.** Click the tree, or use `←` and `→`. `s` hides the
   sidebar, `f` goes full screen — presentation mode leaves nothing but the
   photograph and the recording indicator.
3. **Talk.** Recording follows the photographs on its own.
4. **Add what was established.** Names go in as chips, with autocomplete from
   every name used earlier in the project. Place, event and a date guess are
   three short fields. On a second visit they start filled in from last time.
5. **Pause** to stop recording, then **Resume**. **Discard this take** throws
   away the recording for the photograph on screen and starts it again.
6. **End sitting.**

Later, pick the sitting from the dropdown and press **Play**.

## What lives where

```
<work_dir>/
  config.yml            the only file you edit
  config.resolved.yml   snapshot written by every command (provenance)
  config.history/       prior config.yml, saved by ph_init(overwrite = TRUE)
  index.tsv             the catalogue: id, rel_path, capture date, dimensions
  display/<id>.jpg      pre-rendered display copies
  thumbs/<id>.jpg       pre-rendered tree thumbnails
  sessions/
    2026-08-23-1930/
      session.yml       title, when it started, which photographs
      path.tsv          the order photos were viewed, appended as it happens
  sidecars/
    Trips/Skye/img_0421.jpg/    mirrors the photo directory, a folder per photo
      visit-0001.yml
      visit-0001.webm
      visit-0002.yml
      visit-0002.webm
```

The sidecar tree mirrors the photo directory path for path, and each
photograph gets a directory named after its file. This keeps a photograph's
record findable from its path without phostor, and keeps all visits to one
photograph in one place.

Visit numbers are per photograph and are not reused. Deleting visit 2 of 3
leaves the next visit as number 4, so no sidecar overwrites another.

### A visit

```yaml
photo: Trips/Skye/img_0421.jpg
visit: 3
session: 2026-08-23-1930
started: '2026-08-23T20:14:07Z'
ended: '2026-08-23T20:15:41Z'
duration: 94.2
audio: visit-0003.webm
people:
- Nana Vera
- Uncle Stefan
- '? child in blue'
place: Elgol, Isle of Skye
event: the 1974 camping trip
when: summer 1974
transcript: ~
```

`people`, `place`, `event` and `when` hold what was said, kept separate from
EXIF: on a scanned print the EXIF date is the date of the scan. `transcript` is
reserved so a later offline pass can fill it in without a format change; the
key is written now and readers can rely on it existing.

These are plain YAML files with a comment at the top, and can be hand-edited.
phostor only adds files.

### The path taken

```
iso_time              elapsed  event  rel_path             visit  duration
2026-08-23T19:31:02Z  0.0      start  -                    -      -
2026-08-23T20:14:07Z  2585.1   show   Trips/Skye/img_0421.jpg  3  -
2026-08-23T20:15:41Z  2679.3   leave  Trips/Skye/img_0421.jpg  3  94.2
```

Tab-separated, appended a line at a time, so a crash loses only the visit in
progress. There is no `audio` column: a visit's audio filename lives in its
sidecar, so the two cannot disagree.

## Configuration

The **only path you must set** is `photo_root`. A phostor project is a
*directory*, and `config.yml` lives inside it — the work directory *is* the
directory the config is in, so there is no `work_dir:` key to keep in step.

- `title` — shown in the browser title bar and each sitting's `session.yml`.
- `display_size` / `thumb_size` — longest edge of the pre-rendered copies.
  `display_size` defaults to 4096, for a 4K display; lower it to 2048 for a
  smaller screen, or if rendering takes too long.
- `min_visit_seconds` — a visit shorter than this logs a row in `path.tsv` but
  writes no sidecar, so paging through photographs does not leave a record for
  each one. Set it to `0` to keep every visit.
- `chunk_seconds` — seconds of audio per upload. Each chunk is written to disk
  as it arrives, so this is also how much a crash can lose.
- `extensions` / `cruft` — what counts as a photograph, and what to skip.

## How recording works

The browser records with `MediaRecorder` and sends the stream in chunks. Each
chunk is appended to a `visit-NNNN.webm.part` file as it arrives, and renamed
to its final name when the visit closes. A crash therefore loses one chunk, and
a `.part` file left behind marks an interrupted visit; it is playable, and
phostor does not delete it. `ph_status()` reports them.

Chunks from a single recorder concatenate into a valid WebM, so no `ffmpeg` or
muxing step is needed. phostor pins the recording format for the same reason.

Chunks are acknowledged one at a time. Shiny coalesces repeated writes to one
input within a flush, so sending without waiting for an acknowledgement would
lose whichever chunk arrived second. The server also ignores any chunk whose
visit it does not recognise, which is what makes the start, stop and discard
races safe: audio from a superseded recorder is dropped.

## Read-only guarantee

- `ph_config()` refuses to run when the work directory is the same as, inside,
  or contains `photo_root` — case-insensitively where the filesystem is, since
  `/Volumes/Photo` and `/Volumes/photo` are one directory on APFS.
- Every path phostor writes to is built from the work directory.
- The test suite drives a scripted sitting through the real app server and
  asserts that every file under the photo directory is byte-for-byte unchanged
  afterwards.

The photo collection can also be mounted read-only; phostor behaves the same
either way.

## Development

```r
devtools::test()      # the R suite
devtools::check()     # must be clean before release
```

```sh
tests/browser/run.sh  # the browser half, against real Chrome and Firefox
```

The R suite cannot reach the microphone, `MediaRecorder`, the chunk upload or
the playback clock, because `shiny::testServer()` substitutes for the browser.
Those tests live in `tests/browser/`, driven by Playwright against a real
browser with a synthetic microphone — Chrome's
`--use-fake-device-for-media-stream` and Firefox's
`media.navigator.streams.fake` — so they do not use a real device, raise a
permission prompt, or depend on system privacy settings.

Each browser gets its own photo collection, work directory and phostor
instance. The specs drive the UI and then assert on disk: the sidecars written,
the `.webm` files carrying a valid EBML header and an `OpusHead` stream,
`path.tsv` alternating `show`/`leave`, and the photo directory byte-for-byte
unchanged afterwards.

Chrome is used as installed. Firefox needs Playwright's own build, once:

```sh
cd tests/browser && npm install
npx --prefix tests/browser playwright install firefox   # optional
```

`.Rbuildignore` keeps all of it out of the package, so `R CMD check` never sees
Node. Waits are on the app's own DOM state — `data-ph-mic`, `data-ph-visit`,
`data-ph-visit-chunks` — rather than on a sleep.

Test fixtures are generated, not committed: `vips gaussnoise` builds a small
nested photo directory at test time, so the repository carries no photographs
and the fixtures cannot drift from the tools that read them.
`tests/fixtures/make-fixtures.sh` builds the same tree for inspection.

`inst/shiny/app.R` is the one file `R CMD check` never sources, and `runApp()`
sources it with only `library(phostor)` attached, so only exports are visible.
An app calling an unexported function would pass every check and fail when a
photograph is shown. `tests/testthat/test-app.R` covers this from both sides:
it walks the app's parse tree asserting every `ph_*` it calls is exported, and
it drives the real server end to end.

## License

MIT.
