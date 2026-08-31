# Speaker naming needs real speech to mean anything, so these build a session
# out of two macOS voices, where the truth is known by construction. Skipped
# wherever the parts are missing, as the transcription tests already are.

have_voices <- function() {
  if (!nzchar(Sys.which("say"))) return(FALSE)
  v <- suppressWarnings(system2("say", "-v ?", stdout = TRUE, stderr = FALSE))
  sum(c("Samantha", "Daniel") %in% sub("^(\\S+).*", "\\1", v)) == 2L
}
skip_without_speech <- function() {
  skip_if_not_installed("tuneR")
  skip_if_not(have_voices(), "needs the Samantha and Daniel voices")
  skip_if_not(ph_transcribe_supported(), "needs macOS and swiftc to decode")
  skip_if(is.na(ph_transcribe_build(quiet = TRUE)), "helper did not build")
}

# A session of `n` visits per voice, each visit one recording of that voice
# with a transcript of `per` phrases. Truth is the voice that spoke it.
make_session <- function(p, per = 3L) {
  lines <- c(
    "The old house stood at the end of a long lane, shaded by elms.",
    "She kept the letters in a tin box under the bed, tied with a ribbon.",
    "Nobody wanted to go indoors while the light was still on the water.")
  # ph_path_new() rather than a hand-made directory: it writes session.yml and
  # the path.tsv header, without which ph_playlist() reads nothing.
  sess <- ph_path_new(p$cfg, title = "speakers")
  idx <- ph_read_index(p$cfg)
  truth <- character(0)
  for (k in seq_along(c("Samantha", "Daniel"))) {
    voice <- c("Samantha", "Daniel")[k]
    rel <- idx$rel_path[k]
    dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
    wav <- file.path(dir, "visit-0001.wav")
    system2("say", c("-v", voice, "-o", shQuote(wav), "--file-format=WAVE",
                     "--data-format=LEI16@22050",
                     shQuote(paste(lines[seq_len(per)], collapse = " "))),
            stdout = FALSE, stderr = FALSE)
    # Phrase boundaries: split the recording evenly, which is all the truth
    # here needs -- one voice per recording.
    secs <- length(tuneR::readWave(wav)@left) / 22050
    edges <- seq(0, secs, length.out = per + 1L)
    writeLines(c("start\tend\ttext",
                 sprintf("%.3f\t%.3f\t%s", edges[-(per + 1L)], edges[-1],
                         lines[seq_len(per)])),
               file.path(dir, "visit-0001.tsv"))
    ph_write_sidecar(p$cfg, rel, 1L, list(audio = "visit-0001.wav",
                                          session = basename(sess)))
    ph_path_append(sess, "show", rel_path = rel, visit = 1L)
    ph_path_append(sess, "leave", rel_path = rel, visit = 1L, duration = secs)
    truth <- c(truth, rep(voice, per))
  }
  ph_path_append(sess, "end")
  list(dir = sess, truth = truth,
       rel = idx$rel_path[1:2], per = per)
}

test_that("a label is written, read back, and can be cleared", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello there",
               "2.000\t4.000\tand again"), file.path(dir, "visit-0001.tsv"))

  ph_speaker_label(p$cfg, "top.jpg", 1L, start = 0, speaker = "Beth")
  got <- ph_speakers_read(p$cfg, "top.jpg", 1L)
  expect_equal(nrow(got), 1L)
  expect_equal(got$speaker, "Beth")
  expect_equal(got$source, "manual")

  # Setting a different name replaces rather than adds.
  ph_speaker_label(p$cfg, "top.jpg", 1L, start = 0, speaker = "Marty")
  expect_equal(ph_speakers_read(p$cfg, "top.jpg", 1L)$speaker, "Marty")

  ph_speaker_label(p$cfg, "top.jpg", 1L, start = 0, speaker = "")
  expect_equal(nrow(ph_speakers_read(p$cfg, "top.jpg", 1L)), 0L)
})

test_that("a label must belong to a phrase that exists", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello"),
             file.path(dir, "visit-0001.tsv"))
  expect_error(ph_speaker_label(p$cfg, "top.jpg", 1L, start = 99, speaker = "X"),
               "no phrase starts")
})

