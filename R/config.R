# Configuration defaults. phostor is pointed at a small, local, read-only
# directory, so there is less to tune here than a library-scale tool needs.

# Directory and file names never to index: macOS and Synology artifacts, and
# the thumbnail directories photo managers create.
ph_default_cruft <- c(
  "@eaDir", "#recycle", "#snapshot", "@tmp", ".@__thumb", "@sharebin",
  ".DS_Store", "Thumbs.db", ".Spotlight-V100", ".TemporaryItems",
  ".Trashes", ".fseventsd"
)

# Extensions to index (lowercased, no dot). vipsthumbnail can render all of
# these to the display JPEG the browser is served.
ph_default_extensions <- c(
  "jpg", "jpeg", "jpe", "png", "gif", "bmp", "tif", "tiff", "webp",
  "heic", "heif", "avif"
)

#' The built-in configuration defaults.
#'
#' A plain list of every user-settable field and its default, with no file
#' read, no validation and no derived paths.
#'
#' @return A named list.
#' @examples
#' names(ph_config_defaults())
#' @export
ph_config_defaults <- function() {
  list(
    # The read-only directory of photographs, and the only path a user sets:
    # the work directory is wherever config.yml lives (see R/project.R).
    photo_root = NULL,
    # Shown in the browser title bar and in each session.yml.
    title = "Photographs",
    # Longest edge of the pre-rendered display copy, in pixels. Sized for a 4K
    # display; lower it for a smaller screen or to speed up rendering.
    display_size = 4096L,
    # Longest edge of the tree thumbnail.
    thumb_size = 256L,
    # A visit shorter than this logs a row in path.tsv but writes no sidecar
    # and no audio, so paging through photos does not leave empty records.
    # 0 records every visit.
    min_visit_seconds = 2L,
    # Seconds of audio per uploaded chunk. Smaller loses less to a crash and
    # costs more round trips.
    chunk_seconds = 5L,
    extensions = ph_default_extensions,
    cruft = ph_default_cruft
  )
}
