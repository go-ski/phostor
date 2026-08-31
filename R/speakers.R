# Who said which phrase.
#
# There is no speaker identification on macOS -- the Speech framework offers
# transcription and nothing else -- so this is built from MFCCs and a nearest
# profile, the classic recipe. Two measurements shaped it:
#
#   * Voices must be learned in the conditions they are identified in. The same
#     voices, enrolled clean and identified across a room, scored 2/8; enrolled
#     in the room, 8/8. So the examples come from the recordings themselves --
#     a few phrases labelled by hand -- and a set of voices reaches only within
#     the session it was learned from.
#   * Cepstral mean normalisation, the textbook defence against exactly that
#     mismatch, measured worse here (6/8 against 8/8). With seconds of audio the
#     speaker lives in the means it removes. So it is not used.
#
# Labels live in `visit-NNNN-speakers.tsv` beside the transcript, keyed on the
# phrase's start and end. The name breaks the `visit-NNNN.` prefix on purpose:
# ph_visit_numbers(), ph_visit_counts(), ph_visits_for() and the transcriber's
# scans all match `^visit-[0-9]+[.]`, and this file is caught by none of them.
# `visit-NNNN.tsv` is never rewritten; it belongs to the transcriber.

ph_speaker_cols <- c("start", "end", "speaker", "source", "confidence")

# A phrase shorter than this yields too few frames to say anything about a
# voice. Thirteen per cent of the phrases in a real session are under a second.
ph_speaker_min_secs <- 0.6
# How far the best match must beat the second before it is worth saying. Not a
# fixed number: on real voices the margins are tiny and depend on how many
# people are in the session and how alike they sound. Measured on one family's
# recordings, the margin was 0.0095 when the guess was right and 0.0011 when it
# was wrong -- it separates them well, but a threshold picked in advance names
# either everything or nothing. So it is calibrated per session from the
# phrases a person named, and this is only the floor of last resort, for a
# session with too few labels to calibrate from.
ph_speaker_min_margin <- 1e-4

ph_speakers_read_empty <- function() {
  data.frame(start = numeric(0), end = numeric(0), speaker = character(0),
             source = character(0), confidence = numeric(0),
             stringsAsFactors = FALSE)
}

ph_speakers_path <- function(cfg, rel_path, visit) {
  file.path(ph_visit_dir(cfg, rel_path),
            paste0(ph_visit_stem(visit), "-speakers.tsv"))
}

ph_need_tuneR <- function() {
  if (!requireNamespace("tuneR", quietly = TRUE)) {
    stop("phostor: naming speakers needs the tuneR package.\n",
         '  install.packages("tuneR")', call. = FALSE)
  }
}

#' The session a visit was recorded in.
#'
#' Every sidecar records it, and it is what ties a photograph to the others
#' discussed alongside it — same room, same microphone, same day. Voices are
#' learned within a session, so this is how both the app and the command line
#' know which recordings belong together.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @return The session directory, or `NULL` when the visit records no session
#'   or the session is gone.
#' @examples
#' \dontrun{
#' ph_visit_session("~/phostor/family", "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_visit_session <- function(config, rel_path, visit) {
  cfg <- ph_as_config(config)
  side <- ph_read_sidecar(file.path(ph_visit_dir(cfg, rel_path),
                                    paste0(ph_visit_stem(visit), ".yml")))
  name <- as.character(side$session %||% "")
  if (!length(name) || !nzchar(name)) return(NULL)
  dir <- file.path(cfg$sessions_dir, name)
  if (!dir.exists(dir)) return(NULL)
  dir
}