test_that("the labels file is invisible to everything that walks visits", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello"),
             file.path(dir, "visit-0001.tsv"))
  before <- list(numbers = ph_visit_numbers(dir),
                 counts = ph_visit_counts(p$cfg, "top.jpg"),
                 visits = length(ph_visits_for(p$cfg, "top.jpg")),
                 waiting = phostor:::ph_untranscribed(p$cfg))
  ph_speaker_label(p$cfg, "top.jpg", 1L, start = 0, speaker = "Beth")
  expect_true(file.exists(file.path(dir, "visit-0001-speakers.tsv")))
  # The transcript beside it is a visit file and rightly counts; the labels
  # must add nothing to any of these.
  expect_equal(ph_visit_numbers(dir), before$numbers)
  expect_equal(ph_visit_counts(p$cfg, "top.jpg"), before$counts)
  expect_equal(length(ph_visits_for(p$cfg, "top.jpg")), before$visits)
  expect_equal(phostor:::ph_untranscribed(p$cfg), before$waiting)
})

test_that("names with awkward characters survive the round trip", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "Trips/Skye/a b.jpg", create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello"),
             file.path(dir, "visit-0001.tsv"))
  ph_speaker_label(p$cfg, "Trips/Skye/a b.jpg", 1L, start = 0,
                   speaker = "Nana Vera O'Hara")
  expect_equal(ph_speakers_read(p$cfg, "Trips/Skye/a b.jpg", 1L)$speaker,
               "Nana Vera O'Hara")
})

test_that("two voices are told apart, and the check says how well", {
  skip_without_speech()
  p <- make_project()
  s <- make_session(p)

  # Label the first phrase of each recording; the rest are for it to work out.
  for (k in 1:2) {
    timed <- ph_transcript_timed(p$cfg, s$rel[k], 1L)
    for (i in 1:2) {
      ph_speaker_label(p$cfg, s$rel[k], 1L, start = timed$start[i],
                       speaker = c("Samantha", "Daniel")[k])
    }
  }
  chk <- ph_speakers_check(p$cfg, s$dir, quiet = TRUE)
  expect_gte(chk$n, 4L)
  expect_equal(chk$accuracy, 1)

  out <- ph_speakers_apply(p$cfg, s$dir, quiet = TRUE)
  expect_gt(nrow(out), 0L)
  # Every automatic name matches the voice that really spoke it.
  right <- vapply(seq_len(nrow(out)), function(i) {
    identical(out$speaker[i], if (out$rel_path[i] == s$rel[1]) "Samantha" else "Daniel")
  }, logical(1))
  expect_true(all(right))
})

test_that("hand labels are never overwritten by the machine", {
  skip_without_speech()
  p <- make_project()
  s <- make_session(p)
  for (k in 1:2) {
    timed <- ph_transcript_timed(p$cfg, s$rel[k], 1L)
    for (i in 1:2) {
      ph_speaker_label(p$cfg, s$rel[k], 1L, start = timed$start[i],
                       speaker = c("Samantha", "Daniel")[k])
    }
  }
  # A deliberately wrong hand label must survive: a person outranks a guess.
  timed <- ph_transcript_timed(p$cfg, s$rel[1], 1L)
  ph_speaker_label(p$cfg, s$rel[1], 1L, start = timed$start[1], speaker = "Zed")
  ph_speakers_apply(p$cfg, s$dir, quiet = TRUE)
  got <- ph_speakers_read(p$cfg, s$rel[1], 1L)
  kept <- got[abs(got$start - timed$start[1]) < 0.01, ]
  expect_equal(kept$speaker, "Zed")
  expect_equal(kept$source, "manual")
})

