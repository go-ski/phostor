# Pre-rendered display copies and thumbnails, one pair per photograph.
#
# Rendered up front rather than on demand. At a few hundred photographs that is
# a one-off of seconds, and it means the browser never waits on vips during a
# session, HEIC and TIFF are normalised to a format browsers display, and
# vipsthumbnail applies EXIF rotation.
#
# No LRU cache: bounding one earns its keep at tens of thousands of files; at
# this size it is not worth the complexity.
#
# A render is named after the photograph it was made from, under the size it
# was made at:
#
#   display/4096/Trips/Skye/img_0421.jpg.jpg
#   thumbs/256/Trips/Skye/img_0421.jpg.jpg
#
# The mirror is the same idea as sidecars/: a render is findable from its path
# without phostor. It was once display/<id>.jpg, which named a position in a
# catalogue rather than a photograph -- so two collections in one work
# directory served the same URLs for different pictures, and a browser that had
# cached the first showed it for the second.
#
# The size is a path segment so that changing display_size is not something to
# detect: the old renders are simply not where the app looks, and the URL a
# browser might have cached is not one that is asked for any more.
#
# `.jpg` is appended rather than substituted. `IMG_1234.HEIC` becomes
# `IMG_1234.HEIC.jpg`, which reads oddly but cannot collide: a folder holding
# both `a.jpg` and `a.heic` -- ordinary straight off a phone, and both indexed
# -- would otherwise render them onto each other.

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

#' Where a photograph's render lives, relative to its resource directory.
#'
#' The size, then the photograph's own path with `.jpg` appended:
#' `"4096/Trips/Skye/img_0421.jpg.jpg"`. Exported because `inst/shiny/app.R`
#' builds its image URLs from it, and `runApp()` sources that file with only
#' `library(phostor)` attached.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param kind `"display"` or `"thumb"`.
#' @return A path relative to `display_dir` or `thumb_dir`.
#' @examples
#' \dontrun{
#' ph_render_rel(ph_config(), "Trips/Skye/img_0421.jpg", "display")
#' }
#' @export
ph_render_rel <- function(cfg, rel_path, kind = c("display", "thumb")) {
  kind <- match.arg(kind)
  size <- if (identical(kind, "display")) cfg$display_size else cfg$thumb_size
  file.path(as.integer(size), paste0(rel_path, ".jpg"))
}

# The same, absolute. vipsthumbnail resolves a relative -o against the input
# image's directory, so every destination handed to it must be absolute.
ph_render_path <- function(cfg, rel_path, kind = c("display", "thumb")) {
  kind <- match.arg(kind)
  root <- if (identical(kind, "display")) cfg$display_dir else cfg$thumb_dir
  file.path(root, ph_render_rel(cfg, rel_path, kind))
}

# A render is current when it exists and carries its source's timestamp, which
# ph_render_all() stamps on after writing. An equality test rather than "no
# older than": a photograph restored from a backup, or copied with `cp -p`,
# arrives with a date that is not newer, and comparing with >= would skip it.
# The tolerance is for filesystems that keep mtimes to two seconds.
ph_render_current <- function(dest, src_mtime) {
  if (!file.exists(dest)) return(FALSE)
  d <- abs(as.numeric(file.mtime(dest)) - as.numeric(src_mtime))
  isTRUE(d < 2)
}

#' Renders left over from the old flat layout.
#'
#' phostor once named a render after the photograph's catalogue id rather than
#' its path: `display/7.jpg`. Those files are not read any more, and nothing
#' records what they were made from, so they are neither used nor deleted --
#' [ph_status()] reports them and removing them is your call.
#'
#' @param config A work directory, a config path, or a config list.
#' @return A character vector of paths, empty when there are none.
#' @examples
#' \dontrun{
#' ph_render_orphans("~/phostor/family")
#' }
#' @export
ph_render_orphans <- function(config = NULL) {
  cfg <- ph_as_config(config)
  dirs <- c(cfg$display_dir, cfg$thumb_dir)
  dirs <- dirs[dir.exists(dirs)]
  if (!length(dirs)) return(character(0))
  # Only the top level, and only bare numbers: the current layout puts a size
  # directory there instead, and everything else is somebody else's business.
  unlist(lapply(dirs, function(d) {
    list.files(d, pattern = "^[0-9]+\\.jpg$", full.names = TRUE)
  }), use.names = FALSE)
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

  # Absolute roots for the vipsthumbnail -o rule; the rest of each path comes
  # from ph_render_rel(), so cfg carries the absolute form for both.
  abs_cfg <- cfg
  abs_cfg$display_dir <- display_dir
  abs_cfg$thumb_dir <- thumb_dir

  rendered <- 0L; skipped <- 0L; failed <- character(0)
  pb <- ph_progress(nrow(idx), "rendering", quiet = quiet)
  on.exit(pb$done(), add = TRUE)
  for (i in seq_len(nrow(idx))) {
    src <- file.path(cfg$photo_root, idx$rel_path[i])
    jobs <- list(
      list(dest = ph_render_path(abs_cfg, idx$rel_path[i], "display"),
           size = cfg$display_size),
      list(dest = ph_render_path(abs_cfg, idx$rel_path[i], "thumb"),
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
      # The render mirrors the photo directory, so its parents may not exist.
      dir.create(dirname(j$dest), recursive = TRUE, showWarnings = FALSE)
      out <- ph_render_one(src, j$dest, size = j$size)
      if (is.na(out)) failed <- c(failed, idx$rel_path[i]) else {
        # The render carries its source's timestamp: that is what makes
        # ph_render_current() an exact test, and what makes the browser see a
        # new URL when a photograph is replaced. See the note there.
        try(Sys.setFileTime(j$dest, idx$mtime[i]), silent = TRUE)
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
