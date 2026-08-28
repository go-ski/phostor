# phostor

An app that adds **stor**ies to **pho**tos!

People look at photographs on a screen and talk about them: who is in them,
where they were taken, what was happening, how everyone is related. phostor
displays the photographs, records that conversation, and writes each visit to
disk.

- The folder tree of a read-only photo directory is the sidebar. Click any
  photograph to show it.
- Start a session and the microphone stays live. Segments start and stop by
  themselves as photographs change, so nobody has to remember to press anything.
- Every visit to a photograph writes its own sidecar file holding the audio,
  the names given, and a place, event and date.
- Returning to a photograph later adds a second visit. Nothing is overwritten,
  and the earlier audio can be played back and corrected.
- The order photographs were viewed in is logged as it happens.
- **Play** replays a session: the same photographs, in the same order, with the
  same audio.

**The photo directory is never written to.** phostor refuses to start if its
work directory is the same as, inside, or contains the photographs.

## Requirements

```sh
brew install vips exiftool
```

`vipsthumbnail` (part of libvips) is the only hard requirement: it renders the
display copies. `exiftool` is optional; without it, capture dates and
dimensions are blank. [Transcripts](#transcripts) are optional too, and need
macOS 26 or newer with Xcode's command line tools.

R packages: `yaml`, `base64enc`; plus `shiny`, `bslib` and `htmltools` for the
app, and `pkgload` to run `exec/phostor` against an uninstalled source tree.

**Use Chrome or Firefox.** Recording needs `MediaRecorder`, and both are tested
end to end. Chrome records MP4 and Firefox records Ogg; either falls back to
WebM. Safari is not supported: its fragmented MP4 chunks do not concatenate
into a playable file, where Chrome's do. `ph_app()` opens a browser that can
record in preference to the system default, and reports which one it opened.

Which container a browser picks decides whether a recording can be
transcribed -- see [Transcripts](#transcripts).

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

## Running a session

0. **Check microphone** first. The level meter should move when you speak. If
   there is more than one input, select the right one: a virtual device (Teams,
   Zoom) or a disconnected phone will record silence.
1. **Start session.** The browser asks for the microphone, and a dialog states
   that recording has started. A red **REC** badge stays on screen while the
   microphone is live. If the microphone does not open, the app reports why and
   offers **Try the microphone again**.
2. **Show photographs.** The tree starts closed, so what you see first is the
   collection rather than every photograph in it. Click to open a directory
   and click a photograph, or use `←` `→` `↑` `↓` — all four move to the
   previous or next photograph, so it does not matter which your hand reaches
   for, and the tree opens itself to follow. `b` folds away the fields and
   visits under the photograph, so it takes the height. `s` is presentation
   mode: full screen on the display, with the browser's own chrome, the menu
   bar and the Dock gone, and nothing left but one line of title, the
   photograph, and the recording indicator. `s` or **Esc** leaves, and the app
   says so on screen as you go in.
3. **Look closer.** Scroll on the photograph to zoom where the pointer is,
   drag to move around, and double-click to go in and back out. `+` and `-`
   step, `0` returns to fitted. What is magnified is the display copy, so how
   far it stays sharp follows `display_size` in the config (4096 pixels on the
   longest edge by default); raise it and re-render for more.
4. **Talk.** Recording follows the photographs on its own.
5. **Add what was established.** Names go in as chips, with autocomplete from
   every name used earlier in the project. Place, event and a date guess are
   three short fields. They belong to the photograph, not to the session, so
   they can be filled in at any time -- with a session running or without one --
   and are kept when you move on. Coming back to a photograph shows them again.
6. **Pause** to stop recording, then **Resume**. **Discard this take** throws
   away the recording for the photograph on screen and starts it again.
7. **End session.**

Later, pick the session from the dropdown and press **Play**.

**To stop phostor**, press **Quit** in the sidebar. It asks first, ends any
session in progress so the recording on screen is saved, and then stops the
server. Ctrl+C in the terminal it was launched from does the same, and is the
way out if the browser has already gone. Closing the browser tab does not stop
it: the app goes on listening.

## What lives where

```
<work_dir>/
  config.yml            the only file you edit
  config.resolved.yml   snapshot written by every command (provenance)
  config.history/       prior config.yml, saved by ph_init(overwrite = TRUE)
  index.tsv             the catalogue: id, rel_path, capture date, dimensions
  display/4096/         pre-rendered display copies, under the size made at
    Trips/Skye/img_0421.jpg.jpg
  thumbs/256/           pre-rendered tree thumbnails, likewise
    Trips/Skye/img_0421.jpg.jpg
  sessions/
    2026-08-23-1930/
      session.yml       title, when it started, which photographs
      path.tsv          the order photos were viewed, appended as it happens
  sidecars/
    Trips/Skye/img_0421.jpg/    mirrors the photo directory, a folder per photo
      tags.yml                  who, where, what and when: the photograph itself
      visit-0001.yml
      visit-0001.mp4
      visit-0001.txt            the transcript, when there is one
      visit-0001.tsv            the same words, with the seconds each spans
      visit-0002.yml
      visit-0002.mp4
```

The sidecar tree mirrors the photo directory path for path, and each
photograph gets a directory named after its file. This keeps a photograph's
record findable from its path without phostor, and keeps all visits to one
photograph in one place.

`display/` and `thumbs/` mirror it too, under the size they were made at. The
size in the path means changing `display_size` is not something phostor has to
notice: the old copies are simply not where the app looks, and the browser is
asked for a URL it cannot have cached. `.jpg` is appended rather than
substituted -- `IMG_1234.HEIC` becomes `IMG_1234.HEIC.jpg` -- so a folder
holding both `a.jpg` and `a.heic` renders them to two different files.

Two photographs whose names differ only in case (`A.JPG` and `a.jpg`) share a
directory entry on a case-insensitive filesystem such as APFS, and so share a
render and a sidecar. Rename one if you have such a pair.

Renders are stamped with their photograph's modification date, so replacing a
photograph is picked up even when the replacement is older -- restoring from a
backup, or copying with `cp -p`.

Visit numbers are per photograph and are not reused. Deleting visit 2 of 3
leaves the next visit as number 4, so no sidecar overwrites another.

### What a photograph is of

`tags.yml` holds what is currently known about the photograph:

```yaml
# phostor 0.1.0 -- tags for Trips/Skye/img_0421.jpg
# Safe to hand-edit. Unlike a visit sidecar, phostor rewrites this file
# whenever these fields change in the app.
photo: Trips/Skye/img_0421.jpg
updated: '2026-08-24T20:15:41Z'
people:
- Nana Vera
- Uncle Stefan
place: Elgol, Isle of Skye
event: the 1974 camping trip
when: summer 1974
```

Who is in a photograph, where it was taken, what was happening and roughly
when are facts about the photograph. They are not facts about a recording, and
they do not need one: the fields work whether or not a session is running, and
what is typed is written when you move to the next photograph.

**This is the one file phostor rewrites.** Everything else under `sidecars/` is
written once and afterwards only added to. This file holds what is currently
known rather than a record of one session, so it is replaced as that changes.
Hand-edit it freely; just expect the app to overwrite your edit if you then
change the same photograph's fields on screen.

Kept separate from EXIF, which on a scanned print records the date of the scan.

Earlier versions of phostor wrote these four fields into each visit instead,
which meant they could only be entered during a session. Those older sidecars
are still read: a photograph with no `tags.yml` falls back to its most recent
visit, so nothing already recorded is lost, and the first edit writes the file.

### A visit

```yaml
photo: Trips/Skye/img_0421.jpg
visit: 3
session: 2026-08-23-1930
started: '2026-08-23T20:14:07Z'
ended: '2026-08-23T20:15:41Z'
duration: 94.2
audio: visit-0003.mp4
bytes_expected: 812344
people: []
place: ~
event: ~
when: ~
transcript: ~
```

A visit records the recording. `people`, `place`, `event` and `when` are
reserved and written empty: they describe the photograph, so they live in its
`tags.yml`. A sidecar written by an earlier version still holds whatever it
recorded, and is still read. `transcript` is reserved too: the transcript
lives in `visit-NNNN.txt` beside the audio, so that filling it in never means
rewriting a file you may have hand-edited.

`bytes_expected` is how much audio the browser reported recording for the
visit. If it exceeds the size of the recording beside it, some audio did not
reach disk, and the app said so at the time.

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

- `title` — shown in the browser title bar and each session's `session.yml`.
- `display_size` / `thumb_size` — longest edge of the pre-rendered copies.
  `display_size` defaults to 4096, for a 4K display; lower it to 2048 for a
  smaller screen, or if rendering takes too long.
- `min_visit_seconds` — a visit shorter than this logs a row in `path.tsv` but
  writes no sidecar, so paging through photographs does not leave a record for
  each one. Set it to `0` to keep every visit.
- `chunk_seconds` — seconds of audio per upload. Each chunk is written to disk
  as it arrives, so this is also how much a crash can lose.
- `transcribe` — write a transcript for each recording once you move on. See
  [Transcripts](#transcripts).
- `transcribe_locale` — the language to transcribe in, as a BCP-47 tag such as
  `en-GB`. Empty means whatever this Mac is set to.
- `extensions` / `cruft` — what counts as a photograph, and what to skip.

## How recording works

The browser records with `MediaRecorder` and sends the stream in chunks. Each
chunk is appended to a `visit-NNNN.<ext>.part` file as it arrives, and renamed
to its final name when the visit closes. A crash therefore loses one chunk, and
a `.part` file left behind marks an interrupted visit; it is playable, and
phostor does not delete it. `ph_status()` reports them.

Chunks from a single recorder concatenate into a valid file, so no `ffmpeg` or
muxing step is needed: Ogg and WebM are streams of self-framing blocks, and MP4
arrives as an init segment followed by self-contained fragments. phostor pins
the recording format for the session for the same reason.

Chunks are acknowledged one at a time, and an acknowledgement is matched
against the chunk in flight. Shiny coalesces repeated writes to one input
within a flush, so sending without waiting would lose whichever chunk arrived
second; and a retry can put two copies of one chunk on the wire, so the server
skips any sequence number it has already written.

A visit is reported finished only once its recorder has stopped **and** every
chunk it produced has been acknowledged. `MediaRecorder.stop()` is
asynchronous: it flushes a final chunk on a later tick, and reporting the visit
done before that arrives would rename the file out from under it. A chunk that
still arrives late is appended to the finished file rather than dropped;
chunks belonging to a discarded visit are dropped.

The browser also counts the bytes it handed over, and the server compares that
with the file it wrote. A shortfall is shown in the session bar and recorded as
`bytes_expected` in the sidecar, because a session cannot be repeated. A write
that fails outright, and a recorder that stops being able to record, are both
said out loud there too rather than passing in silence.

Because chunks from two recorders cannot be concatenated, a visit records from
one recorder and one microphone throughout. **Check microphone** therefore
listens to the microphone a session already has rather than reopening it, and
the input picker is locked until the session is paused.

One case is not recovered: closing the browser tab mid-visit loses whatever
audio is still queued in the page. What reached disk is kept — the visit's
file is renamed and its sidecar written — but no total arrives from the
browser, so `bytes_expected` is empty and nothing flags the shortfall. End the
session rather than closing the tab.

## Transcripts

When you move on to the next photograph, the one you just left is transcribed
in the background while you talk about the next. The words are written beside
the audio:

```
sidecars/Trips/Skye/img_0421.jpg/
  visit-0001.mp4     what was said
  visit-0001.txt     what it said
  visit-0001.tsv     and when each phrase was said
  visit-0001.yml     everything else
```

`visit-NNNN.txt` is the prose. `visit-NNNN.tsv` is the same words with the
seconds each phrase spans, one row per phrase:

```
start	end	text
0.320	4.100	That is your grandmother beside the car
4.350	7.800	the summer we drove up to Skye
```

That is what lets the app light the words up as the recording plays.

Transcription runs entirely on this Mac. Nothing is uploaded, there is no
account and no per-minute cost. It uses `SpeechAnalyzer`, which arrived in
macOS 26, through a small Swift helper compiled on first use -- so it needs
macOS 26 or newer and Xcode's command line tools (`xcode-select --install`).
Without those, phostor records exactly as before and writes no transcripts.
`ph_preflight()` reports which it found, and which languages are installed.

Turn it off, or fix the language, in `config.yml`:

```yaml
transcribe: true
transcribe_locale: en-GB    # empty means whatever this Mac is set to
```

The sidecar's `transcript:` key stays reserved and is always written as `~`.
Keeping the text in its own file means filling it in never rewrites a
`visit-NNNN.yml` you may have hand-edited, and a slow transcript never races
the sidecar it belongs to.

**Not every recording can be transcribed.** The transcriber reads the
containers AVFoundation opens -- MP4, Ogg, M4A, WAV -- and cannot read WebM,
whatever codec is inside it. Chrome and Firefox are both asked for a readable
container first and only fall back to WebM, so this bites mainly on recordings
made before transcription existed. They still play; they just have no text.

A transcript made before timings existed has a `.txt` and no `.tsv`. It still
reads, in the panel and through `ph_transcript()`; it just cannot follow the
audio. The next `phostor transcribe` picks those up without `--force` and
gives them their timings, once.

To fill in everything that has none, including after changing the language:

```sh
phostor transcribe            # or ph_transcribe_all()
phostor transcribe --force    # redo the ones already done
```

`ph_status()` counts what is still waiting. `ph_transcript()` reads the prose
back, and `ph_transcript_timed()` the phrases with their times.

### Listening back to one photograph

Under the photograph on screen is every visit made to it: each recording with
its own player, and beneath it what was said. Play one and the words light up
as the voice reaches them; click a phrase to hear it from there. The panel
fills itself in a few seconds after you leave a photograph, when the
transcriber finishes with it.

A recording with no timings shows its prose as one block, and one the
transcriber could never read shows just its player. Press `b` to fold the
panel away and give the photograph the height, or `s` for full-screen
presentation. Scrolling on the photograph zooms it, in either.

## Who said it

Naming speakers needs one package phostor does not otherwise require:

```r
install.packages("tuneR")
```

Without it names are still saved, but they will not spread — the app says so
when you name a phrase, and `ph_preflight()` lists it.

Under each phrase of a transcript is a small chip. Click it and say who spoke.
Naming one phrase re-works the whole session, so the names spread to the other
photographs while you are still labelling, and a note tells you how well it is
doing. Nothing to run, and no need to leave the app.

Give each voice **at least two phrases** before the figure means anything:
leaving out the only example a voice has leaves nothing to recognise it by.

From a terminal, over a whole project:

```sh
phostor speakers          # the latest session
phostor speakers --all    # every session
```

```r
ph_speakers_check("~/photo-sto", ph_sessions()$dir[1])   # how well is it doing?
ph_speakers_apply("~/photo-sto", ph_sessions()$dir[1])   # name the rest
```

`ph_app()` holds its R session while it runs, so use a second terminal for
these, or Quit the app first. The panel picks up outside changes when you move
to another photograph. Avoid naming chips in the app at the same moment as
running these elsewhere: both rewrite the same file, and one can undo the other.

`ph_speakers_check()` leaves out each phrase you named in turn, works it out
from the others, and tells you how often it would have been right — on your own
voices, in your own room. Run it before trusting anything automatic. Automatic
names are shown dimmed; correcting one makes it yours, and teaches the next
pass.

**A set of voices reaches only within its session.** This is the one rule that
matters. The same voices, learned from a clean reading and identified across a
room, were named correctly two times in eight; learned from the room itself,
eight times in eight. Labelling phrases from the recording guarantees the match,
because the examples and the speech come from the same microphone in the same
room on the same day. Labels from one session are never used on another.

Two kinds of phrase get no name rather than a guess: those too short to carry a
voice, and those where the best match does not beat the second by enough.

How much is enough is worked out from your own labels rather than fixed in
advance, because it has to be. On one family's recordings the winning margin
was 0.0095 when the guess was right and 0.0011 when it was wrong — it separates
them well, but any threshold chosen beforehand would have named everything or
nothing. So phostor asks how decisive it had to be to be right on the phrases
*you* named, and holds the rest to that.

**What it cannot do.** Two people talking at once cannot be separated by any of
this, and a family round a table does it constantly. Where the transcriber has
run two voices into one phrase, the name will be whichever it sounds more like.

## Read-only guarantee

- `ph_config()` refuses to run when the work directory is the same as, inside,
  or contains `photo_root` — case-insensitively where the filesystem is, since
  `/Volumes/Photo` and `/Volumes/photo` are one directory on APFS.
- Every path phostor writes to is built from the work directory.
- The test suite drives a scripted session through the real app server and
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
the recordings carrying a valid container header for whichever format the
browser chose, `path.tsv` alternating `show`/`leave`, and the photo directory
byte-for-byte unchanged afterwards.

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