test_that("scrambled labels do no better than chance", {
  # Two of the three surprising results while measuring this were bugs in the
  # scoring rather than findings. This is the assertion that catches that.
  skip_without_speech()
  p <- make_project()
  s <- make_session(p)
  for (k in 1:2) {
    timed <- ph_transcript_timed(p$cfg, s$rel[k], 1L)
    for (i in seq_len(nrow(timed))) {
      ph_speaker_label(p$cfg, s$rel[k], 1L, start = timed$start[i],
                       speaker = c("Samantha", "Daniel")[k])
    }
  }
  expect_equal(ph_speakers_check(p$cfg, s$dir, quiet = TRUE)$accuracy, 1)

  # The same phrases, names shuffled: nothing real is left to learn.
  #
  # The bar is "clearly worse than perfect", not "at chance". With this many
  # phrases a single shuffle can land at four of six by luck, and averaging
  # over enough shuffles to pin down chance would mean decoding the audio
  # dozens of times. What has to be caught is a scorer that reports success
  # whatever it is given -- predicting a phrase from itself, say -- and that
  # would come back at 1 here.
  set.seed(3)
  shuffled <- sample(rep(c("Samantha", "Daniel"), each = s$per))
  n <- 0L
  for (k in 1:2) {
    timed <- ph_transcript_timed(p$cfg, s$rel[k], 1L)
    for (i in seq_len(nrow(timed))) {
      n <- n + 1L
      ph_speaker_label(p$cfg, s$rel[k], 1L, start = timed$start[i],
                       speaker = shuffled[n])
    }
  }
  expect_lt(ph_speakers_check(p$cfg, s$dir, quiet = TRUE)$accuracy, 0.9)
})

test_that("a visit knows which session it belongs to", {
  p <- make_project()
  sess <- ph_path_new(p$cfg, title = "one")
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(session = basename(sess)))
  expect_equal(ph_visit_session(p$cfg, "top.jpg", 1L), sess)

  # Recorded outside any session, or a session since removed.
  ph_write_sidecar(p$cfg, "top.jpg", 2L, list())
  expect_null(ph_visit_session(p$cfg, "top.jpg", 2L))
  ph_write_sidecar(p$cfg, "top.jpg", 3L, list(session = "2000-01-01-0000"))
  expect_null(ph_visit_session(p$cfg, "top.jpg", 3L))
})

test_that("names are offered from the whole session, not one photograph", {
  skip_without_speech()
  p <- make_project()
  s <- make_session(p)
  timed <- ph_transcript_timed(p$cfg, s$rel[1], 1L)
  ph_speaker_label(p$cfg, s$rel[1], 1L, start = timed$start[1], speaker = "Marty")

  # The name was given on the first photograph; it must be known on the second,
  # or it has to be retyped on every one.
  expect_equal(ph_speakers_names(p$cfg, s$dir), "Marty")
  expect_true("Marty" %in%
                ph_speakers_names(p$cfg, ph_visit_session(p$cfg, s$rel[2], 1L)))
})

test_that("naming a phrase spreads to the other photographs of the session", {
  skip_without_speech()
  p <- app_project()
  s <- make_session(p)
  idx <- ph_read_index(p$cfg)
  # Two names on the first photograph, one on the second: enough to learn from.
  t1 <- ph_transcript_timed(p$cfg, s$rel[1], 1L)
  t2 <- ph_transcript_timed(p$cfg, s$rel[2], 1L)
  ph_speaker_label(p$cfg, s$rel[1], 1L, start = t1$start[1], speaker = "Samantha")
  ph_speaker_label(p$cfg, s$rel[2], 1L, start = t2$start[1], speaker = "Daniel")

  id2 <- idx$id[match(s$rel[2], idx$rel_path)]
  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = id2)
    session$setInputs(speaker_pick = list(rel = s$rel[2], visit = 1,
                                          start = t2$start[2]))
    session$setInputs(speaker_name = "Daniel")
    session$setInputs(speaker_save = 1)
  })
  # The first photograph was never touched in the app, and now carries names.
  auto <- ph_speakers_read(p$cfg, s$rel[1], 1L)
  expect_gt(sum(auto$source == "auto"), 0L)
  expect_true(all(auto$speaker[auto$source == "auto"] == "Samantha"))
})

