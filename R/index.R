# The catalogue. One TSV row per photograph, rebuilt on demand.
#
# A phostor collection is local and a few hundred files, so list.files() is the
# whole scanner and there is no shell layer.

# Columns of index.tsv, in order. Anything reading the file should go through
# ph_read_index() rather than assuming these.
ph_index_cols <- c("id", "rel_path", "dir", "name", "ext", "bytes", "mtime",
                   "capture", "capture_src", "width", "height")

# Lowercased extension with no dot; "" when there is none.
ph_ext <- function(path) {
  e <- sub(".*\\.", "", basename(path))
  ifelse(e == basename(path), "", tolower(e))
}

# A tab or newline in a path corrupts index.tsv and path.tsv, both of which are
# tab-separated. Refuse at discovery, naming the file, rather than writing one
# that reads back wrong.
ph_check_paths <- function(rel) {
  bad <- grepl("[\t\r\n]", rel)
  if (any(bad)) {
    stop("phostor: these paths contain a tab or newline and cannot be ",
         "indexed:\n  ", paste(rel[bad], collapse = "\n  "),
         "\n  Rename them, or exclude their directory via `cruft`.",
         call. = FALSE)
  }
  # Invalid UTF-8 reaches R from filesystems written under another locale. If
  # it is written to index.tsv the catalogue becomes unreadable later.
  ok <- validUTF8(rel)
  if (!all(ok)) {
    stop("phostor: these paths are not valid UTF-8 and cannot be indexed:\n  ",
         paste(rel[!ok], collapse = "\n  "), call. = FALSE)
  }
  invisible(rel)
}

#' Scan the photo directory.
#'
#' Walks `photo_root` once and returns one row per photograph, with no
#' metadata read and no ids assigned. [ph_index()] is the normal entry point.
#'
#' @param cfg A config list from [ph_config()].
#' @return A data.frame with `rel_path`, `dir`, `name`, `ext`, `bytes`,
#'   `mtime`, ordered by `rel_path` in C-locale byte order.
#' @examples
#' \dontrun{
#' nrow(ph_scan(ph_config()))
#' }
#' @export
ph_scan <- function(cfg) {
  root <- cfg$photo_root
  if (is.null(root) || !nzchar(root) || !dir.exists(root)) {
    stop("phostor: photo_root does not exist: ", root %||% "<unset>",
         call. = FALSE)
  }
  all_files <- list.files(root, recursive = TRUE, all.files = TRUE,
                          no.. = TRUE, include.dirs = FALSE)
  if (!length(all_files)) return(ph_empty_scan())

  # Prune cruft by whole path segment, so `@eaDir` matches the directory but
  # `@eaDirectory` does not.
  segs <- strsplit(all_files, "/", fixed = TRUE)
  cruft <- vapply(segs, function(s) any(s %in% cfg$cruft), logical(1))
  keep <- all_files[!cruft]
  keep <- keep[ph_ext(keep) %in% cfg$extensions]
  if (!length(keep)) return(ph_empty_scan())

  ph_check_paths(keep)
  keep <- keep[order(keep, method = "radix")]

  info <- file.info(file.path(root, keep), extra_cols = FALSE)
  data.frame(
    rel_path = keep,
    dir      = ifelse(dirname(keep) == ".", "", dirname(keep)),
    name     = basename(keep),
    ext      = ph_ext(keep),
    bytes    = as.numeric(info$size),
    mtime    = as.numeric(info$mtime),
    stringsAsFactors = FALSE
  )
}

ph_empty_scan <- function() {
  data.frame(rel_path = character(0), dir = character(0), name = character(0),
             ext = character(0), bytes = numeric(0), mtime = numeric(0),
             stringsAsFactors = FALSE)
}

