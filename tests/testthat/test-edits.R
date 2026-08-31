# Corrections to a transcript. None of these needs audio or a transcriber: an
# edit is a rule about rows, so the transcripts are planted by hand, as
# test-speakers.R plants them.

plant <- function(p, rel = "top.jpg", rows = NULL) {
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  if (is.null(rows)) {
    rows <- c("0.000\t4.000\tand we drove up to Skye no it was Mull",
              "4.000\t6.000\tI remember that")
  }
  stem <- file.path(dir, ph_visit_stem(1L))
  writeLines(c("start\tend\ttext", rows), paste0(stem, ".tsv"))
  writeLines(paste(sub("^[^\t]*\t[^\t]*\t", "", rows), collapse = " "),
             paste0(stem, ".txt"))
  dir
}

no_edits <- function() {
  data.frame(orig = numeric(0), start = numeric(0), end = numeric(0),
             text = character(0), stringsAsFactors = FALSE)
}

test_that("an overlay replaces the phrase it names and leaves the rest", {
  timed <- data.frame(start = c(0, 4), end = c(4, 6),
                      text = c("one two", "three"), stringsAsFactors = FALSE)
  edits <- data.frame(orig = c(0, 0), start = c(0, 2), end = c(2, 4),
                      text = c("one", "two"), stringsAsFactors = FALSE)
  got <- ph_edits_apply(timed, edits)
  expect_equal(got$start, c(0, 2, 4))
  expect_equal(got$end, c(2, 4, 6))
  expect_equal(got$text, c("one", "two", "three"))
  expect_named(got, c("start", "end", "text"))

  # Nothing to apply, and nothing to apply it to.
  expect_equal(ph_edits_apply(timed, no_edits()), timed)
  expect_equal(nrow(ph_edits_apply(timed[0, ], edits)), 0L)
})

test_that("an orphaned correction is dropped, not applied elsewhere", {
  timed <- data.frame(start = c(0, 4), end = c(4, 6),
                      text = c("one two", "three"), stringsAsFactors = FALSE)
  # What re-transcribing leaves behind: the boundaries moved, so no phrase
  # starts where this correction says one did.
  edits <- data.frame(orig = 1.5, start = 1.5, end = 3, text = "stale",
                      stringsAsFactors = FALSE)
  expect_equal(ph_edits_apply(timed, edits), timed)
})

test_that("a split shows through the transcript and keeps the first half's name", {
  p <- make_project()
  plant(p)
  ph_speaker_label(p$cfg, "top.jpg", 1L, start = 0, speaker = "Beth")

  ph_phrase_split(p$cfg, "top.jpg", 1L, start = 0, at = 2.4,
                  before = "and we drove up to Skye", after = "no it was Mull")
  timed <- ph_transcript_timed(p$cfg, "top.jpg", 1L)
  expect_equal(nrow(timed), 3L)
  expect_equal(timed$start, c(0, 2.4, 4))
  expect_equal(timed$text[1:2], c("and we drove up to Skye", "no it was Mull"))

  # The first half keeps the start, so the name given before the split is
  # still its name -- and its recorded end now stops where the other voice
  # began, rather than covering both people.
  lab <- ph_speakers_read(p$cfg, "top.jpg", 1L)
  expect_equal(nrow(lab), 1L)
  expect_equal(lab$speaker, "Beth")
  expect_equal(lab$end, 2.4)

  # The second half is new and nobody has named it.
  expect_false(any(abs(lab$start - 2.4) < 0.01))
})

test_that("splitting a half that was itself made by a split rewrites one group", {
  p <- make_project()
  dir <- plant(p)
  ph_phrase_split(p$cfg, "top.jpg", 1L, start = 0, at = 2.4,
                  before = "and we drove up to Skye", after = "no it was Mull")
  ph_phrase_split(p$cfg, "top.jpg", 1L, start = 2.4, at = 3.2,
                  before = "no", after = "it was Mull")

  timed <- ph_transcript_timed(p$cfg, "top.jpg", 1L)
  expect_equal(nrow(timed), 4L)
  expect_equal(timed$start, c(0, 2.4, 3.2, 4))

  # One original phrase, so one group: a start the transcriber never wrote must
  # not become an `orig` of its own, or re-transcribing would leave half of a
  # split behind.
  edits <- ph_edits_read(p$cfg, "top.jpg", 1L)
  expect_equal(unique(edits$orig), 0)
  expect_equal(nrow(edits), 3L)
})