#' Every name used in a session.
#'
#' What the app offers when asking who spoke. Drawn from the whole session
#' rather than the photograph on screen: the same people are talking throughout,
#' and having to retype a name on each photograph is how this felt like a blank
#' slate.
#'
#' Reads only the small label files, never the audio.
#'
#' @param config A work directory, a config path, or a config list.
#' @param session_dir A session, from [ph_sessions()].
#' @return A sorted character vector of names, possibly empty.
#' @examples
#' \dontrun{
#' ph_speakers_names("~/phostor/family", ph_sessions()$dir[1])
#' }
#' @export
ph_speakers_names <- function(config, session_dir) {
  cfg <- ph_as_config(config)
  if (is.null(session_dir) || !dir.exists(session_dir)) return(character(0))
  pl <- ph_playlist(cfg, session_dir)
  if (!nrow(pl)) return(character(0))
  nm <- unlist(lapply(seq_len(nrow(pl)), function(i) {
    ph_speakers_read(cfg, pl$rel_path[i], pl$visit[i])$speaker
  }), use.names = FALSE)
  nm <- trimws(as.character(nm))
  sort(unique(nm[nzchar(nm)]))
}

#' Read the speaker labels for one visit.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @return A data.frame of `start`, `end`, `speaker`, `source` and
#'   `confidence`. Zero rows when nothing has been labelled.
#' @examples
#' \dontrun{
#' ph_speakers_read("~/phostor/family", "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_speakers_read <- function(config, rel_path, visit) {
  cfg <- ph_as_config(config)
  empty <- ph_speakers_read_empty()
  path <- ph_speakers_path(cfg, rel_path, visit)
  if (!file.exists(path)) return(empty)
  x <- tryCatch(
    utils::read.table(path, sep = "\t", header = TRUE, quote = "",
                      comment.char = "", stringsAsFactors = FALSE,
                      colClasses = "character", encoding = "UTF-8",
                      na.strings = character(0)),
    error = function(e) NULL)
  if (!is.data.frame(x) || !nrow(x) ||
      !all(ph_speaker_cols %in% names(x))) return(empty)
  out <- data.frame(start = suppressWarnings(as.numeric(x$start)),
                    end = suppressWarnings(as.numeric(x$end)),
                    speaker = as.character(x$speaker),
                    source = as.character(x$source),
                    confidence = suppressWarnings(as.numeric(x$confidence)),
                    stringsAsFactors = FALSE)
  out[!is.na(out$start) & !is.na(out$end) & nzchar(trimws(out$speaker)), ,
      drop = FALSE]
}

ph_speakers_write <- function(cfg, rel_path, visit, df) {
  path <- ph_speakers_path(cfg, rel_path, visit)
  if (!nrow(df)) {
    if (file.exists(path)) unlink(path)
    return(invisible(NA_character_))
  }
  df <- df[order(df$start), ph_speaker_cols, drop = FALSE]
  # Tab-joined by hand, as index.tsv is: write.table() transliterates non-ASCII
  # under a C locale and would rewrite the recorded names.
  clean <- function(v) gsub("[\t\r\n]", " ", as.character(v))
  lines <- c(paste(ph_speaker_cols, collapse = "\t"),
             paste(sprintf("%.3f", df$start), sprintf("%.3f", df$end),
                   clean(df$speaker), clean(df$source),
                   sprintf("%.3f", df$confidence), sep = "\t"))
  ph_visit_dir(cfg, rel_path, create = TRUE)
  writeLines(lines, path, useBytes = TRUE)
  invisible(path)
}

#' Say who spoke one phrase.
#'
#' A label written here is ground truth: it is what the voices are learned from,
#' and what [ph_speakers_check()] measures against. Setting a name over an
#' automatic label makes it manual, so a correction teaches as well as fixes.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param start Start of the phrase, in seconds, as in the transcript.
#' @param speaker The name. `""` removes the label.
#' @return The path written, invisibly.
#' @examples
#' \dontrun{
#' ph_speaker_label(ph_config(), "a.jpg", 1, start = 9.36, speaker = "Beth")
#' }
#' @export
ph_speaker_label <- function(config, rel_path, visit, start, speaker) {
  cfg <- ph_as_config(config)
  timed <- ph_transcript_timed(cfg, rel_path, visit)
  i <- which(abs(timed$start - as.numeric(start)) < 0.01)
  if (!length(i)) {
    stop("phostor: no phrase starts at ", start, " in visit ", visit,
         " of ", rel_path, call. = FALSE)
  }
  df <- ph_speakers_read(cfg, rel_path, visit)
  df <- df[abs(df$start - timed$start[i[1]]) >= 0.01, , drop = FALSE]
  if (nzchar(trimws(speaker))) {
    df <- rbind(df, data.frame(
      start = timed$start[i[1]], end = timed$end[i[1]],
      speaker = trimws(speaker), source = "manual", confidence = 1,
      stringsAsFactors = FALSE))
  }
  ph_speakers_write(cfg, rel_path, visit, df)
}

