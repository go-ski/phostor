# Turning a visit's recording into text.
#
# macOS 26 ships SpeechAnalyzer, which transcribes on the machine: no network,
# no account, no per-minute cost. It is reached through a small Swift helper
# (inst/swift/transcribe.swift) compiled on first use, because R cannot call
# Swift directly and a compiled binary in the package would not survive being
# installed from source on another platform.
#
# The helper reads any container AVFoundation opens -- MP4, Ogg, M4A, WAV --
# and cannot read WebM, whatever codec is inside it. That is why the app
# records MP4 or Ogg and keeps WebM only as a last resort; see pickMime() in
# inst/shiny/app.R. A WebM visit still records and still plays, it just gets
# no transcript.
#
# The transcript is a sibling `visit-NNNN.txt`, not a field written back into
# `visit-NNNN.yml`. Writing the yml would mean rewriting a file that says in
# its own header that phostor never rewrites it, and would race the helper
# against the sidecar write. `transcript:` in the sidecar stays reserved.
#
# Beside it the helper writes `visit-NNNN.tsv`: one row per phrase, with the
# seconds of audio it spans. That is what lets the app light up the words as
# the recording reaches them. The .txt stays the canonical prose -- a .tsv can
# be missing (a transcript made before timings existed) and everything still
# reads, just without the highlight.
#
# A visit counts as transcribed only when both files are there. The helper
# always writes both, even for a recording with no speech in it, so the rule
# converges: nothing is re-run twice.

# Extensions worth handing to the helper. WebM is absent on purpose: it would
# always fail, and a visit should not cost a process launch to learn that.
ph_readable_audio <- c("mp4", "m4a", "ogg", "oga", "opus", "wav", "caf",
                       "aif", "aiff", "mp3")

# MediaRecorder reports the type it settled on; the container decides the
# extension. Anything unrecognised is treated as WebM, which is what every
# browser falls back to.
ph_mime_ext <- c("audio/mp4" = "mp4", "audio/ogg" = "ogg", "audio/webm" = "webm")

#' The file extension for a browser's recording MIME type.
#'
#' `audio/mp4;codecs=mp4a.40.2` and `audio/mp4` both give `mp4`. An
#' unrecognised or empty type gives `webm`.
#'
#' @param mime A MIME type as reported by `MediaRecorder`, with or without a
#'   `;codecs=` part.
#' @return A single lowercase extension, without the dot.
#' @examples
#' ph_audio_ext("audio/mp4;codecs=mp4a.40.2")
#' ph_audio_ext("audio/ogg;codecs=opus")
#' @export
ph_audio_ext <- function(mime) {
  m <- tolower(trimws(sub(";.*$", "", as.character(mime %||% "")[1])))
  ext <- unname(ph_mime_ext[m])
  if (is.na(ext)) "webm" else ext
}

#' Whether this machine could transcribe at all.
#'
#' Transcription needs macOS (for SpeechAnalyzer) and `swiftc` (to build the
#' helper). It does not check the macOS version: the helper reports that
#' itself, since mapping Darwin release numbers to macOS versions is a moving
#' target.
#'
#' @return `TRUE` or `FALSE`.
#' @examples
#' ph_transcribe_supported()
#' @export
ph_transcribe_supported <- function() {
  identical(Sys.info()[["sysname"]], "Darwin") && nzchar(Sys.which("swiftc"))
}

ph_transcribe_src <- function() {
  system.file("swift", "transcribe.swift", package = "phostor")
}

# The built helper, named for a hash of its source, so upgrading phostor
# rebuilds rather than silently running last version's binary.
ph_transcribe_bin <- function() {
  src <- ph_transcribe_src()
  if (!nzchar(src) || !file.exists(src)) return(NA_character_)
  h <- substr(unname(tools::md5sum(src)), 1, 8)
  file.path(tools::R_user_dir("phostor", "cache"),
            paste0("phostor-transcribe-", h))
}

