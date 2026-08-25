# Sidecars: what was recorded about one photograph, on one visit.
#
# The sidecar tree mirrors photo_root path for path. Each photograph gets a
# directory named after its file:
#
#   sidecars/Trips/Skye/img_0421.jpg/visit-0001.yml
#   sidecars/Trips/Skye/img_0421.jpg/visit-0001.webm
#
# A mirror rather than a flat store keyed by id, so that a photograph's record
# is findable from its path without phostor, and so all visits to one
# photograph sit in one directory. Ids key the rendered copies instead.
#
# Visit numbers are per photograph and are not reused: numbering takes the
# highest number present, so deleting visit 2 of 3 leaves the next visit as 4
# and no sidecar overwrites another.

# Fields written to every sidecar, in this order. `transcript` is reserved and
# always written as null in this version, so a later offline pass can fill it
# in without a format change and readers can rely on the key existing.
ph_sidecar_fields <- c("photo", "visit", "session", "started", "ended",
                       "duration", "audio", "bytes_expected", "people",
                       "place", "event", "when", "transcript")

#' The directory holding one photograph's visits.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param create Create the directory if it is missing.
#' @return The directory path.
#' @examples
#' \dontrun{
#' ph_visit_dir(ph_config(), "Trips/Skye/img_0421.jpg")
#' }
#' @export
ph_visit_dir <- function(cfg, rel_path, create = FALSE) {
  d <- file.path(cfg$sidecar_dir, rel_path)
  if (isTRUE(create)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

#' Every visit number already used in a photograph's sidecar directory.
#'
#' Counts every visit-numbered file, whatever its extension. Numbering must
#' include the audio: a `.webm`, or a `.part` from an interrupted visit, holds
#' its number even though no sidecar was written.
#'
#' @param dir A directory from [ph_visit_dir()].
#' @return A sorted integer vector.
#' @examples
#' ph_visit_numbers(tempdir())
#' @export
ph_visit_numbers <- function(dir) {
  if (!dir.exists(dir)) return(integer(0))
  f <- list.files(dir, pattern = "^visit-[0-9]+\\.")
  if (!length(f)) return(integer(0))
  n <- suppressWarnings(as.integer(sub("^visit-0*([0-9]+)\\..*$", "\\1", f)))
  sort(unique(n[!is.na(n)]))
}

#' The next visit number for a photograph.
#'
#' One more than the highest number already present, so a number is never
#' reused after a deletion.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @return A positive integer.
#' @examples
#' \dontrun{
#' ph_next_visit(ph_config(), "Trips/Skye/img_0421.jpg")
#' }
#' @export
ph_next_visit <- function(cfg, rel_path) {
  n <- ph_visit_numbers(ph_visit_dir(cfg, rel_path))
  if (!length(n)) 1L else max(n) + 1L
}

# visit-0007 -- zero-padded so a directory listing sorts in visit order.
ph_visit_stem <- function(visit) sprintf("visit-%04d", as.integer(visit))

#' Write one visit's sidecar.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param visit Visit number.
#' @param fields A named list of sidecar fields to record: any of `session`,
#'   `started`, `ended`, `duration`, `audio`, `bytes_expected`, `people`,
#'   `place`, `event`, `when`. Unknown names are ignored; `photo` and `visit`
#'   are set here.
#' @return The path written, invisibly.
#' @examples
#' \dontrun{
#' ph_write_sidecar(ph_config(), "a.jpg", 1, list(place = "Elgol"))
#' }
#' @export
ph_write_sidecar <- function(cfg, rel_path, visit, fields = list()) {
  dir <- ph_visit_dir(cfg, rel_path, create = TRUE)
  out <- file.path(dir, paste0(ph_visit_stem(visit), ".yml"))

  # Every field in the schema is written, empty ones as an explicit `~`, so
  # readers and hand-editors always see the same set of keys. Note the
  # single-bracket assignment: `body[[k]] <- NULL` would delete the key.
  body <- list()
  body[["photo"]] <- rel_path
  body[["visit"]] <- as.integer(visit)
  for (k in setdiff(ph_sidecar_fields, c("photo", "visit"))) {
    v <- fields[[k]]
    if (identical(k, "people")) {
      p <- trimws(as.character(v %||% character(0)))
      p <- p[!is.na(p) & nzchar(p)]
      body[[k]] <- as.list(p)          # list() -> `[]`, never a dropped key
      next
    }
    if (is.null(v) || (length(v) == 1L && is.na(v)) ||
        (is.character(v) && length(v) == 1L && !nzchar(v))) {
      body[k] <- list(NULL)
      next
    }
    body[[k]] <- if (identical(k, "duration")) round(as.numeric(v), 1) else v
  }
  body <- body[ph_sidecar_fields]

  writeLines(c(
    sprintf("# phostor %s -- visit %d of %s", ph_pkg_version(),
            as.integer(visit), rel_path),
    "# Safe to hand-edit; phostor only adds files, never rewrites them.",
    yaml::as.yaml(body)
  ), out, useBytes = TRUE)
  invisible(out)
}

#' Read one sidecar.
#'
#' @param path Path to a `visit-NNNN.yml`.
#' @return A named list, with `people` always a character vector and every
#'   field in the schema present.
#' @examples
#' \dontrun{
#' ph_read_sidecar("sidecars/a.jpg/visit-0001.yml")
#' }
#' @export
ph_read_sidecar <- function(path) {
  if (!file.exists(path)) return(NULL)
  x <- tryCatch(yaml::read_yaml(path), error = function(e) NULL)
  if (!is.list(x)) return(NULL)
  for (k in setdiff(ph_sidecar_fields, names(x))) x[k] <- list(NULL)
  x$people <- if (is.null(x$people)) character(0) else {
    as.character(unlist(x$people, use.names = FALSE))
  }
  x$visit <- suppressWarnings(as.integer(x$visit))
  x$duration <- suppressWarnings(as.numeric(x$duration %||% NA))
  x[ph_sidecar_fields]
}

#' Every recorded visit to one photograph, oldest first.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @return A list of sidecars, each with an extra `audio_path` giving the
#'   audio file's location on disk (`NA` when the visit has none).
#' @examples
#' \dontrun{
#' ph_visits_for(ph_config(), "Trips/Skye/img_0421.jpg")
#' }
#' @export
ph_visits_for <- function(cfg, rel_path) {
  dir <- ph_visit_dir(cfg, rel_path)
  if (!dir.exists(dir)) return(list())
  files <- sort(list.files(dir, pattern = "^visit-[0-9]+\\.yml$",
                           full.names = TRUE))
  out <- lapply(files, function(f) {
    s <- ph_read_sidecar(f)
    if (is.null(s)) return(NULL)
    a <- s$audio
    s$audio_path <- if (is.null(a) || !nzchar(as.character(a))) NA_character_
                    else file.path(dir, as.character(a))
    s
  })
  out[!vapply(out, is.null, logical(1))]
}

#' Every name used anywhere in this project, for autocomplete.
#'
#' Reads the `people` field of every `tags.yml` and every visit sidecar. Both,
#' because a name typed outside a sitting only ever reaches `tags.yml`, and a
#' name from before tags had their own file only ever reached a sidecar. At a
#' few hundred photographs this is fast enough to call whenever the app needs
#' it.
#'
#' @param config A work directory, a config path, or a config list.
#' @return A sorted character vector of unique names.
#' @examples
#' \dontrun{
#' ph_known_people("~/phostor/family")
#' }
#' @export
ph_known_people <- function(config = NULL) {
  cfg <- ph_as_config(config)
  if (!dir.exists(cfg$sidecar_dir)) return(character(0))
  files <- list.files(cfg$sidecar_dir, pattern = "^visit-[0-9]+\\.yml$",
                      recursive = TRUE, full.names = TRUE)
  nm <- unlist(lapply(files, function(f) ph_read_sidecar(f)$people),
               use.names = FALSE)

  tags <- list.files(cfg$sidecar_dir, pattern = "^tags\\.yml$",
                     recursive = TRUE, full.names = TRUE)
  nm <- c(nm, unlist(lapply(tags, function(f) {
    x <- tryCatch(yaml::read_yaml(f), error = function(e) NULL)
    if (is.list(x)) ph_tags_clean(x)$people else character(0)
  }), use.names = FALSE))

  nm <- trimws(as.character(nm))
  sort(unique(nm[nzchar(nm)]))
}

#' The most recent visit to a photograph, or `NULL`.
#'
#' Used to seed the tag fields, so a second visit starts from the previous
#' visit's values rather than blank.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @return A sidecar list, or `NULL`.
#' @examples
#' \dontrun{
#' ph_last_visit(ph_config(), "Trips/Skye/img_0421.jpg")
#' }
#' @export
ph_last_visit <- function(cfg, rel_path) {
  v <- ph_visits_for(cfg, rel_path)
  if (!length(v)) return(NULL)
  v[[length(v)]]
}