test_that("correcting the words leaves the timing alone and reads back", {
  p <- make_project()
  plant(p)
  before <- ph_transcript_timed(p$cfg, "top.jpg", 1L)

  ph_phrase_text(p$cfg, "top.jpg", 1L, start = 4, text = "I remember it well")
  after <- ph_transcript_timed(p$cfg, "top.jpg", 1L)
  expect_equal(after$start, before$start)
  expect_equal(after$end, before$end)
  expect_equal(after$text[2], "I remember it well")

  # The prose has to agree with the phrases, or ph_transcript() and the panel
  # would say different things about one recording.
  expect_match(ph_transcript(p$cfg, "top.jpg", 1L), "I remember it well",
               fixed = TRUE)
})

test_that("a correction round-trips non-ASCII", {
  p <- make_project()
  plant(p)
  said <- "c'était à Skýe — na h-Eileanan"
  ph_phrase_text(p$cfg, "top.jpg", 1L, start = 4, text = said)
  got <- ph_transcript_timed(p$cfg, "top.jpg", 1L)$text[2]
  expect_equal(got, said)
})

test_that("a split must name a phrase, and must fall inside it", {
  p <- make_project()
  plant(p)
  expect_error(ph_phrase_split(p$cfg, "top.jpg", 1L, start = 99, at = 1,
                               before = "a", after = "b"),
               "no phrase starts")
  expect_error(ph_phrase_split(p$cfg, "top.jpg", 1L, start = 0, at = 9,
                               before = "a", after = "b"),
               "outside the phrase")
  expect_error(ph_phrase_split(p$cfg, "top.jpg", 1L, start = 0, at = 2,
                               before = "a", after = "  "),
               "words on both sides")
  expect_error(ph_phrase_text(p$cfg, "top.jpg", 1L, start = 0, text = " "),
               "cannot be corrected to nothing")
})

test_that("the edits file is invisible to everything that walks visits", {
  p <- make_project()
  dir <- plant(p)
  writeLines("x", paste0(file.path(dir, ph_visit_stem(1L)), ".wav"))
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(audio = "visit-0001.wav"))
  ph_phrase_split(p$cfg, "top.jpg", 1L, start = 0, at = 2.4,
                  before = "and we drove up to Skye", after = "no it was Mull")
  expect_true(file.exists(file.path(dir, "visit-0001-edits.tsv")))

  # The name breaks the `visit-NNNN.` prefix on purpose. If any of these starts
  # counting it, the file becomes a visit of its own.
  expect_equal(ph_visit_numbers(dir), 1L)
  expect_equal(length(ph_visits_for(p$cfg, "top.jpg")), 1L)
  expect_true(ph_has_transcript(dir, 1L))
  expect_equal(ph_visit_counts(p$cfg, "top.jpg"), 1L)
})

test_that("a phrase's words divide between words, never inside one", {
  said <- "up to Skye no it was Mull"
  # Where a double-clicked word begins: the whole word goes to the right.
  expect_equal(ph_phrase_cut(said, 11),
               list(before = "up to Skye", after = "no it was Mull"))
  # Inside a word, and the boundary before it is used.
  expect_equal(ph_phrase_cut(said, 12)$before, "up to Skye")
  # Nothing to the left to divide at: the first word goes left rather than
  # being cut in half.
  expect_equal(ph_phrase_cut(said, 1)$before, "up")
  # No room for a second half, so none is offered.
  expect_equal(ph_phrase_cut(said, 0), list(before = said, after = ""))
  expect_equal(ph_phrase_cut(said, 99)$after, "")
  expect_equal(ph_phrase_cut("", 0), list(before = "", after = ""))
})