# How many phrases carry a name, and how many of those a person gave. For
# ph_status(); reads only the transcripts and the label files.
ph_named_counts <- function(cfg) {
  if (!dir.exists(cfg$sidecar_dir)) {
    return(list(total = 0L, named = 0L, manual = 0L))
  }
  # Relative, so the photograph and visit a transcript belongs to can be read
  # back off its path: a correction can divide one phrase into two, so the
  # count has to come from the phrases as read rather than the lines on disk.
  tsv <- list.files(cfg$sidecar_dir, pattern = "^visit-[0-9]+[.]tsv$",
                    recursive = TRUE)
  total <- sum(vapply(tsv, function(f) {
    nrow(ph_transcript_timed(cfg, dirname(f),
                             as.integer(sub("^visit-0*([0-9]+)[.]tsv$", "\\1",
                                            basename(f)))))
  }, integer(1)))
  spk <- list.files(cfg$sidecar_dir, pattern = "^visit-[0-9]+-speakers[.]tsv$",
                    recursive = TRUE, full.names = TRUE)
  rows <- lapply(spk, function(f) {
    x <- tryCatch(utils::read.table(f, sep = "\t", header = TRUE, quote = "",
                                    comment.char = "", colClasses = "character"),
                  error = function(e) NULL)
    if (is.data.frame(x) && "source" %in% names(x)) x$source else character(0)
  })
  src <- unlist(rows, use.names = FALSE)
  list(total = as.integer(total), named = length(src),
       manual = sum(src == "manual"))
}

# How many voices get a colour of their own. Four, because that is as many as
# the palette can hold and still keep every pair of chips apart on this
# background -- see the note beside --ph-s1 in the app's stylesheet. Past the
# fourth a voice keeps its name and loses its hue, which is a scanning aid
# rather than the way anyone is identified.
ph_speaker_slot_n <- 4L

#' Which phrases open a run, and which merely continue one.
#'
#' A chip under every phrase prints a name once per sentence, which buries the
#' one thing worth seeing: where the voice changed. So a chip is shown only
#' where a run begins, and a run is a maximal stretch of consecutive phrases
#' naming one person.
#'
#' Runs break on the name alone. A hand-given name followed by the same name
#' guessed is still one person talking, and a chip there would say the speaker
#' changed when nobody did. What the change in provenance does affect is
#' `all_manual`, which is `TRUE` only when every phrase in the run was named by
#' a person -- so a chip drawn as ground truth never covers a guess.
#'
#' An unnamed phrase is a run of its own, so it always keeps a chip and stays
#' nameable.
#'
#' Pure, and takes the two frames rather than a project, so the rule can be
#' tested on its own.
#'
#' @param timed Phrases, from [ph_transcript_timed()].
#' @param labels Speaker labels, from [ph_speakers_read()].
#' @return A data.frame with one row per phrase: `speaker` (`""` when unnamed),
#'   `source`, `run` (an integer id), `lead` (does this phrase open its run) and
#'   `all_manual`.
#' @examples
#' timed <- data.frame(start = c(0, 2, 4), end = c(2, 4, 6),
#'                     text = c("a", "b", "c"))
#' labels <- data.frame(start = c(0, 2), end = c(2, 4),
#'                      speaker = c("Beth", "Beth"),
#'                      source = c("manual", "auto"), confidence = c(1, 0.5))
#' ph_speaker_runs(timed, labels)
#' @export
ph_speaker_runs <- function(timed, labels) {
  empty <- data.frame(speaker = character(0), source = character(0),
                      run = integer(0), lead = logical(0),
                      all_manual = logical(0), stringsAsFactors = FALSE)
  n <- if (is.data.frame(timed)) nrow(timed) else 0L
  if (!n) return(empty)
  if (!is.data.frame(labels)) labels <- ph_speakers_read_empty()
  j <- match(ph_time_key(timed$start), ph_time_key(labels$start))
  speaker <- trimws(ifelse(is.na(j), "", as.character(labels$speaker[j])))
  source <- ifelse(is.na(j), "", as.character(labels$source[j]))
  # An unnamed phrase never continues anything, so nzchar() is what keeps a
  # stretch of "+" chips from collapsing into one.
  same <- c(FALSE, speaker[-1] == speaker[-n] & nzchar(speaker[-1]))
  run <- cumsum(!same)
  manual <- source == "manual"
  by_run <- vapply(split(manual, run), all, logical(1))
  data.frame(speaker = speaker, source = source, run = run, lead = !same,
             all_manual = unname(by_run[as.character(run)]),
             stringsAsFactors = FALSE)
}

