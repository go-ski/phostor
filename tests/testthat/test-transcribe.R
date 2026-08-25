# A stand-in for the Swift helper, so the guards and the plumbing can be
# tested on any machine. It takes the same arguments and writes the same two
# files, in the same order: the .tsv first, so a .txt on disk always has one
# beside it.
stub_transcriber <- function(text = "a stub transcript", status = 0L,
                             timed = TRUE) {
  bin <- tempfile("stub-transcribe-")
  writeLines(c(
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "out=",
    "while [[ $# -gt 0 ]]; do",
    "  case \"$1\" in",
    "    --out) out=\"$2\"; shift 2 ;;",
    "    --locale) shift 2 ;;",
    "    *) shift ;;",
    "  esac",
    "done",
    sprintf("if [[ %d -ne 0 ]]; then echo 'phostor-transcribe: nope' >&2; exit %d; fi",
            status, status),
    # timed = FALSE stands in for the previous version of the helper, which
    # wrote prose and no timings.
    if (timed) c(
      'tsv="${out%.*}.tsv"',
      "printf 'start\\tend\\ttext\\n' > \"$tsv\"",
      sprintf("if [[ -n %s ]]; then printf '0.500\\t2.250\\t%%s\\n' %s >> \"$tsv\"; fi",
              shQuote(text), shQuote(text))),
    sprintf("printf '%%s\\n' %s > \"$out\"", shQuote(text))), bin)
  Sys.chmod(bin, "0755")
  bin
}

# A visit with audio on disk, which is all the guards look at.
make_visit <- function(p, rel = "top.jpg", visit = 1L, ext = "mp4") {
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  f <- file.path(dir, sprintf("visit-%04d.%s", visit, ext))
  writeBin(as.raw(1:64), f)
  basename(f)
}

test_that("a MIME type becomes the extension the container needs", {
  expect_equal(ph_audio_ext("audio/mp4;codecs=mp4a.40.2"), "mp4")
  expect_equal(ph_audio_ext("audio/mp4"), "mp4")
  expect_equal(ph_audio_ext("audio/ogg;codecs=opus"), "ogg")
  expect_equal(ph_audio_ext("audio/webm;codecs=opus"), "webm")
  expect_equal(ph_audio_ext("AUDIO/MP4"), "mp4")
  # Anything unrecognised falls back to what every browser can produce.
  expect_equal(ph_audio_ext("audio/flac"), "webm")
  expect_equal(ph_audio_ext(NULL), "webm")
  expect_equal(ph_audio_ext(""), "webm")
})

test_that("a recording is transcribed to a sibling .txt", {
  p <- make_project()
  audio <- make_visit(p)
  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub_transcriber())
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE), "done")
  expect_equal(ph_transcript(p$cfg, "top.jpg", 1L), "a stub transcript")
})

test_that("the sidecar is not touched: transcript stays reserved", {
  p <- make_project()
  make_visit(p)
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(audio = "visit-0001.mp4"))
  before <- readLines(file.path(ph_visit_dir(p$cfg, "top.jpg"), "visit-0001.yml"))
  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub_transcriber())
  ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE)
  after <- readLines(file.path(ph_visit_dir(p$cfg, "top.jpg"), "visit-0001.yml"))
  expect_identical(before, after)
  expect_true(any(grepl("^transcript: ~", after)))
})

test_that("WebM is skipped without launching anything", {
  p <- make_project()
  make_visit(p, ext = "webm")
  # No binding mocked: reaching for a transcriber here would be the bug.
  expect_match(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE),
               "cannot be read")
})

test_that("each guard gives its own reason", {
  p <- make_project()
  stub <- stub_transcriber()
  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub)

  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE), "no audio")

  audio <- make_visit(p)
  cfg_off <- p$cfg
  cfg_off$transcribe <- FALSE
  expect_equal(ph_transcribe_visit(cfg_off, "top.jpg", 1L, wait = TRUE), "off")

  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE), "done")
  # A second pass does not redo work already done, unless asked.
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE),
               "already transcribed")
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE, force = TRUE),
               "done")

  # A run already in flight is left alone.
  dir <- ph_visit_dir(p$cfg, "top.jpg")
  file.create(file.path(dir, "visit-0001.txt.part"))
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE, force = TRUE),
               "already running")
})