test_that("a hand label survives the spreading", {
  skip_without_speech()
  p <- app_project()
  s <- make_session(p)
  idx <- ph_read_index(p$cfg)
  t1 <- ph_transcript_timed(p$cfg, s$rel[1], 1L)
  t2 <- ph_transcript_timed(p$cfg, s$rel[2], 1L)
  ph_speaker_label(p$cfg, s$rel[1], 1L, start = t1$start[1], speaker = "Samantha")
  ph_speaker_label(p$cfg, s$rel[2], 1L, start = t2$start[1], speaker = "Daniel")
  # Deliberately wrong, by hand: a person outranks a guess even unattended.
  ph_speaker_label(p$cfg, s$rel[1], 1L, start = t1$start[2], speaker = "Zed")

  id1 <- idx$id[match(s$rel[1], idx$rel_path)]
  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = id1)
    session$setInputs(speaker_pick = list(rel = s$rel[1], visit = 1,
                                          start = t1$start[1]))
    session$setInputs(speaker_name = "Samantha")
    session$setInputs(speaker_save = 1)
  })
  got <- ph_speakers_read(p$cfg, s$rel[1], 1L)
  kept <- got[abs(got$start - t1$start[2]) < 0.01, ]
  expect_equal(kept$speaker, "Zed")
  expect_equal(kept$source, "manual")
})

test_that("the second run over a session is faster than the first", {
  # Decoding used to happen three times per run, invisibly. The cache is what
  # makes naming-as-you-label bearable, so its absence must be a failure.
  skip_without_speech()
  p <- make_project()
  s <- make_session(p)
  for (k in 1:2) {
    timed <- ph_transcript_timed(p$cfg, s$rel[k], 1L)
    ph_speaker_label(p$cfg, s$rel[k], 1L, start = timed$start[1],
                     speaker = c("Samantha", "Daniel")[k])
  }
  first <- system.time(ph_speakers_apply(p$cfg, s$dir, quiet = TRUE))[["elapsed"]]
  again <- system.time(ph_speakers_apply(p$cfg, s$dir, quiet = TRUE))[["elapsed"]]
  expect_lt(again, first)
})

test_that("naming a phrase does nothing extra when tuneR is absent", {
  # tuneR is only suggested. Clicking a chip must save the label and carry on,
  # never raise, on the machines that do not have it.
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello there"),
             file.path(dir, "visit-0001.tsv"))
  ph_write_sidecar(p$cfg, rel, 1L, list())

  # The real one is captured before the binding is replaced: reaching for
  # base::requireNamespace inside the mock reaches the mock.
  real <- base::requireNamespace
  local_mocked_bindings(
    requireNamespace = function(package, ...) {
      if (identical(package, "tuneR")) FALSE else real(package, ...)
    }, .package = "base")
  expect_no_error(shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = idx$id[1])
    session$setInputs(speaker_pick = list(rel = rel, visit = 1, start = 0))
    session$setInputs(speaker_name = "Beth")
    session$setInputs(speaker_save = 1)
  }))
  expect_equal(ph_speakers_read(p$cfg, rel, 1L)$speaker, "Beth")
})

test_that("the command line names the latest session", {
  skip_without_speech()
  p <- make_project()
  s <- make_session(p)
  for (k in 1:2) {
    timed <- ph_transcript_timed(p$cfg, s$rel[k], 1L)
    ph_speaker_label(p$cfg, s$rel[k], 1L, start = timed$start[1],
                     speaker = c("Samantha", "Daniel")[k])
  }
  expect_message(ph_cli(c("speakers", "--work", p$work)), "named")
  expect_gt(sum(ph_speakers_read(p$cfg, s$rel[1], 1L)$source == "auto"), 0L)
})

test_that("preflight names tuneR without failing for want of it", {
  msgs <- capture.output(ph_preflight(), type = "message")
  expect_true(any(grepl("tuneR", msgs)))
  # Optional: a missing suggested package must not make preflight say no.
  if (!requireNamespace("tuneR", quietly = TRUE)) {
    expect_true(any(grepl("^warn +tuneR", msgs)))
    expect_false(any(grepl("^miss +tuneR", msgs)))
  }
})

