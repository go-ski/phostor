# Pre-rendered display copies and thumbnails, one pair per photograph.
#
# Rendered up front rather than on demand. At a few hundred photographs that is
# a one-off of seconds, and it means the browser never waits on vips during a
# session, HEIC and TIFF are normalised to a format browsers display, and
# vipsthumbnail applies EXIF rotation.
#
# No LRU cache: dundee bounds its original cache because it handles tens of
# thousands of files; at this size a cache is not worth the complexity.

# Formats a browser renders from raw bytes. Anything else must be converted
# first, so the display copy is always rendered whatever the source.
ph_web_formats <- c("jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "avif")

#' Is this a format a browser can display directly?
#'
#' @param path A file path.
#' @return `TRUE` or `FALSE`.
#' @examples
#' ph_is_web_format("a.jpg")
#' ph_is_web_format("a.heic")
#' @export
ph_is_web_format <- function(path) ph_ext(path) %in% ph_web_formats

#' Render one photograph to a JPEG of a given longest edge.
#'
#' @param src Source image path.
#' @param dest Destination path. Must be absolute: `vipsthumbnail` resolves a
#'   relative `-o` against the *input image's* directory, not the working
#'   directory, and phostor must never write next to a photograph.
#' @param size Longest-edge pixel size.
#' @param quality JPEG quality.
#' @return `dest`, or `NA_character_` if the render failed.
#' @examples
#' \dontrun{
#' ph_render_one("in.heic", file.path(tempdir(), "out.jpg"), 2048)
#' }
#' @export
ph_render_one <- function(src, dest, size = 2048L, quality = 85L) {
  # system2() builds a command line without quoting, so shQuote every argument
  # to keep spaces and awkward characters in filenames safe.
  status <- tryCatch(
    system2("vipsthumbnail",
            c(shQuote(src), "--size", paste0(size, "x", size),
              "-o", shQuote(sprintf("%s[Q=%d]", dest, as.integer(quality)))),
            stdout = FALSE, stderr = FALSE),
    error = function(e) 1L)
  if (!identical(as.integer(status), 0L) || !file.exists(dest)) {
    return(NA_character_)
  }
  dest
}

# A render is current when it exists and is no older than its source. Comparing
# against the source mtime rather than merely testing existence means an edited
# photograph is picked up, and a re-run costs one stat() per file.
ph_render_current <- function(dest, src_mtime) {
  file.exists(dest) && as.numeric(file.mtime(dest)) >= src_mtime
}

#' Render display copies and thumbnails for the whole catalogue.
#'
#' Idempotent: a second call does no work, and only photographs whose source
#' has changed are re-rendered.
#'
#' @param config A work directory, a config path, or a config list.
#' @param force Re-render everything, current or not.
#' @param quiet Suppress progress output.
#' @return Invisibly, a list of counts: `rendered`, `skipped`, `failed`.
#' @examples
#' \dontrun{
#' ph_render_all("~/phostor/family")
#' }
#' @export
ph_render_all <- function(config = NULL, force = FALSE, quiet = FALSE) {
  cfg <- ph_as_config(config, require_photos = TRUE)
  idx <- ph_read_index(cfg)
  if (!nrow(idx)) {
    message("phostor: nothing to render; run ph_index() first.")
    return(invisible(list(rendered = 0L, skipped = 0L, failed = 0L)))
  }
  if (!nzchar(Sys.which("vipsthumbnail"))) {
    stop("phostor: vipsthumbnail not found (brew install vips).",
         call. = FALSE)
  }
  for (d in c(cfg$display_dir, cfg$thumb_dir)) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }
  # Absolute, for the vipsthumbnail -o rule above.
  display_dir <- normalizePath(cfg$display_dir, mustWork = TRUE)
  thumb_dir   <- normalizePath(cfg$thumb_dir, mustWork = TRUE)

  rendered <- 0L; skipped <- 0L; failed <- character(0)
  pb <- ph_progress(nrow(idx), "rendering", quiet = quiet)
  on.exit(pb$done(), add = TRUE)
  for (i in seq_len(nrow(idx))) {
    src <- file.path(cfg$photo_root, idx$rel_path[i])
    jobs <- list(
      list(dest = file.path(display_dir, paste0(idx$id[i], ".jpg")),
           size = cfg$display_size),
      list(dest = file.path(thumb_dir, paste0(idx$id[i], ".jpg")),
           size = cfg$thumb_size)
    )
    for (j in jobs) {
      if (!isTRUE(force) && ph_render_current(j$dest, idx$mtime[i])) {
        skipped <- skipped + 1L
        next
      }
      if (!file.exists(src)) {
        failed <- c(failed, idx$rel_path[i])
        next
      }
      out <- ph_render_one(src, j$dest, size = j$size)
      if (is.na(out)) failed <- c(failed, idx$rel_path[i]) else {
        rendered <- rendered + 1L
      }
    }
    pb$tick()
  }
  pb$done()

  failed <- unique(failed)
  if (!quiet) {
    message(sprintf("phostor: rendered %d, skipped %d (already current)",
                    rendered, skipped))
    if (length(failed)) {
      message(sprintf("   -> %d photograph(s) could not be rendered:",
                      length(failed)))
      for (f in utils::head(failed, 10L)) message("      ", f)
      if (length(failed) > 10L) {
        message("      ... and ", length(failed) - 10L, " more")
      }
    }
  }
  invisible(list(rendered = rendered, skipped = skipped,
                 failed = length(failed)))
}