#' A colour slot for each voice in a session.
#'
#' Chips carry a hue so that turn-taking can be read at a glance. Slots are
#' handed out in the order the voices are first heard in the session, and never
#' cycled: a fifth voice keeps its name and gets no hue, rather than borrowing
#' the first voice's colour and putting two people in one colour.
#'
#' Ordering by first appearance means a voice named later, whose first phrase
#' falls early in the session, takes its place ahead of voices already coloured
#' and shifts them along. That is rare, it settles once the voices are known,
#' and it is the price of never letting two people collide on one colour.
#'
#' A session, not a project: voices are learned within one anyway
#' ([ph_speakers_apply()]), and a colour that meant one person on Tuesday and
#' another on Friday would be worse than none.
#'
#' @param config A work directory, a config path, or a config list.
#' @param session_dir A session, from [ph_sessions()].
#' @return A named integer vector of slot numbers, `1` upwards, `0` for a voice
#'   past the last slot. Empty when nothing in the session is named.
#' @examples
#' \dontrun{
#' ph_speaker_slots("~/phostor/family", ph_sessions()$dir[1])
#' }
#' @export
ph_speaker_slots <- function(config, session_dir) {
  cfg <- ph_as_config(config)
  if (is.null(session_dir) || !dir.exists(session_dir)) return(integer(0))
  pl <- ph_playlist(cfg, session_dir)
  if (!nrow(pl)) return(integer(0))
  # The label files are written sorted by start and read back that way, so the
  # order a voice is first heard in needs nothing but the labels themselves --
  # no transcript, and no audio. This runs on every render of the panel.
  heard <- unlist(lapply(seq_len(nrow(pl)), function(i) {
    nm <- trimws(ph_speakers_read(cfg, pl$rel_path[i], pl$visit[i])$speaker)
    nm[nzchar(nm)]
  }), use.names = FALSE)
  nm <- unique(as.character(heard))
  if (!length(nm)) return(integer(0))
  stats::setNames(as.integer(ifelse(seq_along(nm) <= ph_speaker_slot_n,
                                    seq_along(nm), 0L)), nm)
}

# --------------------------------------------------------------------------
# hearing the voices
# --------------------------------------------------------------------------

# Decoded recordings, for as long as this R session lasts. Naming spreads on
# every label now, so the same session is worked over again and again: without
# this each run decoded every recording three times -- twice in apply(), once
# more in the check it calls.
#
# Keyed on the recording's path and modification time, so a re-recorded visit
# is decoded afresh rather than answered from a stale file.
ph_wav_cache <- new.env(parent = emptyenv())

