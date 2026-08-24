# Configuration defaults. phostor is pointed at a small, local, read-only
# directory -- one sitting's worth of photographs -- so there is far less to
# tune here than a library-scale tool needs.

# Directory and file names never to index. macOS and Synology artifacts, plus
# the thumbnail directories photo managers scatter around.
ph_default_cruft <- c(
  "@eaDir", "#recycle", "#snapshot", "@tmp", ".@__thumb", "@sharebin",
  ".DS_Store", "Thumbs.db", ".Spotlight-V100", ".TemporaryItems",
  ".Trashes", ".fseventsd"
)

# Extensions to index (lowercased, no dot). Everything here can be rendered to
# a display JPEG by vipsthumbnail, which is what the browser is actually shown.
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
    # The read-only directory of photographs. The only path a user sets: the
    # work directory is wherever config.yml lives (see R/project.R).
    photo_root = NULL,
    # Shown in the browser title bar and on the sitting's session.yml.
    title = "Photographs",
    # Longest edge of the pre-rendered display copy, in pixels.
    display_size = 2048L,
    # Longest edge of the tree thumbnail.
    thumb_size = 240L,
    # A visit shorter than this logs a row in path.tsv but writes no sidecar
    # and no audio, so paging past forty photos looking for one does not leave
    # forty empty records. 0 records every visit, however brief.
    min_visit_seconds = 2L,
    # Seconds of audio per uploaded chunk. Smaller means less lost to a crash
    # and more round trips; 5 is imperceptible either way.
    chunk_seconds = 5L,
    extensions = ph_default_extensions,
    cruft = ph_default_cruft
  )
}
