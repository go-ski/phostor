# Corrections to a transcript, kept beside it rather than in it.
#
# The transcriber owns `visit-NNNN.tsv` and phostor never rewrites it. An edit
# made in place would be lost the next time `phostor transcribe --force` ran,
# and would break the rule that everything under sidecars/ is written once and
# afterwards only added to.
#
# So a correction is an overlay. `visit-NNNN-edits.tsv` holds, for each phrase
# that changed, the rows that replace it:
#
#   orig    start   end     text
#   4.350   4.350   7.090   and we drove up to Skye
#   4.350   7.090   11.200  no, it was Mull, wasn't it
#
# `orig` is the start of the transcriber's own phrase, so one phrase becomes
# two and both halves stay addressable afterwards. ph_transcript_timed()
# applies this on read, which is the single point that carries a split to the
# chips, to the playback highlight, and to the span of audio a voice is learned
# from -- the last of which is why splitting matters at all. Where the
# transcriber has run two voices into one phrase, that phrase is what
# ph_speaker_profile() averages, and the profile is of neither person.
#
# The name breaks the `visit-NNNN.` prefix for the same reason `-speakers.tsv`
# does: ph_visit_numbers(), ph_visit_counts(), ph_visits_for() and the
# transcriber's own scans all match `^visit-[0-9]+[.]`, and this file is caught
# by none of them.
#
# Re-transcribing moves the phrase boundaries, so `orig` stops matching and
# those rows are dropped rather than corrupting a fresh transcript. Speaker
# labels, keyed on the same times, already behave this way.

ph_edits_cols <- c("orig", "start", "end", "text")

# Times are written and read at three decimals, which is what the transcript
# and the label files use, so keying on them is exact rather than approximate.
ph_time_key <- function(x) sprintf("%.3f", round(as.numeric(x), 3))

ph_edits_path <- function(cfg, rel_path, visit) {
  file.path(ph_visit_dir(cfg, rel_path),
            paste0(ph_visit_stem(visit), "-edits.tsv"))
}

ph_edits_empty <- function() {
  data.frame(orig = numeric(0), start = numeric(0), end = numeric(0),
             text = character(0), stringsAsFactors = FALSE)
}

#' Read the corrections made to one visit's transcript.
#'
#' The overlay [ph_transcript_timed()] applies. Each group of rows sharing an
#' `orig` replaces the transcriber's phrase that started at that second, so a
#' phrase split in two shows as two rows with one `orig`.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @return A data.frame of `orig`, `start`, `end` and `text`. Zero rows when
#'   nothing has been corrected.
#' @examples
#' \dontrun{
#' ph_edits_read("~/phostor/family", "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_edits_read <- function(config, rel_path, visit) {
  cfg <- ph_as_config(config)
  path <- ph_edits_path(cfg, rel_path, visit)
  if (!file.exists(path)) return(ph_edits_empty())
  # quote = "" and comment.char = "": an apostrophe or a # is ordinary speech,
  # as in ph_transcript_timed().
  x <- tryCatch(
    utils::read.table(path, sep = "\t", header = TRUE, quote = "",
                      comment.char = "", stringsAsFactors = FALSE,
                      colClasses = "character", encoding = "UTF-8",
                      na.strings = character(0)),
    error = function(e) NULL)
  if (!is.data.frame(x) || !nrow(x) ||
      !all(ph_edits_cols %in% names(x))) return(ph_edits_empty())
  out <- data.frame(orig = suppressWarnings(as.numeric(x$orig)),
                    start = suppressWarnings(as.numeric(x$start)),
                    end = suppressWarnings(as.numeric(x$end)),
                    text = as.character(x$text),
                    stringsAsFactors = FALSE)
  out <- out[!is.na(out$orig) & !is.na(out$start) & !is.na(out$end) &
             nzchar(trimws(out$text)), , drop = FALSE]
  out[order(out$orig, out$start), , drop = FALSE]
}

ph_edits_write <- function(cfg, rel_path, visit, df) {
  path <- ph_edits_path(cfg, rel_path, visit)
  if (!nrow(df)) {
    if (file.exists(path)) unlink(path)
    return(invisible(NA_character_))
  }
  df <- df[order(df$orig, df$start), ph_edits_cols, drop = FALSE]
  # Tab-joined by hand, as the label file is: write.table() transliterates
  # non-ASCII under a C locale, and this file holds speech.
  clean <- function(v) gsub("[\t\r\n]", " ", as.character(v))
  lines <- c(paste(ph_edits_cols, collapse = "\t"),
             paste(sprintf("%.3f", df$orig), sprintf("%.3f", df$start),
                   sprintf("%.3f", df$end), clean(df$text), sep = "\t"))
  ph_visit_dir(cfg, rel_path, create = TRUE)
  writeLines(lines, path, useBytes = TRUE)
  invisible(path)
}