test_that("a failing transcriber is reported, not raised", {
  p <- make_project()
  make_visit(p)
  testthat::local_mocked_bindings(
    ph_transcribe_bin = function() stub_transcriber(status = 3L))
  expect_no_error(r <- ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE))
  expect_match(r, "nope")
  expect_true(is.na(ph_transcript(p$cfg, "top.jpg", 1L)))
})

test_that("no transcript reads back as NA, an empty one as empty", {
  p <- make_project()
  expect_true(is.na(ph_transcript(p$cfg, "top.jpg", 1L)))
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines("", file.path(dir, "visit-0001.txt"))
  expect_equal(ph_transcript(p$cfg, "top.jpg", 1L), "")
})

test_that("status counts only recordings that could still be transcribed", {
  p <- make_project()
  expect_equal(ph_untranscribed(p$cfg), 0L)
  make_visit(p, "top.jpg", 1L, ext = "mp4")
  expect_equal(ph_untranscribed(p$cfg), 1L)
  # A WebM recording is not waiting for anything.
  make_visit(p, "Trips/x.png", 1L, ext = "webm")
  expect_equal(ph_untranscribed(p$cfg), 1L)
  # Prose and timings both, which is what the helper leaves behind.
  d <- ph_visit_dir(p$cfg, "top.jpg")
  writeLines("done", file.path(d, "visit-0001.txt"))
  writeLines("start\tend\ttext", file.path(d, "visit-0001.tsv"))
  expect_equal(ph_untranscribed(p$cfg), 0L)
})

test_that("a backfill walks every recording and reports each one", {
  p <- make_project()
  make_visit(p, "top.jpg", 1L)
  make_visit(p, "top.jpg", 2L)
  make_visit(p, "Trips/Skye/a b.jpg", 1L)
  make_visit(p, "Trips/x.png", 1L, ext = "webm")
  stub <- stub_transcriber()
  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub)
  res <- ph_transcribe_all(p$cfg, quiet = TRUE)
  expect_equal(nrow(res), 4L)
  expect_equal(sum(res$result == "done"), 3L)
  # The photo path a transcript belongs to survives a space in the name.
  expect_true("Trips/Skye/a b.jpg" %in% res$photo)
  expect_equal(ph_transcript(p$cfg, "Trips/Skye/a b.jpg", 1L), "a stub transcript")
  expect_equal(ph_untranscribed(p$cfg), 0L)
})

test_that("config carries the transcription settings", {
  p <- make_project()
  expect_true(p$cfg$transcribe)
  expect_equal(p$cfg$transcribe_locale, "")
  expect_true("transcribe" %in% names(ph_config_defaults()))
  expect_true("transcribe_locale" %in% names(ph_config_defaults()))
})

# --- the real helper, where there is one ------------------------------------

