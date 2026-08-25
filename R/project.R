# R/project.R -- work directory as the project handle.
#
#   <work_dir>/config.yml            live, user-edited (the only file to edit)
#   <work_dir>/config.resolved.yml   snapshot written by every command
#   <work_dir>/config.history/       timestamped copies of prior config.yml
#   <work_dir>/index.tsv             the catalogue
#   <work_dir>/display/  thumbs/     pre-rendered copies, keyed by photo id
#   <work_dir>/sessions/<stamp>/     session.yml + path.tsv, one per sitting
#   <work_dir>/sidecars/<rel_path>/  a directory per photo, holding its visits
#
# `work_dir` is not a field in config.yml: it is where config.yml is. One
# directory per read-only photo directory, so a second collection is a second
# directory rather than a second set of paths to keep in step.
#
# `photo_root` is read-only: phostor never writes under it, and never changes
# an mtime there. The path helpers below are what enforce that.

`%||%` <- function(a, b) if (is.null(a)) b else a
na_if_empty <- function(x) if (length(x) && nzchar(x)) x else NULL

# packageVersion() errors when R/ has been source()d rather than installed
# (tests/testthat/setup.R), so provenance must not depend on it.
ph_pkg_version <- function() {
  tryCatch(as.character(utils::packageVersion("phostor")),
           error = function(e) "source")
}

# Derived, non-user-settable fields. Named here so the resolved snapshot can be
# re-read without every one of them tripping the unknown-key warning.
ph_derived_keys <- c("index_file", "display_dir", "thumb_dir", "sessions_dir",
                     "sidecar_dir", "config_file")

# ---------------------------------------------------------------------------
# path utilities
# ---------------------------------------------------------------------------

# normalizePath() that resolves symlinks in whatever prefix already exists
# without creating anything: config loading must not mutate the filesystem.
ph_resolve_path <- function(p) {
  if (is.null(p) || !length(p) || !nzchar(p)) return(p)
  p <- path.expand(p)
  if (!grepl("^(/|[A-Za-z]:)", p)) p <- file.path(getwd(), p)
  tail <- character(0)
  cur <- p
  while (!file.exists(cur)) {
    parent <- dirname(cur)
    if (identical(parent, cur)) break
    tail <- c(basename(cur), tail)
    cur <- parent
  }
  cur <- normalizePath(cur, mustWork = FALSE)
  if (length(tail)) cur <- do.call(file.path, c(list(cur), as.list(tail)))
  sub("(?<=.)/+$", "", cur, perl = TRUE)
}

# Case-insensitive filesystems (APFS/HFS+ on macOS, SMB mounts) defeat a plain
# prefix test: /Volumes/Photo and /Volumes/photo are one directory. Probe the
# filesystem the paths live on (tempdir() is often a different one) and cache
# per directory, since ph_config() is called on every command.
ph_case_cache <- new.env(parent = emptyenv())

ph_flip_case <- function(x) {
  chartr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
         "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", x)
}

# Runs on photo_root, whose mtime must not change, so it must not probe by
# writing a test file. Instead it takes an existing entry whose name changes
# under a case flip and checks whether the flipped name still resolves.
ph_fs_case_insensitive <- function(path = tempdir()) {
  dir <- path
  while (!dir.exists(dir) && dirname(dir) != dir) dir <- dirname(dir)
  key <- dir
  hit <- ph_case_cache[[key]]
  if (!is.null(hit)) return(hit)

  entries <- tryCatch(list.files(dir, all.files = TRUE, no.. = TRUE),
                      error = function(e) character(0))
  flipped <- ph_flip_case(entries)
  cased <- flipped != entries
  res <- if (any(cased & flipped %in% entries)) {
    # Two entries differing only in case coexist: definitively case-sensitive.
    FALSE
  } else if (any(cased)) {
    file.exists(file.path(dir, flipped[cased][[1]]))
  } else {
    # Empty directory, or no entry carries a letter: fall back to the platform
    # default (APFS/HFS+ are case-insensitive unless formatted otherwise).
    identical(Sys.info()[["sysname"]], "Darwin")
  }
  assign(key, res, envir = ph_case_cache)
  res
}