#' Apply a transcript's corrections to the transcriber's own phrases.
#'
#' Pure: the substitution rule on its own, so it can be reasoned about and
#' tested without a project on disk. A phrase whose start matches an `orig` is
#' replaced by that group's rows; every other phrase is kept as it is. Rows
#' whose `orig` matches no phrase are dropped, which is what makes a correction
#' harmless after the recording has been transcribed again to different
#' boundaries.
#'
#' @param timed Phrases as the transcriber wrote them: `start`, `end`, `text`.
#' @param edits An overlay from [ph_edits_read()].
#' @return A data.frame of `start`, `end` and `text`, ordered by `start`.
#' @examples
#' timed <- data.frame(start = 0, end = 4, text = "one two")
#' edits <- data.frame(orig = c(0, 0), start = c(0, 2), end = c(2, 4),
#'                     text = c("one", "two"))
#' ph_edits_apply(timed, edits)
#' @export
ph_edits_apply <- function(timed, edits) {
  if (!is.data.frame(timed) || !nrow(timed)) return(timed)
  if (!is.data.frame(edits) || !nrow(edits)) return(timed)
  keys <- ph_time_key(edits$orig)
  by <- split(seq_len(nrow(edits)), keys)
  out <- lapply(seq_len(nrow(timed)), function(i) {
    g <- by[[ph_time_key(timed$start[i])]]
    if (is.null(g)) return(timed[i, c("start", "end", "text"), drop = FALSE])
    e <- edits[g, , drop = FALSE]
    data.frame(start = e$start, end = e$end, text = e$text,
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, out)
  out[order(out$start), , drop = FALSE]
}

# Which of the transcriber's phrases a currently visible phrase came from, and
# the rows that phrase currently stands for. Splitting a phrase that was itself
# made by a split has to rewrite that original's whole group rather than add a
# second group under a start the transcriber never wrote.
ph_edits_group <- function(cfg, rel_path, visit, start) {
  raw <- ph_transcript_raw(cfg, rel_path, visit)
  edits <- ph_edits_read(cfg, rel_path, visit)
  key <- ph_time_key(start)
  # A phrase the transcriber wrote, and which nothing has replaced.
  i <- which(ph_time_key(raw$start) == key)
  if (length(i) && !key %in% ph_time_key(edits$orig)) {
    return(list(orig = raw$start[i[1]],
                rows = data.frame(start = raw$start[i[1]], end = raw$end[i[1]],
                                  text = raw$text[i[1]],
                                  stringsAsFactors = FALSE)))
  }
  j <- which(ph_time_key(edits$start) == key)
  if (!length(j)) return(NULL)
  orig <- edits$orig[j[1]]
  g <- edits[ph_time_key(edits$orig) == ph_time_key(orig), , drop = FALSE]
  list(orig = orig, rows = g[order(g$start), c("start", "end", "text"),
                             drop = FALSE])
}

# Replace one visible phrase with `rows`, and write the result.
ph_edits_replace <- function(cfg, rel_path, visit, start, rows) {
  g <- ph_edits_group(cfg, rel_path, visit, start)
  if (is.null(g)) {
    stop("phostor: no phrase starts at ", start, " in visit ", visit,
         " of ", rel_path, call. = FALSE)
  }
  keep <- g$rows[ph_time_key(g$rows$start) != ph_time_key(start), , drop = FALSE]
  new <- rbind(keep, rows)
  new <- new[order(new$start), , drop = FALSE]
  all <- ph_edits_read(cfg, rel_path, visit)
  all <- all[ph_time_key(all$orig) != ph_time_key(g$orig), , drop = FALSE]
  ph_edits_write(cfg, rel_path, visit, rbind(all, data.frame(
    orig = g$orig, start = new$start, end = new$end, text = new$text,
    stringsAsFactors = FALSE)))
}

#' Divide a phrase's words at a character offset, between words.
#'
#' The offset comes from where a pointer landed in the transcript, so it can
#' fall inside a word; splitting there would leave half a word on each side.
#' This backs up to the word boundary at or before it, which is also exactly
#' where a double-clicked word begins.
#'
#' @param text The phrase.
#' @param offset A character offset into it, from `0`.
#' @return A list of `before` and `after`, both trimmed. `after` is `""` when
#'   the offset leaves nothing on the right, which is what stops a split being
#'   proposed before the first word.
#' @examples
#' ph_phrase_cut("up to Skye no it was Mull", 11)
#' @export
ph_phrase_cut <- function(text, offset) {
  text <- as.character(text)
  n <- nchar(text)
  offset <- max(0L, min(as.integer(offset), n))
  if (offset <= 0L || offset >= n) return(list(before = trimws(text),
                                               after = ""))
  # The last space at or before the offset. A pointer inside the first word has
  # nothing to its left to divide at, so go forward to the end of that word
  # instead of dividing inside it.
  k <- regexpr("[[:space:]][^[:space:]]*$", substr(text, 1L, offset))
  cut <- if (k > 0L) k - 1L else {
    fwd <- regexpr("[[:space:]]", substring(text, offset + 1L))
    if (fwd > 0L) offset + fwd - 1L else n
  }
  list(before = trimws(substr(text, 1L, cut)),
       after = trimws(substring(text, cut + 1L)))
}

#' Split one phrase in two where the speaker changed mid-sentence.
#'
#' The transcriber hears one sentence where two people spoke, and a chip can
#' only sit between phrases -- so saying the voice changed part way through a
#' sentence means dividing the phrase. Both halves are then nameable, and each
#' holds one voice, which is what [ph_speakers_apply()] learns from.
#'
#' The first half keeps the phrase's start, so a name already given to it
#' survives; the second half is new and unnamed.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param start Start of the phrase to divide, in seconds.
#' @param at Where to divide it, in seconds. Must fall inside the phrase.
#' @param before Words of the first half.
#' @param after Words of the second half.
#' @return The path written, invisibly.
#' @examples
#' \dontrun{
#' ph_phrase_split(ph_config(), "a.jpg", 1, start = 4.35, at = 7.09,
#'                 before = "and we drove up to Skye",
#'                 after = "no, it was Mull")
#' }
#' @export
ph_phrase_split <- function(config, rel_path, visit, start, at, before, after) {
  cfg <- ph_as_config(config)
  timed <- ph_transcript_timed(cfg, rel_path, visit)
  i <- which(abs(timed$start - as.numeric(start)) < 0.01)
  if (!length(i)) {
    stop("phostor: no phrase starts at ", start, " in visit ", visit,
         " of ", rel_path, call. = FALSE)
  }
  s <- timed$start[i[1]]; e <- timed$end[i[1]]; at <- as.numeric(at)
  if (!is.finite(at) || at <= s || at >= e) {
    stop(sprintf("phostor: split at %s falls outside the phrase (%.3f to %.3f)",
                 at, s, e), call. = FALSE)
  }
  before <- trimws(as.character(before)); after <- trimws(as.character(after))
  if (!nzchar(before) || !nzchar(after)) {
    stop("phostor: a split needs words on both sides of it", call. = FALSE)
  }
  out <- ph_edits_replace(cfg, rel_path, visit, s, data.frame(
    start = c(s, at), end = c(at, e), text = c(before, after),
    stringsAsFactors = FALSE))
  # A name given to the phrase before it was divided still belongs to the first
  # half, but its recorded end is now the whole of what was said by two people.
  # Nothing reads that end today; leaving it wrong is how it starts being read.
  lab <- ph_speakers_read(cfg, rel_path, visit)
  k <- which(abs(lab$start - s) < 0.01)
  if (length(k)) {
    lab$end[k] <- at
    ph_speakers_write(cfg, rel_path, visit, lab)
  }
  out
}

#' Correct the words of one phrase.
#'
#' Fixes what the transcriber misheard, without touching its timing and without
#' rewriting the transcript itself. [ph_transcript()] and
#' [ph_transcript_timed()] both read the correction back.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param start Start of the phrase, in seconds.
#' @param text What was actually said.
#' @return The path written, invisibly.
#' @examples
#' \dontrun{
#' ph_phrase_text(ph_config(), "a.jpg", 1, start = 4.35, text = "up to Mull")
#' }
#' @export
ph_phrase_text <- function(config, rel_path, visit, start, text) {
  cfg <- ph_as_config(config)
  timed <- ph_transcript_timed(cfg, rel_path, visit)
  i <- which(abs(timed$start - as.numeric(start)) < 0.01)
  if (!length(i)) {
    stop("phostor: no phrase starts at ", start, " in visit ", visit,
         " of ", rel_path, call. = FALSE)
  }
  text <- trimws(as.character(text))
  if (!nzchar(text)) {
    stop("phostor: a phrase cannot be corrected to nothing", call. = FALSE)
  }
  ph_edits_replace(cfg, rel_path, visit, timed$start[i[1]], data.frame(
    start = timed$start[i[1]], end = timed$end[i[1]], text = text,
    stringsAsFactors = FALSE))
}