test_that("the app says why names will not spread, once", {
  # The failure that prompted this: the label saved, nothing spread, and
  # nothing said why. Never raising is right; saying nothing was not.
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello there",
               "2.000\t4.000\tand again"), file.path(dir, "visit-0001.tsv"))
  ph_write_sidecar(p$cfg, rel, 1L, list())

  real <- base::requireNamespace
  local_mocked_bindings(
    requireNamespace = function(package, ...) {
      if (identical(package, "tuneR")) FALSE else real(package, ...)
    }, .package = "base")
  said <- 0L
  local_mocked_bindings(
    showNotification = function(...) { said <<- said + 1L; invisible("id") },
    .package = "shiny")

  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = idx$id[1])
    expect_false(isTRUE(rv$told_tuneR))

    session$setInputs(speaker_pick = list(rel = rel, visit = 1, start = 0))
    session$setInputs(speaker_name = "Beth")
    session$setInputs(speaker_save = 1)
    expect_true(rv$told_tuneR)          # said

    # Naming a second phrase must not say it again. Counted rather than read
    # off the flag: a sentinel value there is not TRUE, so it would defeat the
    # very guard under test.
    session$setInputs(speaker_pick = list(rel = rel, visit = 1, start = 2))
    session$setInputs(speaker_name = "Marty")
    session$setInputs(speaker_save = 1)
    expect_true(rv$told_tuneR)
  })
  expect_equal(said, 1L)
  # And both labels were saved regardless.
  expect_equal(nrow(ph_speakers_read(p$cfg, rel, 1L)), 2L)
})

test_that("the startup notice is only for someone already naming speakers", {
  # ph_app_notes() rather than ph_app(): the latter binds a port and blocks,
  # and a test must not fight whatever is already listening on it.
  p <- make_project()
  real <- base::requireNamespace
  local_mocked_bindings(
    requireNamespace = function(package, ...) {
      if (identical(package, "tuneR")) FALSE else real(package, ...)
    }, .package = "base")

  # Nothing named yet: nothing to say.
  expect_silent(phostor:::ph_app_notes(p$cfg))

  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\thello"),
             file.path(dir, "visit-0001.tsv"))
  ph_speaker_label(p$cfg, "top.jpg", 1L, start = 0, speaker = "Beth")
  expect_message(phostor:::ph_app_notes(p$cfg), "tuneR")
})

# --------------------------------------------------------------------------
# runs, colours, and what the voices are learned from
# --------------------------------------------------------------------------

test_that("a chip marks where the voice changed, and nowhere else", {
  timed <- data.frame(start = c(0, 2, 4, 6, 8, 10), end = c(2, 4, 6, 8, 10, 12),
                      text = letters[1:6], stringsAsFactors = FALSE)
  labels <- data.frame(start = c(0, 2, 4, 8, 10), end = c(2, 4, 6, 10, 12),
                       speaker = c("Beth", "Beth", "Beth", "Marty", "Marty"),
                       source = c("manual", "auto", "manual", "manual",
                                  "manual"),
                       confidence = c(1, .5, 1, 1, 1), stringsAsFactors = FALSE)
  run <- ph_speaker_runs(timed, labels)

  # Three chips for six phrases: Beth, the unnamed one, Marty.
  expect_equal(run$lead, c(TRUE, FALSE, FALSE, TRUE, TRUE, FALSE))
  expect_equal(run$run, c(1, 1, 1, 2, 3, 3))

  # Beth's own name followed by Beth guessed is still Beth talking, so the
  # provenance changing does not open a run -- but it does stop the chip
  # claiming that everything under it is ground truth.
  expect_false(run$all_manual[1])
  expect_true(run$all_manual[5])
})

test_that("unnamed phrases never collapse into one another", {
  timed <- data.frame(start = c(0, 2, 4), end = c(2, 4, 6),
                      text = letters[1:3], stringsAsFactors = FALSE)
  run <- ph_speaker_runs(timed, ph_speakers_read_empty())
  # Every "+" has to stay clickable, or a phrase becomes unnameable.
  expect_true(all(run$lead))
  expect_equal(run$speaker, rep("", 3))
})

test_that("a run of one, and no phrases at all", {
  timed <- data.frame(start = 0, end = 2, text = "a", stringsAsFactors = FALSE)
  labels <- data.frame(start = 0, end = 2, speaker = "Beth", source = "manual",
                       confidence = 1, stringsAsFactors = FALSE)
  run <- ph_speaker_runs(timed, labels)
  expect_true(run$lead)
  expect_true(run$all_manual)
  expect_equal(nrow(ph_speaker_runs(timed[0, ], labels)), 0L)
})

