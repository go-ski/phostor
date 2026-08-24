# phostor

**An app that adds stories to photos.**

Family, friends, and relatives look at photographs on a screen and talk about
them: who is in them, where they were taken, what was happening, how everyone
is related. That conversation is the valuable thing in the room, and it may be
lost over time. The photographs will outlive everyone present but the memories 
may not.

phostor shows the photographs, records the talk, and writes each visit down.

- The folder tree of a read-only photo directory is the sidebar. Click any
  photograph to show it.
- Start a sitting and the microphone stays live. Segments start and stop by
  themselves as photographs change, so nobody has to remember to press anything.
- Every visit to a photograph writes its own sidecar beside that photograph's
  record — the audio, the names the room supplied, and the place, event and
  date they settled on.
- Coming back to a photograph later adds a second visit. Nothing is overwritten:
  the room hears what was said last time and corrects it.
- The route through the evening is logged as it happens.
- **Play** replays the whole sitting — the same photographs, in the same order,
  with the same voices.

**The photo directory is never written to.** phostor refuses to start if its
work directory is the same as, inside, or contains the photographs.

## Requirements

```sh
brew install vips exiftool
```

`vipsthumbnail` (part of libvips) is the one hard requirement: it renders the
display copies, and without it there is nothing to show. `exiftool` is optional
— without it, capture dates and dimensions are blank and everything else works.

R packages: `yaml`, `base64enc`; plus `shiny`, `bslib` and `htmltools` for the
app, and `pkgload` to run `exec/phostor` against an uninstalled source tree.

**Use Chrome or Firefox.** Recording needs `MediaRecorder` with Opus in WebM.
Both have it, and both are tested end to end. **Safari does not** — it records
fragmented MP4, whose chunks do not concatenate into a playable file. `ph_app()` 
opens a browser that can record in preference to your system default, and tells 
you which one it opened.

### If recording fails, it is almost certainly the operating system

macOS grants microphone access **per application**, underneath the permission
the web page asks for. A browser can be allowed by the page and refused by the
system, and what reaches the page is an unhelpful `NotFoundError`.

Press **Check microphone** in the app — before the evening, not during it. It
names your browser, lists the input devices it can see, shows a live level meter
that moves when you speak, and records three seconds to play straight back. If
something is wrong, it says what to do about it.

The usual fix:

> **System Settings → Privacy & Security → Microphone** → switch your browser
> on → **quit the browser completely and open it again.** macOS applies the
> change only on relaunch, which is the step almost everyone misses.

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

0. **Check microphone** first, while nobody is waiting. The level meter should
   move when you speak. If there is more than one input, pick the right one —
   a virtual device (Teams, Zoom) or a disconnected phone will record silence.
1. **Start sitting.** The browser asks for the microphone; a banner says plainly
   that the room is being recorded. A red **REC** badge stays on screen the
   whole time, legible from across the room. If the microphone does not open,
   the app says why and offers **Try the microphone again** — fix the
   permission, press it, carry on.
2. **Show photographs.** Click the tree, or use `←` and `→`. `s` hides the
   sidebar, `f` goes full screen — presentation mode leaves nothing but the
   photograph and the recording indicator.
3. **Talk.** Recording follows the photographs on its own.
4. **Add what the room concludes.** Names go in as chips, with autocomplete from
   every name used earlier in the project. Place, event and a date guess are
   three short fields. On a second visit they start filled in from last time.
5. **Pause** for a tea break, then **Resume**. **Discard this take** throws away
   the recording for the photograph on screen and starts it again — for when
   the dog barked.
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
      path.tsv          the route through the evening, appended as it happens
  sidecars/
    Trips/Skye/img_0421.jpg/    mirrors the photo directory, a folder per photo
      visit-0001.yml
      visit-0001.webm
      visit-0002.yml
      visit-0002.webm