test_that("the Swift helper builds and transcribes actual speech", {
  skip_if_not(ph_transcribe_supported(), "no macOS/swiftc")
  skip_if_not(nzchar(Sys.which("say")), "no say(1) to make speech with")
  bin <- ph_transcribe_build(quiet = TRUE)
  skip_if(is.na(bin), "helper did not build; needs macOS 26 or newer")

  chk <- suppressWarnings(system2(bin, "--check", stdout = TRUE, stderr = TRUE))
  skip_if(!identical(as.integer(attr(chk, "status") %||% 0L), 0L),
          "no speech model installed")

  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  audio <- file.path(dir, "visit-0001.m4a")
  # Ordinary words only. A place name comes back spelled how it sounded
  # ("Elgol" -> "El Gaul"), which would make this test about the model rather
  # than about the pipeline.
  system2("say", c("-o", shQuote(audio), "--data-format=aac",
                   shQuote("This was taken in the summer, down by the river.")),
          stdout = FALSE, stderr = FALSE)
  skip_if(!file.exists(audio), "say(1) wrote nothing")

  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE), "done")
  got <- ph_transcript(p$cfg, "top.jpg", 1L)
  expect_match(got, "summer", ignore.case = TRUE)
  expect_match(got, "river", ignore.case = TRUE)
  # No half-written file is left behind, by either writer.
  expect_false(file.exists(file.path(dir, "visit-0001.txt.part")))
  expect_false(file.exists(file.path(dir, "visit-0001.tsv.part")))

  # The timings the panel highlights from: in order, inside the recording, and
  # covering the words that came back as prose.
  timed <- ph_transcript_timed(p$cfg, "top.jpg", 1L)
  expect_gt(nrow(timed), 0L)
  expect_true(all(timed$start >= 0))
  expect_true(all(timed$end >= timed$start))
  expect_false(is.unsorted(timed$start))
  # One spoken sentence. A generous ceiling, but it is what catches the error
  # that matters here: milliseconds, or CMTime ticks, written as seconds.
  expect_lt(max(timed$end), 60)
  expect_match(paste(timed$text, collapse = " "), "summer", ignore.case = TRUE)
})

test_that("the helper refuses WebM cleanly rather than producing nonsense", {
  skip_if_not(ph_transcribe_supported(), "no macOS/swiftc")
  bin <- ph_transcribe_build(quiet = TRUE)
  skip_if(is.na(bin), "helper did not build; needs macOS 26 or newer")
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  # An empty file is not a WebM, but it is equally unreadable, which is the
  # behaviour under test: a non-zero exit and no output file.
  bad <- file.path(dir, "visit-0001.mp4")
  writeBin(as.raw(rep(0, 128)), bad)
  r <- ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE)
  expect_false(identical(r, "done"))
  expect_true(is.na(ph_transcript(p$cfg, "top.jpg", 1L)))
})

# ---------------------------------------------------------------------------
# timed transcripts
# ---------------------------------------------------------------------------

test_that("the helper's timings are read back as phrases", {
  p <- make_project()
  make_visit(p)
  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub_transcriber())
  ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE)

  timed <- ph_transcript_timed(p$cfg, "top.jpg", 1L)
  expect_equal(nrow(timed), 1L)
  expect_equal(timed$start, 0.5)
  expect_equal(timed$end, 2.25)
  expect_equal(timed$text, "a stub transcript")
  # The prose is still the prose: one file did not replace the other.
  expect_equal(ph_transcript(p$cfg, "top.jpg", 1L), "a stub transcript")
})

test_that("a visit with no .tsv gives no phrases, not an error", {
  p <- make_project()
  make_visit(p)
  testthat::local_mocked_bindings(
    ph_transcribe_bin = function() stub_transcriber(timed = FALSE))
  ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE)

  expect_equal(nrow(ph_transcript_timed(p$cfg, "top.jpg", 1L)), 0L)
  expect_named(ph_transcript_timed(p$cfg, "top.jpg", 1L),
               c("start", "end", "text"))
  # The prose is still readable, which is what the panel falls back to.
  expect_equal(ph_transcript(p$cfg, "top.jpg", 1L), "a stub transcript")
})

test_that("a recording with no speech gives an empty transcript, not a retry", {
  p <- make_project()
  make_visit(p)
  testthat::local_mocked_bindings(
    ph_transcribe_bin = function() stub_transcriber(text = ""))
  ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE)

  dir <- ph_visit_dir(p$cfg, "top.jpg")
  # Both files exist -- that is what stops it being transcribed again.
  expect_true(file.exists(file.path(dir, "visit-0001.txt")))
  expect_true(file.exists(file.path(dir, "visit-0001.tsv")))
  expect_equal(nrow(ph_transcript_timed(p$cfg, "top.jpg", 1L)), 0L)
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE),
               "already transcribed")
})