test_that("split phrases are counted as phrases", {
  p <- make_project()
  plant(p)
  expect_equal(ph_named_counts(p$cfg)$total, 2L)
  ph_phrase_split(p$cfg, "top.jpg", 1L, start = 0, at = 2.4,
                  before = "and we drove up to Skye", after = "no it was Mull")
  expect_equal(ph_named_counts(p$cfg)$total, 3L)
})

# --------------------------------------------------------------------------
# through the app
# --------------------------------------------------------------------------

test_that("splitting a phrase in the app divides it and asks who the rest was", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  writeLines(c("start\tend\ttext",
               "0.000\t4.000\tand we drove up to Skye no it was Mull"),
             file.path(dir, "visit-0001.tsv"))
  writeLines("and we drove up to Skye no it was Mull",
             file.path(dir, "visit-0001.txt"))
  ph_write_sidecar(p$cfg, rel, 1L, list(audio = "visit-0001.wav"))
  id <- idx$id[match(rel, idx$rel_path)]

  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = id)
    # 23 is where "no" begins, which is what double-clicking that word gives.
    session$setInputs(phrase_edit = list(rel = rel, visit = 1, start = 0,
                                         offset = 23))
    expect_equal(as.numeric(rv$phrase_at$start), 0)
    # The dialog's own fields never reach the server under testServer -- the
    # browser is what sends them -- so they are set here as the browser would.
    # What they are seeded with is ph_phrase_cut(), tested on its own above.
    session$setInputs(phrase_before = "and we drove up to Skye",
                      phrase_after = "no it was Mull",
                      phrase_split_at = 2.4)
    session$setInputs(phrase_split = 1)
    # Dividing a sentence is only ever done because the voice changed, so the
    # second half is what it goes on to ask about.
    expect_equal(as.numeric(rv$speaker_at$start), 2.4)
  })

  timed <- ph_transcript_timed(p$cfg, rel, 1L)
  expect_equal(nrow(timed), 2L)
  expect_equal(timed$text, c("and we drove up to Skye", "no it was Mull"))
})

test_that("Save puts the two parts back as one corrected phrase", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t4.000\tup to the mall"),
             file.path(dir, "visit-0001.tsv"))
  writeLines("up to the mall", file.path(dir, "visit-0001.txt"))
  ph_write_sidecar(p$cfg, rel, 1L, list(audio = "visit-0001.wav"))
  id <- idx$id[match(rel, idx$rel_path)]

  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = id)
    session$setInputs(phrase_edit = list(rel = rel, visit = 1, start = 0,
                                         offset = 0))
    session$setInputs(phrase_before = "up to Mull", phrase_after = "")
    session$setInputs(phrase_save = 1)
  })
  timed <- ph_transcript_timed(p$cfg, rel, 1L)
  expect_equal(nrow(timed), 1L)
  expect_equal(timed$text, "up to Mull")
  expect_equal(timed$end, 4)
})

test_that("Same as above takes a chip away by making the run one person's", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\tone", "2.000\t4.000\ttwo"),
             file.path(dir, "visit-0001.tsv"))
  ph_write_sidecar(p$cfg, rel, 1L, list(audio = "visit-0001.wav"))
  ph_speaker_label(p$cfg, rel, 1L, start = 0, speaker = "Beth")
  id <- idx$id[match(rel, idx$rel_path)]

  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = id)
    session$setInputs(speaker_pick = list(rel = rel, visit = 1, start = 2))
    expect_equal(rv$speaker_prev, "Beth")
    session$setInputs(speaker_same = 1)
  })

  # Written as a person's own answer, so tidying the transcript also teaches.
  got <- ph_speakers_read(p$cfg, rel, 1L)
  expect_equal(got$speaker, c("Beth", "Beth"))
  expect_equal(got$source, c("manual", "manual"))

  # And the second chip is gone, because the voice did not change.
  run <- ph_speaker_runs(ph_transcript_timed(p$cfg, rel, 1L), got)
  expect_equal(run$lead, c(TRUE, FALSE))
})