#' Build the transcription helper.
#'
#' Compiles `inst/swift/transcribe.swift` into the user's cache directory. The
#' build is skipped when an up-to-date binary is already there, so this is
#' cheap to call on every start. An `Info.plist` is linked into the binary:
#' without one the process has no bundle identity and macOS cannot attribute a
#' speech-recognition request to it.
#'
#' @param quiet Suppress the compiler's own output on failure.
#' @return The path to the binary, or `NA_character_` if it could not be built.
#' @examples
#' \dontrun{
#' ph_transcribe_build()
#' }
#' @export
ph_transcribe_build <- function(quiet = FALSE) {
  if (!ph_transcribe_supported()) return(NA_character_)
  bin <- ph_transcribe_bin()
  if (is.na(bin)) return(NA_character_)
  if (file.exists(bin)) return(bin)

  src <- ph_transcribe_src()
  plist <- system.file("swift", "Info.plist", package = "phostor")
  if (!nzchar(plist) || !file.exists(plist)) return(NA_character_)
  dir.create(dirname(bin), recursive = TRUE, showWarnings = FALSE)

  # Built to a pid-tagged name and renamed, so two sessions starting at once
  # cannot hand each other a half-written binary.
  tmp <- paste0(bin, ".", Sys.getpid())
  on.exit(unlink(tmp), add = TRUE)
  out <- suppressWarnings(system2(
    "swiftc",
    c("-O", "-parse-as-library", "-o", shQuote(tmp), shQuote(src),
      "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
      "-Xlinker", "__info_plist", "-Xlinker", shQuote(plist)),
    stdout = TRUE, stderr = TRUE))
  if (!is.null(attr(out, "status")) && !identical(attr(out, "status"), 0L)) {
    if (!quiet) message("phostor: could not build the transcriber\n",
                        paste(out, collapse = "\n"))
    return(NA_character_)
  }
  if (!file.exists(tmp) || !file.rename(tmp, bin)) return(NA_character_)
  bin
}

# Every reason a visit might not be transcribed, in the order they are checked.
# Returned rather than raised: a sitting must not stop because a transcript
# could not be made.
ph_transcribe_why <- function(cfg, dir, visit, audio, force) {
  if (!isTRUE(cfg$transcribe)) return("off")
  if (is.null(audio) || is.na(audio) || !nzchar(audio)) return("no audio")
  ext <- tolower(tools::file_ext(audio))
  if (!ext %in% ph_readable_audio) return(paste0(ext, " cannot be read"))
  if (!file.exists(file.path(dir, audio))) return("audio missing")
  out <- file.path(dir, paste0(ph_visit_stem(visit), ".txt"))
  if (file.exists(paste0(out, ".part"))) return("already running")
  if (ph_has_transcript(dir, visit) && !isTRUE(force)) {
    return("already transcribed")
  }
  NA_character_
}

# Both files, not just the prose: a .txt on its own was written before timings
# existed and is re-run once, unforced, to gain them.
ph_has_transcript <- function(dir, visit) {
  stem <- file.path(dir, ph_visit_stem(visit))
  file.exists(paste0(stem, ".txt")) && file.exists(paste0(stem, ".tsv"))
}