# One exiftool call for the whole collection, not one per file. Perl startup is
# roughly 90 ms, so 200 photographs is 18 seconds against well under one.
# Filenames go through an argfile, so spaces, quotes and non-ASCII need no
# shell quoting.
#
# Returns a data.frame of capture/capture_src/width/height, one row per input,
# in input order.
ph_exif_batch <- function(paths, quiet = FALSE) {
  n <- length(paths)
  empty <- data.frame(capture = rep(NA_character_, n),
                      capture_src = rep(NA_character_, n),
                      width = rep(NA_integer_, n),
                      height = rep(NA_integer_, n),
                      stringsAsFactors = FALSE)
  if (!n) return(empty)
  if (!nzchar(Sys.which("exiftool"))) {
    if (!quiet) {
      message("   -> exiftool not found; capture dates and dimensions ",
              "will be blank")
    }
    return(empty)
  }

  argfile <- tempfile("phostor-exif-", fileext = ".txt")
  on.exit(unlink(argfile), add = TRUE)
  # useBytes: the paths are validated UTF-8 already, and re-encoding them under
  # a C locale would mangle the names being passed to exiftool.
  writeLines(paths, argfile, useBytes = TRUE)

  out <- tryCatch(
    system2("exiftool",
            c("-m", "-q", "-q", "-T", "-charset", "filename=UTF8",
              "-DateTimeOriginal", "-CreateDate", "-ImageWidth", "-ImageHeight",
              "-@", shQuote(argfile)),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0))
  # -T prints one tab-separated line per file, in input order, with "-" for any
  # tag it could not read. A short read means the call failed for every file
  # rather than some, so fall back wholesale rather than misalign the rows.
  if (length(out) != n) {
    if (!quiet && length(out)) {
      message("   -> exiftool returned ", length(out), " lines for ", n,
              " files; metadata skipped")
    }
    return(empty)
  }

  f <- strsplit(out, "\t", fixed = TRUE)
  get <- function(i) vapply(f, function(x) if (length(x) >= i) x[[i]] else "-",
                            character(1))
  dash <- function(x) ifelse(x %in% c("-", "", "0000:00:00 00:00:00"),
                             NA_character_, x)
  dto <- dash(get(1)); cre <- dash(get(2))
  cd <- ph_capture_date(dto, cre)
  data.frame(
    capture     = cd$value,
    capture_src = cd$source,
    width       = suppressWarnings(as.integer(dash(get(3)))),
    height      = suppressWarnings(as.integer(dash(get(4)))),
    stringsAsFactors = FALSE
  )
}

#' Capture date, with the fallback named.
#'
#' `DateTimeOriginal` is the date the photograph was taken. `CreateDate` is
#' often the date of a scan or export, so when it is the only value available
#' the app labels which field it is showing.
#'
#' @param capture `DateTimeOriginal` values, or `NA`.
#' @param create_date `CreateDate` values, or `NA`.
#' @return A list of two equal-length character vectors, `value` and `source`.
#' @examples
#' ph_capture_date(c("1974:07:03 14:22:01", NA), c(NA, "2011:02:02 09:00:00"))
#' @export
ph_capture_date <- function(capture, create_date = NA_character_) {
  capture <- as.character(capture)
  create_date <- rep_len(as.character(create_date), length(capture))
  ok <- function(x) !is.na(x) & nzchar(x)
  value <- ifelse(ok(capture), capture,
                  ifelse(ok(create_date), create_date, NA_character_))
  source <- ifelse(ok(capture), "DateTimeOriginal",
                   ifelse(ok(create_date), "CreateDate", NA_character_))
  list(value = value, source = source)
}