# Does either path contain the other? This is the work_dir vs photo_root test.
# The case folding is what makes it correct on APFS.
ph_paths_overlap <- function(a, b) {
  if (is.null(a) || is.null(b) || !length(a) || !length(b) ||
      !nzchar(a) || !nzchar(b)) return(FALSE)
  if (ph_fs_case_insensitive(a) || ph_fs_case_insensitive(b)) {
    a <- tolower(a); b <- tolower(b)
  }
  identical(a, b) ||
    startsWith(paste0(a, "/"), paste0(b, "/")) ||
    startsWith(paste0(b, "/"), paste0(a, "/"))
}

# The directional half of the same question: is `child` at or below `parent`?
ph_path_under <- function(child, parent) {
  if (is.null(child) || is.null(parent) || !length(child) || !length(parent) ||
      !nzchar(child) || !nzchar(parent)) return(FALSE)
  if (ph_fs_case_insensitive(child) || ph_fs_case_insensitive(parent)) {
    child <- tolower(child); parent <- tolower(parent)
  }
  identical(child, parent) ||
    startsWith(paste0(child, "/"), paste0(parent, "/"))
}

# ---------------------------------------------------------------------------
# which project am I working on?
# ---------------------------------------------------------------------------

#' Set the work directory for this R session.
#'
#' After `ph_use("~/phostor/family")` every other `ph_*()` call may be made
#' with no arguments at all.
#'
#' @param work_dir Path to an initialised phostor work directory.
#' @return The resolved work directory, invisibly.
#' @examples
#' \dontrun{
#' ph_use("~/phostor/family")
#' }
#' @export
ph_use <- function(work_dir) {
  wd <- ph_resolve_path(work_dir)
  cfg_file <- file.path(wd, "config.yml")
  if (!file.exists(cfg_file)) {
    stop("phostor: no config.yml in ", wd,
         ". Run ph_init(\"", work_dir, "\") first.", call. = FALSE)
  }
  options(phostor.work_dir = wd)
  message("phostor: using ", wd)
  invisible(wd)
}

#' The active work directory.
#'
#' Resolution order: explicit argument, `options(phostor.work_dir)`,
#' `$PHOSTOR_WORK`, `$PHOSTOR_CONFIG`, `./config.yml`, `./work/config.yml`.
#'
#' @param work_dir Optional explicit path.
#' @return A resolved directory path.
#' @examples
#' \dontrun{
#' ph_work_dir()
#' }
#' @export
ph_work_dir <- function(work_dir = NULL) {
  cand <- c(work_dir,
            getOption("phostor.work_dir"),
            na_if_empty(Sys.getenv("PHOSTOR_WORK")),
            na_if_empty(dirname(Sys.getenv("PHOSTOR_CONFIG", ""))),
            if (file.exists("config.yml")) getwd(),
            if (file.exists(file.path("work", "config.yml"))) "work")
  cand <- cand[nzchar(cand) & cand != "."]
  if (!length(cand)) {
    stop("phostor: no work directory. Use ph_init(<dir>) to create one, ",
         "ph_use(<dir>) to select one, or set PHOSTOR_WORK.", call. = FALSE)
  }
  ph_resolve_path(cand[[1]])
}

# ---------------------------------------------------------------------------
# creating and editing a project config
# ---------------------------------------------------------------------------