# The recording decoded to 16 kHz mono WAV. The Swift helper does it: it
# already knows how to open a fragmented MP4, and nothing else here should
# have to.
ph_speaker_wav <- function(cfg, rel_path, visit, cache = ph_wav_cache) {
  dir <- ph_visit_dir(cfg, rel_path)
  audio <- ph_visit_audio(dir, visit)
  if (is.null(audio)) return(NULL)
  key <- paste(file.path(dir, audio),
               as.numeric(file.mtime(file.path(dir, audio))))
  hit <- cache[[key]]
  if (!is.null(hit) && file.exists(hit)) return(hit)
  bin <- ph_transcribe_bin()
  if (is.na(bin) || !file.exists(bin)) bin <- ph_transcribe_build(quiet = TRUE)
  if (is.na(bin)) return(NULL)
  wav <- tempfile(fileext = ".wav")
  ok <- suppressWarnings(system2(
    bin, c("--pcm", "--out", shQuote(wav), shQuote(file.path(dir, audio))),
    stdout = FALSE, stderr = FALSE))
  if (!identical(as.integer(ok), 0L) || !file.exists(wav)) return(NULL)
  assign(key, wav, envir = cache)
  wav
}

# A voice as a fixed-length profile: the mean and spread of each cepstral
# coefficient over the frames that carry energy. The quietest third is dropped
# as room rather than voice.
ph_speaker_profile <- function(wav, start, end) {
  ph_need_tuneR()
  w <- tryCatch(tuneR::readWave(wav, from = start, to = end, units = "seconds"),
                error = function(e) NULL)
  if (is.null(w) || length(w@left) < w@samp.rate * ph_speaker_min_secs) return(NULL)
  m <- tryCatch(tuneR::melfcc(w, numcep = 20, wintime = 0.025, hoptime = 0.010),
                error = function(e) NULL)
  if (is.null(m)) return(NULL)
  m <- m[stats::complete.cases(m), , drop = FALSE]
  if (nrow(m) < 5) return(NULL)
  m <- m[m[, 1] > stats::quantile(m[, 1], 0.35), , drop = FALSE]
  if (nrow(m) < 3) return(NULL)
  c(colMeans(m), apply(m, 2, stats::sd))
}

ph_cosine <- function(a, b) {
  d <- sqrt(sum(a^2) * sum(b^2))
  if (!is.finite(d) || d == 0) return(-Inf)
  sum(a * b) / d
}