#' Read the catalogue.
#'
#' @param cfg A config list from [ph_config()].
#' @return A data.frame with the columns of `index.tsv`, empty if there is no
#'   catalogue yet.
#' @examples
#' \dontrun{
#' head(ph_read_index(ph_config()))
#' }
#' @export
ph_read_index <- function(cfg) {
  f <- cfg$index_file
  if (!file.exists(f)) {
    out <- as.data.frame(
      stats::setNames(rep(list(character(0)), length(ph_index_cols)),
                      ph_index_cols), stringsAsFactors = FALSE)
    out$id <- integer(0); out$bytes <- numeric(0); out$mtime <- numeric(0)
    out$width <- integer(0); out$height <- integer(0)
    return(out)
  }
  x <- utils::read.table(f, sep = "\t", header = TRUE, quote = "",
                         comment.char = "", stringsAsFactors = FALSE,
                         colClasses = "character", encoding = "UTF-8",
                         na.strings = character(0))
  x$id     <- as.integer(x$id)
  x$bytes  <- as.numeric(x$bytes)
  x$mtime  <- as.numeric(x$mtime)
  x$width  <- suppressWarnings(as.integer(x$width))
  x$height <- suppressWarnings(as.integer(x$height))
  for (k in c("capture", "capture_src")) x[[k]][x[[k]] == ""] <- NA_character_
  x
}

ph_write_index <- function(cfg, idx) {
  out <- idx[, ph_index_cols, drop = FALSE]
  chr <- vapply(out, is.character, logical(1))
  out[chr] <- lapply(out[chr], function(v) ifelse(is.na(v), "", v))
  # Tab-joined by hand rather than through write.table(), which transliterates
  # non-ASCII under a C locale and would rewrite the recorded filenames.
  lines <- c(paste(ph_index_cols, collapse = "\t"),
             do.call(paste, c(unname(out), list(sep = "\t"))))
  writeLines(lines, cfg$index_file, useBytes = TRUE)
  invisible(cfg$index_file)
}

#' Build or refresh the catalogue.
#'
#' Scans `photo_root`, assigns an id to every photograph it has not seen
#' before, reads capture dates and dimensions in a single `exiftool` call, and
#' writes `index.tsv`.
#'
#' Ids are stable: a photograph keeps the id it was first given, and a new one
#' takes the next number up. Nothing is keyed by position in the file, so
#' adding photographs does not renumber the rendered copies of existing ones.
#'
#' Photographs no longer present in `photo_root` drop out of the catalogue.
#' Their sidecars are left in place.
#'
#' @param config A work directory, a config path, or a config list.
#' @param quiet Suppress progress messages.
#' @return The catalogue, invisibly.
#' @examples
#' \dontrun{
#' idx <- ph_index("~/phostor/family")
#' }
#' @export
ph_index <- function(config = NULL, quiet = FALSE) {
  cfg <- ph_as_config(config, require_photos = TRUE)
  ph_config_snapshot(cfg)
  ph_step(paste0("scanning ", cfg$photo_root), quiet = quiet)

  found <- ph_scan(cfg)
  if (!nrow(found)) {
    ph_write_index(cfg, cbind(found, id = integer(0), capture = character(0),
                              capture_src = character(0), width = integer(0),
                              height = integer(0)))
    message("phostor: no photographs found under ", cfg$photo_root)
    return(invisible(ph_read_index(cfg)))
  }

  old <- ph_read_index(cfg)
  found$id <- old$id[match(found$rel_path, old$rel_path)]
  fresh <- is.na(found$id)
  if (any(fresh)) {
    start <- if (nrow(old)) max(old$id, na.rm = TRUE) else 0L
    found$id[fresh] <- start + seq_len(sum(fresh))
  }

  ph_step(sprintf("reading metadata for %d photograph(s)", nrow(found)),
          quiet = quiet)
  meta <- ph_exif_batch(file.path(cfg$photo_root, found$rel_path),
                        quiet = quiet)
  idx <- cbind(found, meta)

  ph_write_index(cfg, idx)
  if (!quiet) {
    message(sprintf("phostor: %d photograph(s) indexed%s -> %s",
                    nrow(idx),
                    if (any(fresh)) sprintf(" (%d new)", sum(fresh)) else "",
                    cfg$index_file))
    gone <- setdiff(old$rel_path, idx$rel_path)
    if (length(gone)) {
      message(sprintf("   -> %d photograph(s) no longer in %s; their sidecars ",
                      length(gone), cfg$photo_root),
              "are untouched")
    }
  }
  invisible(ph_read_index(cfg))
}