```

The sidecar tree mirrors the photo directory path for path, and each photograph
gets a **directory named exactly like its file**. Two reasons. A photograph's
record must be findable from its path alone, years from now and without
phostor; and every visit to one photograph — across every sitting it ever
appeared in — then sits together in one place.

Visit numbers are per photograph and never reused. Deleting visit 2 of 3 leaves
the next visit as number 4, so no sidecar ever silently replaces another.

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

`people`, `place`, `event` and `when` are **what the room concluded**, kept
deliberately apart from EXIF. On a scanned print the EXIF date is the date of
the scan, and the room is the better authority. `transcript` is reserved: an
offline pass can fill it in later without a format change, so the key is
written now and readers can rely on it existing.

These are plain YAML files with a comment at the top. Hand-edit them freely.
phostor only ever adds files.

### The path taken

```
iso_time              elapsed  event  rel_path             visit  duration
2026-08-23T19:31:02Z  0.0      start  -                    -      -
2026-08-23T20:14:07Z  2585.1   show   Trips/Skye/img_0421.jpg  3  -
2026-08-23T20:15:41Z  2679.3   leave  Trips/Skye/img_0421.jpg  3  94.2
```

Tab-separated, appended line by line as the evening happens, so a crash or a
shut laptop loses nothing but the visit in progress. There is no `audio` column
on purpose: a visit's audio filename lives in its sidecar and nowhere else, so
the two can never disagree.

## Configuration

The **only path you must set** is `photo_root`. A phostor project is a
*directory*, and `config.yml` lives inside it — the work directory *is* the
directory the config is in, so there is no `work_dir:` key to keep in step.

- `title` — shown in the browser title bar and each sitting's `session.yml`.
- `display_size` / `thumb_size` — longest edge of the pre-rendered copies.
  Raise `display_size` for a 4K television.
- `min_visit_seconds` — a visit shorter than this logs a row in `path.tsv` but
  writes no sidecar, so paging past forty photographs looking for one does not
  leave forty empty records. Set it to `0` to keep every visit.
- `chunk_seconds` — seconds of audio per upload. Each chunk is written to disk
  as it arrives, so this is also how much a crash can cost you.
- `extensions` / `cruft` — what counts as a photograph, and what to skip.

## How the recording actually works

The browser records with `MediaRecorder` and ships the stream up in chunks.
Each chunk is appended to a `visit-NNNN.webm.part` file the moment it arrives,
and renamed to its final name only when the visit closes cleanly. So a crash
costs one chunk rather than the evening, and a `.part` file left behind is
unambiguously an interrupted visit — playable, and never deleted by phostor.
`ph_status()` reports them.

Chunks from a single recorder concatenate into a valid WebM, which is why this
needs no `ffmpeg` and no muxing step, and why phostor pins the format rather
than stitching together whatever a browser happens to offer.

Chunks are acknowledged one at a time. Shiny coalesces repeated writes to one
input within a flush, so a fire-and-forget upload would silently lose whichever
chunk arrived second. And the server ignores any chunk whose visit it does not
recognise — that single rule is what makes every start, stop and discard race
safe: audio from a superseded recorder lands nowhere.

## Is it safe for my photographs?

That is the whole design.

- `ph_config()` refuses to run when the work directory is the same as, inside,
  or contains `photo_root` — case-insensitively where the filesystem is, since
  `/Volumes/Photo` and `/Volumes/photo` are one directory on APFS.
- Everything phostor writes is built from a path under the work directory.
- The test suite drives a complete scripted sitting through the real app server
  and asserts that every file under the photo directory is byte-for-byte
  unchanged afterwards.

If you want, mount the photo collection read-only, phostor will not
notice the difference.

## Development

```r
devtools::test()      # the R suite
devtools::check()     # clean before anything ships
```

```sh
tests/browser/run.sh  # the browser half, against real Chrome and Firefox
```

The R suite cannot reach the microphone, `MediaRecorder`, the chunk upload or
the playback clock: `shiny::testServer()` fakes the browser entirely. So those
live in `tests/browser/`, driven by Playwright against a **real** browser with a
**synthetic microphone** — Chrome's `--use-fake-device-for-media-stream` and
Firefox's `media.navigator.streams.fake` — so the tests never touch a real
device, never raise a prompt, and never depend on system privacy settings.

Each browser gets its own photo collection, work directory and phostor
instance. The specs drive the real UI and then assert on **disk**: the sidecars
written, the `.webm` files carrying a valid EBML header and an `OpusHead`
stream, `path.tsv` strictly alternating `show`/`leave`, and the photo directory
byte-for-byte unchanged afterwards.

Chrome is used as installed. Firefox needs Playwright's own build, once:

```sh
cd tests/browser && npm install
npx --prefix tests/browser playwright install firefox   # optional
```

`.Rbuildignore` keeps all of it out of the package, so `R CMD check` never sees
Node. Waits are on the app's own DOM state — `data-ph-mic`, `data-ph-visit`,
`data-ph-visit-chunks` — never on a sleep.

Test fixtures are **generated**, not committed: `vips gaussnoise` builds a small
nested photo directory at test time, so the repository carries no photographs
and the fixtures cannot drift away from the tools that read them.
`tests/fixtures/make-fixtures.sh` builds the same tree by hand if you want one
to look at.

`inst/shiny/app.R` is the one file `R CMD check` never sources, and `runApp()`
sources it with only `library(phostor)` attached — exports and nothing else. So
an app calling an unexported function passes every check and fails the moment a
photograph is shown. `tests/testthat/test-app.R` closes that gap from both
sides: it walks the app's parse tree asserting every `ph_*` it calls is
exported, and it drives the real server end to end.

## License

MIT.