# Every phrase of every visit in a session, with whatever label it carries.
ph_speaker_phrases <- function(cfg, session_dir) {
  pl <- ph_playlist(cfg, session_dir)
  if (!nrow(pl)) return(NULL)
  out <- lapply(seq_len(nrow(pl)), function(i) {
    timed <- ph_transcript_timed(cfg, pl$rel_path[i], pl$visit[i])
    if (!nrow(timed)) return(NULL)
    lab <- ph_speakers_read(cfg, pl$rel_path[i], pl$visit[i])
    j <- match(round(timed$start, 2), round(lab$start, 2))
    data.frame(rel_path = pl$rel_path[i], visit = pl$visit[i],
               start = timed$start, end = timed$end, text = timed$text,
               speaker = ifelse(is.na(j), NA_character_, lab$speaker[j]),
               source = ifelse(is.na(j), NA_character_, lab$source[j]),
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, out[!vapply(out, is.null, logical(1))])
  out
}

# Profiles for every phrase, decoding each recording once.
ph_speaker_features <- function(cfg, ph) {
  lapply(seq_len(nrow(ph)), function(i) {
    wav <- ph_speaker_wav(cfg, ph$rel_path[i], ph$visit[i])
    if (is.null(wav)) return(NULL)
    ph_speaker_profile(wav, ph$start[i], ph$end[i])
  })
}

# Average the examples of each voice into one profile.
ph_speaker_fit_from <- function(feats, names_) {
  ok <- !vapply(feats, is.null, logical(1)) & !is.na(names_)
  if (!any(ok)) return(NULL)
  by <- split(which(ok), names_[ok])
  vapply(by, function(idx) colMeans(do.call(rbind, feats[idx])),
         numeric(length(feats[[which(ok)[1]]])))
}

# Nearest profile, and how far it beat the next.
ph_speaker_nearest <- function(f, prof) {
  if (is.null(f) || is.null(prof) || ncol(prof) < 1) return(NULL)
  sim <- apply(prof, 2, ph_cosine, b = f)
  o <- order(sim, decreasing = TRUE)
  margin <- if (length(sim) > 1) sim[o[1]] - sim[o[2]] else 1
  list(speaker = colnames(prof)[o[1]], margin = margin)
}

# --------------------------------------------------------------------------
# what it can and cannot do, said out loud
# --------------------------------------------------------------------------

#' How often the naming would be right, on your own voices.
#'
#' Leaves out each hand-labelled phrase in turn, learns the voices without it,
#' and predicts it. The labels are ground truth, so this is a real figure for
#' these people in this room -- not a claim carried over from somewhere else.
#'
#' Run it before trusting [ph_speakers_apply()]. A feature that cannot say how
#' often it is wrong has no business naming a family's recordings.
#'
#' @param config A work directory, a config path, or a config list.
#' @param session_dir A session, from [ph_sessions()]. Voices are learned within
#'   one session: the same room, microphone and day, which is what makes the
#'   examples comparable to the speech they are matched against.
#' @param quiet Suppress the report.
#' @return Invisibly, a list of `n`, `correct`, `accuracy`, `confusion` and
#'   `labels` (examples per voice).
#' @examples
#' \dontrun{
#' ph_speakers_check("~/phostor/family", ph_sessions()$dir[1])
#' }
#' @export
ph_speakers_check <- function(config, session_dir, quiet = FALSE) {
  cfg <- ph_as_config(config)
  ph_need_tuneR()
  ph <- ph_speaker_phrases(cfg, session_dir)
  if (is.null(ph)) return(invisible(NULL))
  hand <- which(!is.na(ph$speaker) & ph$source == "manual")
  if (length(hand) < 2) {
    if (!quiet) message("phostor: label a few phrases first -- at least two, ",
                        "and four or five per person works better")
    return(invisible(NULL))
  }
  feats <- ph_speaker_features(cfg, ph[hand, , drop = FALSE])
  truth <- ph$speaker[hand]
  usable <- !vapply(feats, is.null, logical(1))
  guess <- rep(NA_character_, length(hand))
  margin <- rep(NA_real_, length(hand))
  for (i in which(usable)) {
    # Without this example: predicting a phrase from itself proves nothing.
    prof <- ph_speaker_fit_from(feats[-i], truth[-i])
    if (is.null(prof)) next
    near <- ph_speaker_nearest(feats[[i]], prof)
    if (!is.null(near)) { guess[i] <- near$speaker; margin[i] <- near$margin }
  }
  ok <- !is.na(guess)
  acc <- if (any(ok)) mean(guess[ok] == truth[ok]) else NA_real_
  # The bar for naming anything else: how decisive this had to be to be right
  # here. A low quantile rather than the middle, so it does not throw away most
  # of what it could name.
  right <- ok & guess == truth & is.finite(margin)
  res <- list(n = sum(ok), correct = sum(guess[ok] == truth[ok]),
              accuracy = acc,
              margin_ok = if (sum(right) >= 3)
                unname(stats::quantile(margin[right], 0.25)) else NA_real_,
              confusion = if (any(ok)) table(labelled = truth[ok],
                                             guessed = guess[ok]) else NULL,
              labels = table(truth))
  # Leaving out the only example a voice has leaves nothing to recognise it by,
  # so the score is meaningless rather than bad. Say which it is: labelling one
  # phrase per person and being told it gets nothing right is alarming and
  # wrong.
  res$thin <- any(res$labels < 2)
  if (!quiet) {
    if (res$thin) {
      message(sprintf("phostor: %d of %d, but too few examples to judge by",
                      res$correct, res$n))
      message("  every voice needs at least two named phrases before this ",
              "figure means anything")
    } else {
      message(sprintf("phostor: %d of %d labelled phrases named correctly (%.0f%%)",
                      res$correct, res$n, 100 * acc))
    }
    message("  examples per voice: ",
            paste(sprintf("%s %d", names(res$labels), as.integer(res$labels)),
                  collapse = ", "))
    if (!res$thin && is.finite(acc) && acc < 0.8) {
      message("  that is not good enough to name the rest unattended. ",
              "Label more phrases, especially for the voices it confuses.")
    }
    if (sum(!usable)) {
      message(sprintf("  %d labelled phrase(s) too short to hear a voice in",
                      sum(!usable)))
    }
  }
  invisible(res)
}

#' Name the phrases nobody has labelled.
#'
#' Learns the voices from the hand-labelled phrases in this session and names
#' the rest. Refuses two kinds of phrase rather than guessing: those too short
#' to carry a voice, and those where the best match barely beats the second.
#'
#' Hand labels are never overwritten.
#'
#' @param config A work directory, a config path, or a config list.
#' @param session_dir A session, from [ph_sessions()].
#' @param quiet Suppress the report.
#' @return Invisibly, a data.frame of what was named, with the margin behind
#'   each decision.
#' @examples
#' \dontrun{
#' ph_speakers_apply("~/phostor/family", ph_sessions()$dir[1])
#' }
#' @export
ph_speakers_apply <- function(config, session_dir, quiet = FALSE) {
  cfg <- ph_as_config(config)
  ph_need_tuneR()
  ph <- ph_speaker_phrases(cfg, session_dir)
  if (is.null(ph)) return(invisible(NULL))
  hand <- which(!is.na(ph$speaker) & ph$source == "manual")
  if (length(hand) < 2) {
    if (!quiet) message("phostor: nothing to learn from -- label a few ",
                        "phrases first")
    return(invisible(NULL))
  }
  # Always run: its margin_ok is the bar for naming anything, not just a report.
  chk <- ph_speakers_check(cfg, session_dir, quiet = quiet)
  floor <- if (!is.null(chk) && is.finite(chk$margin_ok)) chk$margin_ok
           else ph_speaker_min_margin

  prof <- ph_speaker_fit_from(ph_speaker_features(cfg, ph[hand, , drop = FALSE]),
                              ph$speaker[hand])
  if (is.null(prof)) return(invisible(NULL))

  want <- setdiff(seq_len(nrow(ph)), hand)
  feats <- ph_speaker_features(cfg, ph[want, , drop = FALSE])
  named <- 0L; skipped <- 0L
  out <- vector("list", length(want))
  for (k in seq_along(want)) {
    near <- ph_speaker_nearest(feats[[k]], prof)
    if (is.null(near) || near$margin < floor) {
      skipped <- skipped + 1L
      next
    }
    i <- want[k]
    out[[k]] <- data.frame(rel_path = ph$rel_path[i], visit = ph$visit[i],
                           start = ph$start[i], end = ph$end[i],
                           speaker = near$speaker, confidence = near$margin,
                           stringsAsFactors = FALSE)
    named <- named + 1L
  }
  out <- do.call(rbind, out[!vapply(out, is.null, logical(1))])

  # One write per visit, keeping the hand labels that are already there.
  if (!is.null(out)) {
    for (key in unique(paste(out$rel_path, out$visit))) {
      rows <- out[paste(out$rel_path, out$visit) == key, , drop = FALSE]
      rel <- rows$rel_path[1]; v <- rows$visit[1]
      keep <- ph_speakers_read(cfg, rel, v)
      keep <- keep[keep$source == "manual", , drop = FALSE]
      add <- data.frame(start = rows$start, end = rows$end,
                        speaker = rows$speaker, source = "auto",
                        confidence = rows$confidence, stringsAsFactors = FALSE)
      add <- add[!round(add$start, 2) %in% round(keep$start, 2), , drop = FALSE]
      ph_speakers_write(cfg, rel, v, rbind(keep, add))
    }
  }
  if (!quiet) {
    message(sprintf("phostor: named %d phrase(s), left %d unnamed as too ",
                    named, skipped), "short or too close to call")
  }
  invisible(out)
}
