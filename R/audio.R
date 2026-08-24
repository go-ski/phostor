# Audio assembly.
#
# The browser records with MediaRecorder and hands us the stream in chunks. We
# write each chunk to disk the moment it arrives, appending to a `.part` file,
# and rename to the final name only when the visit closes cleanly. Two things
# follow from that:
#
#   * a crash costs at most one chunk, not the evening; and
#   * a `.part` file left behind is unambiguously an interrupted visit, so no
#     sidecar ever claims audio that is not there.
#
# Chunks from a single MediaRecorder concatenate into a valid WebM, which is
# why this works without ffmpeg or any other muxing step. It is also why the
# app pins the recorder to one format and refuses to stitch chunks from a
# browser that cannot supply it -- see inst/shiny/app.R.

#' Open a visit's audio file.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param ext Container extension, without the dot.
#' @return The `.part` path to append to.
#' @examples
#' \dontrun{
#' ph_audio_open(ph_config(), "a.jpg", 1)
#' }
#' @export
ph_audio_open <- function(cfg, rel_path, visit, ext = "webm") {
  dir <- ph_visit_dir(cfg, rel_path, create = TRUE)
  part <- file.path(dir, paste0(ph_visit_stem(visit), ".", ext, ".part"))
  if (file.exists(part)) unlink(part)
  # Created empty, immediately, rather than on the first chunk. The file is
  # what reserves this visit number on disk: without it, leaving a photograph
  # and coming straight back -- before any audio has arrived -- would compute
  # the same number twice and the second visit would overwrite the first.
  file.create(part)
  part
}

#' Append one base64-encoded chunk to a visit's audio file.
#'
#' @param part A path from [ph_audio_open()].
#' @param b64 One chunk, base64-encoded, as sent by the browser.
#' @return The number of bytes appended, invisibly.
#' @examples
#' p <- file.path(tempdir(), "visit-0001.webm.part")
#' ph_audio_append(p, base64enc::base64encode(as.raw(1:10)))
#' file.size(p)
#' @export
ph_audio_append <- function(part, b64) {
  if (is.null(b64) || !length(b64) || !nzchar(b64[[1]])) return(invisible(0L))
  raw <- base64enc::base64decode(as.character(b64)[[1]])
  con <- file(part, open = "ab")
  on.exit(close(con), add = TRUE)
  writeBin(raw, con)
  invisible(length(raw))
}

#' Close a visit's audio file.
#'
#' Renames the `.part` file to its final name. An empty or absent `.part` --
#' the microphone was never armed, or the visit was too short to produce a
#' chunk -- yields `NA` and leaves no file behind, so the sidecar records no
#' audio rather than pointing at silence.
#'
#' @param part A path from [ph_audio_open()].
#' @return The final filename (basename only, as stored in the sidecar), or
#'   `NA_character_`.
#' @examples
#' \dontrun{
#' ph_audio_close(p)
#' }
#' @export
ph_audio_close <- function(part) {
  if (!file.exists(part)) return(NA_character_)
  if (file.size(part) == 0) {
    unlink(part)
    return(NA_character_)
  }
  final <- sub("\\.part$", "", part)
  if (!file.rename(part, final)) return(NA_character_)
  basename(final)
}

#' Discard a visit's audio.
#'
#' @param part A path from [ph_audio_open()].
#' @return `TRUE` if a file was removed.
#' @examples
#' \dontrun{
#' ph_audio_discard(p)
#' }
#' @export
ph_audio_discard <- function(part) {
  if (!file.exists(part)) return(FALSE)
  unlink(part)
  TRUE
}

#' Interrupted visits left behind in a project.
#'
#' A `.part` file is what an interrupted visit leaves: the audio up to the
#' moment the process stopped. They are playable, and phostor never deletes
#' them on its own.
#'
#' @param config A work directory, a config path, or a config list.
#' @return A character vector of paths.
#' @examples
#' \dontrun{
#' ph_orphan_audio("~/phostor/family")
#' }
#' @export
ph_orphan_audio <- function(config = NULL) {
  cfg <- ph_as_config(config)
  if (!dir.exists(cfg$sidecar_dir)) return(character(0))
  f <- list.files(cfg$sidecar_dir, pattern = "\\.part$", recursive = TRUE,
                  full.names = TRUE)
  # A zero-byte .part is a visit that opened and closed with nothing said, not
  # an interruption worth reporting.
  f[file.size(f) > 0]
}