#' Initialise a phostor work directory for one read-only photo directory.
#'
#' Copies the annotated template to `<work_dir>/config.yml` and fills in the
#' fields supplied here. Nothing is written outside `work_dir`; the photo
#' directory is never touched. Edit `<work_dir>/config.yml` directly to change
#' settings, then call [ph_config()] to re-validate.
#'
#' @param work_dir Directory to create/use. Everything phostor writes for this
#'   collection lives here.
#' @param photo_root Read-only root of the photo directory.
#' @param ... Further scalar config fields, e.g. `display_size = 1600`.
#' @param overwrite Replace an existing `config.yml`, archiving the previous
#'   version to `config.history/` first.
#' @return The validated config list, invisibly.
#' @examples
#' \dontrun{
#' ph_init("~/phostor/family", photo_root = "~/photos")
#' }
#' @export
ph_init <- function(work_dir, photo_root = NULL, ..., overwrite = FALSE) {
  wd <- ph_resolve_path(work_dir)
  if (!is.null(photo_root)) {
    pr <- ph_resolve_path(photo_root)
    if (ph_paths_overlap(pr, wd)) {
      stop("phostor: work_dir must not be the same as, inside, or containing ",
           "photo_root.\n  photo_root: ", pr, "\n  work_dir:   ", wd,
           call. = FALSE)
    }
    if (!dir.exists(pr)) {
      warning("phostor: photo_root does not exist yet: ", pr, call. = FALSE)
    }
  }
  dir.create(wd, recursive = TRUE, showWarnings = FALSE)
  cfg_file <- file.path(wd, "config.yml")

  if (file.exists(cfg_file) && !isTRUE(overwrite)) {
    message("phostor: ", cfg_file, " already exists; leaving it in place ",
            "(pass overwrite = TRUE to reset it).")
    return(invisible(ph_config(wd)))
  }
  if (file.exists(cfg_file)) ph_archive_config(wd)

  tmpl <- ph_template_lines()
  fills <- c(list(photo_root = photo_root), list(...))
  fills <- fills[!vapply(fills, is.null, logical(1))]
  for (k in names(fills)) tmpl <- ph_template_set(tmpl, k, fills[[k]])
  writeLines(tmpl, cfg_file)
  message("phostor: wrote ", cfg_file,
          "\n  edit it directly if you need to change settings, then re-run.")

  invisible(ph_config(wd))
}