test_that("colours are handed out in the order voices are first heard", {
  p <- make_project()
  sess <- ph_path_new(p$cfg, title = "colours")
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1:2]
  for (k in 1:2) {
    dir <- ph_visit_dir(p$cfg, rel[k], create = TRUE)
    writeLines(c("start\tend\ttext", "0.000\t2.000\tone", "2.000\t4.000\ttwo"),
               file.path(dir, "visit-0001.tsv"))
    ph_write_sidecar(p$cfg, rel[k], 1L, list(session = basename(sess)))
    ph_path_append(sess, "show", rel_path = rel[k], visit = 1L)
    ph_path_append(sess, "leave", rel_path = rel[k], visit = 1L, duration = 4)
  }
  ph_path_append(sess, "end")

  # Marty speaks second on the first photograph, Beth first.
  ph_speaker_label(p$cfg, rel[1], 1L, start = 0, speaker = "Beth")
  ph_speaker_label(p$cfg, rel[1], 1L, start = 2, speaker = "Marty")
  ph_speaker_label(p$cfg, rel[2], 1L, start = 0, speaker = "Vera")
  expect_equal(ph_speaker_slots(p$cfg, sess),
               c(Beth = 1L, Marty = 2L, Vera = 3L))

  # A voice past the last slot keeps its name and loses its hue, rather than
  # borrowing the first voice's colour and putting two people in one.
  ph_speaker_label(p$cfg, rel[2], 1L, start = 2, speaker = "Stefan")
  dir <- ph_visit_dir(p$cfg, rel[2])
  writeLines(c("start\tend\ttext", "0.000\t2.000\tone", "2.000\t4.000\ttwo",
               "4.000\t6.000\tthree"), file.path(dir, "visit-0001.tsv"))
  ph_speaker_label(p$cfg, rel[2], 1L, start = 4, speaker = "Anna")
  got <- ph_speaker_slots(p$cfg, sess)
  expect_equal(unname(got[["Anna"]]), 0L)
  expect_equal(sum(got > 0L), ph_speaker_slot_n)

  expect_equal(ph_speaker_slots(p$cfg, NULL), integer(0))
})

test_that("the voices are learned from a person's labels and never the model's", {
  # ph_speakers_apply() writes its own guesses into the same file it learns
  # from. Nothing but the `source` column stops the next pass training on them,
  # and a model taught by its own output drifts without ever saying so.
  p <- make_project()
  sess <- ph_path_new(p$cfg, title = "provenance")
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  dir <- ph_visit_dir(p$cfg, rel, create = TRUE)
  writeLines(c("start\tend\ttext", "0.000\t2.000\tone", "2.000\t4.000\ttwo",
               "4.000\t6.000\tthree"), file.path(dir, "visit-0001.tsv"))
  ph_write_sidecar(p$cfg, rel, 1L, list(session = basename(sess)))
  ph_path_append(sess, "show", rel_path = rel, visit = 1L)
  ph_path_append(sess, "leave", rel_path = rel, visit = 1L, duration = 6)
  ph_path_append(sess, "end")

  ph_speaker_label(p$cfg, rel, 1L, start = 0, speaker = "Beth")
  ph_speaker_label(p$cfg, rel, 1L, start = 2, speaker = "Marty")
  # A guess for a third voice nobody ever named.
  lab <- ph_speakers_read(p$cfg, rel, 1L)
  ph_speakers_write(p$cfg, rel, 1L, rbind(lab, data.frame(
    start = 4, end = 6, speaker = "Ghost", source = "auto", confidence = 0.01,
    stringsAsFactors = FALSE)))

  ph <- ph_speaker_phrases(p$cfg, sess)
  hand <- which(!is.na(ph$speaker) & ph$source == "manual")
  expect_equal(sort(ph$speaker[hand]), c("Beth", "Marty"))
  expect_false("Ghost" %in% ph$speaker[hand])

  # And through the profiles themselves: a voice with no hand-labelled example
  # has nothing to average, so it must not appear among them.
  feats <- list(c(1, 0), c(0, 1), c(1, 1))
  prof <- ph_speaker_fit_from(feats[hand], ph$speaker[hand])
  expect_equal(sort(colnames(prof)), c("Beth", "Marty"))
})
