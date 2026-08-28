# The path taken through the photographs, one session per directory:
#
#   sessions/2026-08-23-1930/session.yml
#   sessions/2026-08-23-1930/path.tsv
#
# path.tsv is appended a line at a time, so a crash or a killed R process loses
# only the visit in progress. Tab-separated rather than JSON so that reading it
# needs no parser and no dependency.

# No `audio` column: a visit's audio filename lives in its sidecar, so the two
# cannot disagree. The path row is written when the photograph is left, while
# the audio name is only final once the browser has flushed its last chunk.
# The name is derivable as sidecars/<rel_path>/visit-NNNN.webm.
ph_path_cols <- c("iso_time", "elapsed", "event", "rel_path", "visit",
                  "duration")

# Every event kind that may appear in the `event` column.
ph_path_events <- c("start", "show", "leave", "discard", "pause", "resume",
                    "end")

ph_now_iso <- function(t = Sys.time()) {
  format(as.POSIXct(t), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

#' Start a new session.
#'
#' Creates `sessions/<stamp>/` with a `session.yml` and a `path.tsv` carrying
#' its header row and a `start` event.
#'
#' @param config A work directory, a config path, or a config list.
#' @param title Title for this session; defaults to the project title.
#' @return The session directory, invisibly.
#' @examples
#' \dontrun{
#' ph_path_new("~/phostor/family")
#' }
#' @export
ph_path_new <- function(config = NULL, title = NULL) {
  cfg <- ph_as_config(config)
  now <- Sys.time()
  stamp <- format(now, "%Y-%m-%d-%H%M")
  dir <- file.path(cfg$sessions_dir, stamp)
  # Two sessions in the same minute would otherwise share a directory and
  # interleave their paths into one file.
  n <- 1L
  while (dir.exists(dir)) {
    n <- n + 1L
    dir <- file.path(cfg$sessions_dir, sprintf("%s-%d", stamp, n))
  }
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  writeLines(c(
    sprintf("# phostor %s -- a session.", ph_pkg_version()),
    yaml::as.yaml(list(session = basename(dir),
                       title = title %||% cfg$title,
                       started = ph_now_iso(now),
                       photo_root = cfg$photo_root))
  ), file.path(dir, "session.yml"), useBytes = TRUE)

  writeLines(paste(ph_path_cols, collapse = "\t"),
             file.path(dir, "path.tsv"), useBytes = TRUE)
  ph_path_append(dir, "start", started = now)
  invisible(dir)
}

#' Append one event to a session's path.
#'
#' @param session_dir A session directory from [ph_path_new()].
#' @param event One of `start`, `show`, `leave`, `discard`, `pause`, `resume`,
#'   `end`.
#' @param rel_path Photograph the event concerns, if any.
#' @param visit Visit number, if any.
#' @param duration Visit duration in seconds, if any.
#' @param started The session's start time, used only for the `start` row.
#' @param time Event time; defaults to now.
#' @return The row written, invisibly, as a character vector.
#' @examples
#' \dontrun{
#' ph_path_append(d, "show", rel_path = "a.jpg", visit = 1)
#' }
#' @export
ph_path_append <- function(session_dir, event, rel_path = NA, visit = NA,
                           duration = NA, started = NULL,
                           time = Sys.time()) {
  event <- match.arg(event, ph_path_events)
  f <- file.path(session_dir, "path.tsv")
  t0 <- if (!is.null(started)) as.numeric(started) else ph_path_start(session_dir)
  dash <- function(x, fmt = NULL) {
    if (length(x) != 1L || is.na(x) || !nzchar(as.character(x))) return("-")
    if (is.null(fmt)) as.character(x) else sprintf(fmt, x)
  }
  row <- c(ph_now_iso(time),
           sprintf("%.1f", max(0, as.numeric(time) - t0)),
           event,
           dash(rel_path),
           dash(visit),
           dash(duration, "%.1f"))
  cat(paste(row, collapse = "\t"), "\n", sep = "", file = f, append = TRUE)
  invisible(row)
}

# The session's start time, read back from its own first row so that elapsed
# times stay correct across an app restart.
ph_path_start <- function(session_dir) {
  p <- ph_path_read(session_dir)
  if (!nrow(p)) return(as.numeric(Sys.time()))
  as.numeric(as.POSIXct(p$iso_time[1], format = "%Y-%m-%dT%H:%M:%SZ",
                        tz = "UTC"))
}

#' Read a session's path.
#'
#' @param session_dir A session directory.
#' @return A data.frame with the columns of `path.tsv`; empty if there is none.
#' @examples
#' \dontrun{
#' ph_path_read(d)
#' }
#' @export
ph_path_read <- function(session_dir) {
  f <- file.path(session_dir, "path.tsv")
  empty <- as.data.frame(
    stats::setNames(rep(list(character(0)), length(ph_path_cols)),
                    ph_path_cols), stringsAsFactors = FALSE)
  if (!file.exists(f)) return(empty)
  x <- tryCatch(
    utils::read.table(f, sep = "\t", header = TRUE, quote = "",
                      comment.char = "", stringsAsFactors = FALSE,
                      colClasses = "character", encoding = "UTF-8",
                      na.strings = character(0)),
    error = function(e) empty)
  if (!nrow(x)) return(empty)
  for (k in ph_path_cols) if (is.null(x[[k]])) x[[k]] <- "-"
  x[ph_path_cols]
}

#' The sessions recorded in a project, newest first.
#'
#' @param config A work directory, a config path, or a config list.
#' @return A data.frame with `session`, `dir`, `title`, `started`, `visits`.
#' @examples
#' \dontrun{
#' ph_sessions("~/phostor/family")
#' }
#' @export
ph_sessions <- function(config = NULL) {
  cfg <- ph_as_config(config)
  empty <- data.frame(session = character(0), dir = character(0),
                      title = character(0), started = character(0),
                      visits = integer(0), stringsAsFactors = FALSE)
  if (!dir.exists(cfg$sessions_dir)) return(empty)
  dirs <- list.dirs(cfg$sessions_dir, recursive = FALSE, full.names = TRUE)
  dirs <- dirs[file.exists(file.path(dirs, "path.tsv"))]
  if (!length(dirs)) return(empty)
  rows <- lapply(dirs, function(d) {
    meta <- tryCatch(yaml::read_yaml(file.path(d, "session.yml")),
                     error = function(e) list())
    p <- ph_path_read(d)
    data.frame(session = basename(d), dir = d,
               title = as.character(meta$title %||% ""),
               started = as.character(meta$started %||% ""),
               visits = sum(p$event == "leave"),
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  out[order(out$session, decreasing = TRUE), , drop = FALSE]
}

#' The playlist for one session.
#'
#' Every completed visit, in the order it was recorded, with the audio each one
#' produced. This is what the Play button walks.
#'
#' @param cfg A config list from [ph_config()].
#' @param session_dir A session directory.
#' @return A data.frame with `rel_path`, `id`, `visit`, `duration` and `audio`
#'   (a path relative to `sidecar_dir`, or `NA`). Audio and duration are read
#'   from each visit's sidecar, which is where they are recorded.
#' @examples
#' \dontrun{
#' ph_playlist(ph_config(), d)
#' }
#' @export
ph_playlist <- function(cfg, session_dir) {
  p <- ph_path_read(session_dir)
  p <- p[p$event == "leave" & p$rel_path != "-", , drop = FALSE]
  idx <- ph_read_index(cfg)
  visit <- suppressWarnings(as.integer(p$visit))
  # The sidecar records what was captured. A visit too brief to write one was
  # still shown, so it is still included in the playlist.
  side <- lapply(seq_along(visit), function(i) {
    f <- file.path(cfg$sidecar_dir, p$rel_path[i],
                   sprintf("visit-%04d.yml", visit[i]))
    ph_read_sidecar(f)
  })
  audio <- vapply(seq_along(side), function(i) {
    a <- side[[i]]$audio
    if (is.null(a) || !nzchar(as.character(a))) NA_character_
    else file.path(p$rel_path[i], as.character(a))
  }, character(1))
  dur <- suppressWarnings(as.numeric(replace(p$duration, p$duration == "-", NA)))
  for (i in seq_along(side)) {
    d <- side[[i]]$duration
    if (!is.null(d) && !is.na(d)) dur[i] <- d
  }
  out <- data.frame(
    rel_path = p$rel_path,
    id = idx$id[match(p$rel_path, idx$rel_path)],
    visit = visit,
    duration = dur,
    audio = audio,
    stringsAsFactors = FALSE
  )
  # A photograph that has since been removed from photo_root has no rendered
  # copy to show, so it cannot be replayed; everything else still can.
  out[!is.na(out$id), , drop = FALSE]
}