#' Transcribe one visit's recording.
#'
#' Started in the background by default: R is single-threaded, and waiting for
#' a transcript would freeze the app while the next photograph is on screen.
#' The helper writes `visit-NNNN.txt` beside the audio when it finishes.
#'
#' Never raises. A visit that cannot be transcribed -- no audio, a WebM
#' recording, no helper on this machine -- returns the reason instead, so the
#' sitting carries on.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param audio The audio filename, as stored in the sidecar. Looked up from
#'   the visit directory when `NULL`.
#' @param wait Wait for the transcript and return when it is written.
#' @param force Transcribe even if a transcript already exists.
#' @return `"started"`, `"done"`, or the reason it was skipped, invisibly.
#' @examples
#' \dontrun{
#' ph_transcribe_visit(ph_config(), "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_transcribe_visit <- function(cfg, rel_path, visit, audio = NULL,
                                wait = FALSE, force = FALSE) {
  dir <- ph_visit_dir(cfg, rel_path)
  if (is.null(audio)) audio <- ph_visit_audio(dir, visit)

  why <- ph_transcribe_why(cfg, dir, visit, audio, force)
  if (!is.na(why)) return(invisible(why))

  bin <- ph_transcribe_bin()
  if (is.na(bin) || !file.exists(bin)) bin <- ph_transcribe_build(quiet = TRUE)
  if (is.na(bin)) return(invisible("no transcriber"))

  out <- file.path(dir, paste0(ph_visit_stem(visit), ".txt"))
  loc <- as.character(cfg$transcribe_locale %||% "")[1]
  args <- c(if (nzchar(loc)) c("--locale", shQuote(loc)),
            "--out", shQuote(out), shQuote(file.path(dir, audio)))

  if (!isTRUE(wait)) {
    # Fire and forget. Output is discarded rather than logged: ph_status()
    # reports which visits have no transcript, which is the question a user
    # actually asks, and ph_transcribe_all() gives the reason.
    suppressWarnings(system2(bin, args, wait = FALSE,
                             stdout = FALSE, stderr = FALSE))
    return(invisible("started"))
  }
  res <- suppressWarnings(system2(bin, args, stdout = TRUE, stderr = TRUE))
  status <- attr(res, "status") %||% 0L
  if (!identical(as.integer(status), 0L)) {
    return(invisible(if (length(res)) sub("^phostor-transcribe: ", "", res[1])
                     else "failed"))
  }
  invisible("done")
}

# The audio recorded for one visit, whatever container it ended up in.
ph_visit_audio <- function(dir, visit) {
  if (!dir.exists(dir)) return(NULL)
  stem <- ph_visit_stem(visit)
  f <- list.files(dir, pattern = paste0("^", stem, "\\."))
  f <- f[tolower(tools::file_ext(f)) %in% c(ph_readable_audio, "webm")]
  if (!length(f)) NULL else f[1]
}

#' Read one visit's transcript.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @return The transcript as a single string, or `NA_character_` if there is
#'   none. A recording with no speech in it gives `""`.
#' @examples
#' \dontrun{
#' ph_transcript("~/phostor/family", "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_transcript <- function(config, rel_path, visit) {
  cfg <- ph_as_config(config)
  path <- file.path(ph_visit_dir(cfg, rel_path),
                    paste0(ph_visit_stem(visit), ".txt"))
  if (!file.exists(path)) return(NA_character_)
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

#' Read one visit's transcript as timed phrases.
#'
#' The rows the app highlights from. A visit transcribed before timings existed
#' has no `.tsv`, and gives zero rows; [ph_transcript()] still reads its prose.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @return A data.frame of `start`, `end` (seconds, numeric) and `text`. Zero
#'   rows when there is no timed transcript, and when the recording held no
#'   speech.
#' @examples
#' \dontrun{
#' ph_transcript_timed("~/phostor/family", "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_transcript_timed <- function(config, rel_path, visit) {
  cfg <- ph_as_config(config)
  empty <- data.frame(start = numeric(0), end = numeric(0),
                      text = character(0), stringsAsFactors = FALSE)
  path <- file.path(ph_visit_dir(cfg, rel_path),
                    paste0(ph_visit_stem(visit), ".tsv"))
  if (!file.exists(path)) return(empty)
  # quote = "" and comment.char = "": an apostrophe or a # is ordinary speech,
  # and either would otherwise swallow the rest of the row.
  x <- tryCatch(
    utils::read.table(path, sep = "\t", header = TRUE, quote = "",
                      comment.char = "", stringsAsFactors = FALSE,
                      colClasses = "character", encoding = "UTF-8",
                      na.strings = character(0)),
    error = function(e) NULL)
  if (!is.data.frame(x) || !nrow(x) ||
      !all(c("start", "end", "text") %in% names(x))) {
    return(empty)
  }
  out <- data.frame(start = suppressWarnings(as.numeric(x$start)),
                    end = suppressWarnings(as.numeric(x$end)),
                    text = as.character(x$text),
                    stringsAsFactors = FALSE)
  # A row with no usable time cannot be highlighted, and one with no words has
  # nothing to show.
  out[!is.na(out$start) & !is.na(out$end) & nzchar(trimws(out$text)), ,
      drop = FALSE]
}