# Timestamped copy of the live config; returns the archive path (or NULL).
ph_archive_config <- function(work_dir) {
  cfg_file <- file.path(work_dir, "config.yml")
  if (!file.exists(cfg_file)) return(invisible(NULL))
  hist <- file.path(work_dir, "config.history")
  dir.create(hist, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(hist, format(Sys.time(), "config-%Y%m%d-%H%M%S.yml"))
  if (file.exists(dest)) return(invisible(dest))   # same second, same content
  file.copy(cfg_file, dest)
  invisible(dest)
}

# ---------------------------------------------------------------------------
# the annotated template
# ---------------------------------------------------------------------------

# Ships in inst/templates/config.yml so it survives installation. Edited
# textually rather than regenerated through yaml::as.yaml(), which would strip
# every comment. Falls back to the source tree when R/ has been source()d.
ph_template_lines <- function() {
  cands <- c(
    system.file("templates", "config.yml", package = "phostor"),
    file.path(na_if_empty(Sys.getenv("PHOSTOR_SRC")) %||% ".",
              "inst", "templates", "config.yml"),
    file.path(getwd(), "inst", "templates", "config.yml"),
    file.path(getwd(), "..", "..", "inst", "templates", "config.yml")
  )
  cands <- cands[nzchar(cands) & file.exists(cands)]
  if (!length(cands)) {
    stop("phostor: config template not found; reinstall the package.",
         call. = FALSE)
  }
  readLines(cands[[1]])
}

# Replace `key: <anything>` in the template, preserving surrounding comments.
# Only scalar fields are settable this way; list fields are left to the editor.
ph_template_set <- function(lines, key, value) {
  if (length(value) != 1L) return(lines)
  hit <- grep(paste0("^\\s*", key, ":"), lines)
  scalar <- trimws(yaml::as.yaml(value, line.sep = "\n"))
  scalar <- sub("^---\\s*", "", scalar)
  repl <- sprintf("%s: %s", key, scalar)
  if (length(hit)) lines[hit[[1]]] <- repl else lines <- c(lines, repl)
  lines
}

#' Write the annotated example config somewhere for inspection.
#'
#' [ph_init()] is the normal entry point; this is for looking at the template.
#'
#' @param path Destination path.
#' @return `path`, invisibly.
#' @examples
#' ph_config_example(file.path(tempdir(), "config.example.yml"))
#' @export
ph_config_example <- function(path = "config.example.yml") {
  writeLines(ph_template_lines(), path)
  invisible(path)
}

# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

# `x` may be a work directory, a YAML path, a resolved config list, or NULL.
ph_config_source <- function(x = NULL) {
  if (is.list(x)) return(list(cfg = x))
  if (is.null(x)) x <- ph_work_dir()
  x <- ph_resolve_path(x)
  if (dir.exists(x)) {
    f <- file.path(x, "config.yml")
    if (!file.exists(f)) {
      stop("phostor: ", x, " is not an initialised work directory ",
           "(no config.yml). Run ph_init(\"", x, "\").", call. = FALSE)
    }
    return(list(file = f, work_dir = x))
  }
  if (!file.exists(x)) stop("phostor: no config file at ", x, call. = FALSE)
  list(file = x, work_dir = ph_resolve_path(dirname(x)))
}

# config.yml is hand-edited, so a typo (thumb_sze:) is a likely error, and it
# fails silently: the run completes with the default. Name the key and guess
# what was meant.
ph_check_keys <- function(user, defaults) {
  known <- c(names(defaults), "work_dir", ph_derived_keys)
  bad <- setdiff(names(user), known)
  for (k in bad) {
    d <- known[which.min(utils::adist(k, known))]
    warning("phostor: unknown config key '", k, "'",
            if (utils::adist(k, d)[1, 1] <= 3)
              paste0(" -- did you mean '", d, "'?"),
            call. = FALSE)
  }
  invisible(bad)
}

# Type and range validation, reported all at once rather than as whatever
# error the first bad value triggers two commands later.
ph_validate <- function(cfg) {
  err <- character(0)
  num <- function(k, lo, hi) {
    v <- suppressWarnings(as.integer(cfg[[k]])[1])
    if (is.na(v) || v < lo || v > hi) {
      err <<- c(err, sprintf("%s must be an integer in [%d, %d], got '%s'",
                             k, lo, hi, paste(cfg[[k]], collapse = " ")))
    }
    v
  }
  cfg$display_size      <- num("display_size", 256L, 8192L)
  cfg$thumb_size        <- num("thumb_size", 32L, 1024L)
  # 0 keeps every visit, however brief.
  cfg$min_visit_seconds <- num("min_visit_seconds", 0L, 3600L)
  cfg$chunk_seconds     <- num("chunk_seconds", 1L, 60L)
  flag <- suppressWarnings(as.logical(cfg$transcribe)[1])
  if (is.na(flag)) {
    err <- c(err, sprintf("transcribe must be true or false, got '%s'",
                          paste(cfg$transcribe, collapse = " ")))
  }
  cfg$transcribe <- flag
  cfg$transcribe_locale <- as.character(cfg$transcribe_locale %||% "")[1]
  if (is.na(cfg$transcribe_locale)) cfg$transcribe_locale <- ""
  if (!length(cfg$extensions)) err <- c(err, "extensions is empty")
  if (!length(cfg$title) || !nzchar(as.character(cfg$title)[1])) {
    err <- c(err, "title is empty")
  }
  if (length(err)) {
    stop("phostor: invalid config:\n  - ", paste(err, collapse = "\n  - "),
         call. = FALSE)
  }
  cfg
}

#' Load and validate the config for a work directory.
#'
#' @param config A work directory, a YAML path, a config list, or `NULL` to use
#'   the active work directory (see [ph_work_dir()]).
#' @param require_photos Require `photo_root` to be set and to exist.
#' @param create Create the work directory if it is missing.
#' @return A validated config list with absolute paths.
#' @examples
#' \dontrun{
#' cfg <- ph_config("~/phostor/family")
#' }
#' @export
ph_config <- function(config = NULL, require_photos = FALSE, create = TRUE) {
  src <- ph_config_source(config)
  if (!is.null(src$cfg)) return(src$cfg)

  defaults <- ph_config_defaults()
  user <- yaml::read_yaml(src$file)
  # An empty config.yml reads back as NULL, and a file containing a bare
  # scalar reads back as a character vector; neither is a mapping.
  if (!is.list(user)) {
    if (!is.null(user) && length(user)) {
      stop("phostor: ", src$file, " is not a YAML mapping (key: value).",
           call. = FALSE)
    }
    user <- list()
  }
  user <- user[!vapply(user, is.null, logical(1))]   # `key:` with no value
  ph_check_keys(user, defaults)
  cfg <- utils::modifyList(defaults,
                           user[intersect(names(user), names(defaults))])

  # A project is a directory: the one holding config.yml is the work directory.
  cfg$work_dir <- src$work_dir

  cfg$extensions <- tolower(as.character(cfg$extensions))
  cfg$title <- as.character(cfg$title)[1]
  cfg <- ph_validate(cfg)

  if (require_photos) {
    if (is.null(cfg$photo_root) || !nzchar(cfg$photo_root)) {
      stop("phostor: photo_root must be set in ", src$file, call. = FALSE)
    }
    if (!dir.exists(ph_resolve_path(cfg$photo_root))) {
      stop("phostor: photo_root does not exist: ",
           ph_resolve_path(cfg$photo_root), call. = FALSE)
    }
  }
  cfg$photo_root <- ph_resolve_path(cfg$photo_root)

  # Everything phostor writes goes under work_dir, so keeping work_dir and
  # photo_root disjoint is what makes the photo directory read-only.
  if (ph_paths_overlap(cfg$photo_root, cfg$work_dir)) {
    stop("phostor: work_dir must not be the same as, nested inside, or ",
         "contain photo_root.\n  photo_root: ", cfg$photo_root,
         "\n  work_dir:   ", cfg$work_dir, call. = FALSE)
  }

  if (isTRUE(create)) {
    dir.create(cfg$work_dir, recursive = TRUE, showWarnings = FALSE)
  }

  cfg$index_file   <- file.path(cfg$work_dir, "index.tsv")
  cfg$display_dir  <- file.path(cfg$work_dir, "display")
  cfg$thumb_dir    <- file.path(cfg$work_dir, "thumbs")
  cfg$sessions_dir <- file.path(cfg$work_dir, "sessions")
  cfg$sidecar_dir  <- file.path(cfg$work_dir, "sidecars")
  cfg$config_file  <- src$file
  cfg
}

# Accept a work dir, a path, a config list or NULL wherever a config is taken.
ph_as_config <- function(config = NULL, ...) {
  if (is.list(config)) config else ph_config(config, ...)
}

# ---------------------------------------------------------------------------
# provenance
# ---------------------------------------------------------------------------

# Called at the top of each command. Writes the resolved config into work_dir
# as a record of what ran, and as a stable absolute-path file for ph_app(),
# which chdirs. Only user-facing keys are written, so re-reading it raises no
# unknown-key warning; derived paths go in the comment header.
ph_config_snapshot <- function(cfg) {
  out <- file.path(cfg$work_dir, "config.resolved.yml")
  keep <- c(names(ph_config_defaults()), "work_dir")
  body <- cfg[intersect(keep, names(cfg))]
  writeLines(c(
    sprintf("# phostor %s -- written %s. Do not edit; edit config.yml.",
            ph_pkg_version(), format(Sys.time())),
    sprintf("# derived: index=%s display=%s thumbs=%s sessions=%s sidecars=%s",
            cfg$index_file, cfg$display_dir, cfg$thumb_dir, cfg$sessions_dir,
            cfg$sidecar_dir),
    yaml::as.yaml(body)
  ), out)
  invisible(out)
}

# Confirmation of what was loaded, to catch a config from the wrong project.
ph_config_report <- function(cfg) {
  message("phostor project: ", basename(cfg$work_dir))
  message("  photo_root : ", cfg$photo_root %||% "<unset>",
          if (!is.null(cfg$photo_root) && nzchar(cfg$photo_root) &&
              !dir.exists(cfg$photo_root)) "  (MISSING)" else "")
  message("  work_dir   : ", cfg$work_dir)
  message("  title      : ", cfg$title)
  invisible(cfg)
}