test_that("speech containing a tab or an apostrophe survives the round trip", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines(c("start\tend\ttext",
               "0.000\t1.500\tit's Kate's dog, #4 in the litter",
               "1.500\t3.000\tand \"quoted\" words too"),
             file.path(dir, "visit-0001.tsv"))

  timed <- ph_transcript_timed(p$cfg, "top.jpg", 1L)
  expect_equal(nrow(timed), 2L)
  expect_equal(timed$text[1], "it's Kate's dog, #4 in the litter")
  expect_equal(timed$text[2], "and \"quoted\" words too")
})

test_that("a malformed or empty .tsv gives no phrases", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)

  writeLines("start\tend\ttext", file.path(dir, "visit-0001.tsv"))
  expect_equal(nrow(ph_transcript_timed(p$cfg, "top.jpg", 1L)), 0L)

  writeLines(character(0), file.path(dir, "visit-0002.tsv"))
  expect_equal(nrow(ph_transcript_timed(p$cfg, "top.jpg", 2L)), 0L)

  # Rows with no usable time are dropped rather than rendered unhighlightable.
  writeLines(c("start\tend\ttext", "-\t-\tsomething"),
             file.path(dir, "visit-0003.tsv"))
  expect_equal(nrow(ph_transcript_timed(p$cfg, "top.jpg", 3L)), 0L)

  expect_equal(nrow(ph_transcript_timed(p$cfg, "nosuch.jpg", 1L)), 0L)
})

test_that("a transcript without timings is re-run once to gain them", {
  p <- make_project()
  make_visit(p)
  dir <- ph_visit_dir(p$cfg, "top.jpg")
  # What the previous version of the helper left behind.
  writeLines("older prose", file.path(dir, "visit-0001.txt"))

  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub_transcriber())
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE), "done")
  expect_equal(nrow(ph_transcript_timed(p$cfg, "top.jpg", 1L)), 1L)
  # And not a third time.
  expect_equal(ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE),
               "already transcribed")
})

test_that("ph_status counts a transcript that has no timings as waiting", {
  p <- make_project()
  make_visit(p)
  dir <- ph_visit_dir(p$cfg, "top.jpg")
  writeLines("older prose", file.path(dir, "visit-0001.txt"))
  expect_equal(ph_untranscribed(p$cfg), 1L)

  writeLines("start\tend\ttext", file.path(dir, "visit-0001.tsv"))
  expect_equal(ph_untranscribed(p$cfg), 0L)
})

# ---------------------------------------------------------------------------
# what the panel polls on
# ---------------------------------------------------------------------------

test_that("a fresh readable recording is waited on until its transcript lands", {
  p <- make_project()
  make_visit(p)
  expect_true(ph_visit_waiting(p$cfg, "top.jpg", 1L))

  testthat::local_mocked_bindings(ph_transcribe_bin = function() stub_transcriber())
  ph_transcribe_visit(p$cfg, "top.jpg", 1L, wait = TRUE)
  expect_false(ph_visit_waiting(p$cfg, "top.jpg", 1L))
})

test_that("nothing that can never be transcribed is waited on", {
  p <- make_project()

  # WebM: the transcriber cannot open it, so there is nothing to wait for.
  make_visit(p, rel = "a.jpg", ext = "webm")
  expect_false(ph_visit_waiting(p$cfg, "a.jpg", 1L))

  # No audio at all.
  ph_visit_dir(p$cfg, "b.jpg", create = TRUE)
  expect_false(ph_visit_waiting(p$cfg, "b.jpg", 1L))

  # Transcription switched off.
  make_visit(p, rel = "c.jpg")
  off <- p$cfg
  off$transcribe <- FALSE
  expect_false(ph_visit_waiting(off, "c.jpg", 1L))
})

test_that("a recording old enough to have failed stops being waited on", {
  p <- make_project()
  audio <- make_visit(p)
  f <- file.path(ph_visit_dir(p$cfg, "top.jpg"), audio)
  Sys.setFileTime(f, Sys.time() - 600)
  expect_false(ph_visit_waiting(p$cfg, "top.jpg", 1L))
  # The cut-off is a parameter, so the app can wait longer if it ever needs to.
  expect_true(ph_visit_waiting(p$cfg, "top.jpg", 1L, within = 3600))
})