#' Is a visit still waiting for its transcript?
#'
#' What the app polls on, so a panel showing a just-finished visit picks the
#' text up when the helper writes it. False for anything that will never get
#' one: a WebM recording, a visit with no audio, and a recording old enough
#' that a transcriber which was going to answer would have answered by now.
#' Without that last clause a failed transcription would be waited on for as
#' long as its photograph was on screen.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param within Seconds since the recording was written to keep waiting for.
#' @return `TRUE` or `FALSE`.
#' @examples
#' \dontrun{
#' ph_visit_waiting("~/phostor/family", "Trips/Skye/img_0421.jpg", 1)
#' }
#' @export
ph_visit_waiting <- function(config, rel_path, visit, within = 120) {
  cfg <- ph_as_config(config)
  if (!isTRUE(cfg$transcribe)) return(FALSE)
  dir <- ph_visit_dir(cfg, rel_path)
  audio <- ph_visit_audio(dir, visit)
  if (is.null(audio)) return(FALSE)
  if (!tolower(tools::file_ext(audio)) %in% ph_readable_audio) return(FALSE)
  if (ph_has_transcript(dir, visit)) return(FALSE)
  age <- suppressWarnings(
    as.numeric(difftime(Sys.time(), file.mtime(file.path(dir, audio)),
                        units = "secs")))
  isTRUE(is.finite(age) && age < within)
}

#' Transcribe every recording that has no transcript yet.
#'
#' Runs one at a time and waits for each, so a backfill over a large collection
#' does not start hundreds of processes at once.
#'
#' @param config A work directory, a config path, or a config list.
#' @param force Re-transcribe recordings that already have a transcript.
#' @param quiet Suppress the per-visit report.
#' @return A data frame of `photo`, `visit` and `result`, invisibly.
#' @examples
#' \dontrun{
#' ph_transcribe_all("~/phostor/family")
#' }
#' @export
ph_transcribe_all <- function(config = NULL, force = FALSE, quiet = FALSE) {
  cfg <- ph_as_config(config)
  empty <- data.frame(photo = character(0), visit = integer(0),
                      result = character(0))
  if (!dir.exists(cfg$sidecar_dir)) return(invisible(empty))

  audio <- list.files(cfg$sidecar_dir, full.names = TRUE, recursive = TRUE,
                      pattern = "^visit-[0-9]+\\.[A-Za-z0-9]+$")
  audio <- audio[tolower(tools::file_ext(audio)) %in% c(ph_readable_audio, "webm")]
  if (!length(audio)) return(invisible(empty))

  dirs <- dirname(audio)
  rel <- substring(dirs, nchar(cfg$sidecar_dir) + 2L)
  visits <- as.integer(sub("^visit-0*([0-9]+)\\..*$", "\\1", basename(audio)))

  out <- vapply(seq_along(audio), function(i) {
    r <- ph_transcribe_visit(cfg, rel[i], visits[i], audio = basename(audio[i]),
                             wait = TRUE, force = force)
    if (!quiet) message(sprintf("%-4s %s visit %d", r, rel[i], visits[i]))
    r
  }, character(1))

  invisible(data.frame(photo = rel, visit = visits, result = out))
}

# Recordings with no transcript beside them, for ph_status(). Counts only what
# could be transcribed: a WebM recording is not waiting for anything.
ph_untranscribed <- function(cfg) {
  if (!dir.exists(cfg$sidecar_dir)) return(0L)
  audio <- list.files(cfg$sidecar_dir, recursive = TRUE, full.names = TRUE,
                      pattern = "^visit-[0-9]+\\.[A-Za-z0-9]+$")
  audio <- audio[tolower(tools::file_ext(audio)) %in% ph_readable_audio]
  if (!length(audio)) return(0L)
  stem <- sub("\\.[A-Za-z0-9]+$", "", audio)
  sum(!(file.exists(paste0(stem, ".txt")) & file.exists(paste0(stem, ".tsv"))))
}
