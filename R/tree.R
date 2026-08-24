# The folder tree shown in the sidebar.
#
# HTML is pasted as escaped strings rather than built with div()/span(): tag
# objects cost seconds per render against milliseconds for identical output
# (measured in dundee at 35,000 rows). The tree is rendered once per session
# and the selection highlight is moved client-side.
#
# Nesting uses <details>/<summary>: no JavaScript, no tree library, and
# keyboard navigation comes with the elements.
#
# All the photograph onclicks set one global input. Per-row observeEvent()
# handlers accumulate and leak; a single input does not.

#' Escape text for HTML.
#'
#' Exported because `inst/shiny/app.R` calls it, and `runApp()` sources that
#' file with only `library(phostor)` attached.
#'
#' @param x A character vector.
#' @return `x`, with `&`, `<`, `>`, `"` and `'` replaced by entities. Safe in
#'   element text and in an attribute value alike.
#' @examples
#' ph_escape("Tom & <Jerry>")
#' @export
ph_escape <- function(x) {
  # attribute = TRUE also escapes the quote characters. htmlEscape() defaults
  # to FALSE, which is safe for element text but not for an attribute value.
  # One always-safe function, matching the fallback below.
  if (requireNamespace("htmltools", quietly = TRUE)) {
    return(as.character(htmltools::htmlEscape(x, attribute = TRUE)))
  }
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  gsub("'", "&#39;", x, fixed = TRUE)
}

#' Percent-encode a relative path for use in a URL.
#'
#' One segment at a time, so the separators survive. Filenames here are
#' arbitrary: spaces, `#`, `?` and non-ASCII all occur, and every one of them
#' breaks a raw `src` attribute.
#'
#' @param rel One or more relative paths.
#' @return The encoded paths.
#' @examples
#' ph_url_path("Trips/Isle of Skye/img #4.jpg")
#' @export
ph_url_path <- function(rel) {
  vapply(strsplit(rel, "/", fixed = TRUE), function(segs) {
    paste(vapply(segs, function(s) utils::URLencode(s, reserved = TRUE),
                 character(1)), collapse = "/")
  }, character(1), USE.NAMES = FALSE)
}

#' How many recorded visits each photograph already has.
#'
#' Counts written sidecars only. An interrupted visit's `.part` file reserves
#' its number (see [ph_next_visit()]) but is not a recorded visit.
#'
#' @param cfg A config list from [ph_config()].
#' @param rel_paths Photographs to count, relative to `photo_root`.
#' @return An integer vector, parallel to `rel_paths`.
#' @examples
#' \dontrun{
#' ph_visit_counts(ph_config(), c("a.jpg", "b.jpg"))
#' }
#' @export
ph_visit_counts <- function(cfg, rel_paths) {
  vapply(rel_paths, function(r) {
    d <- ph_visit_dir(cfg, r)
    if (!dir.exists(d)) return(0L)
    length(list.files(d, pattern = "^visit-[0-9]+\\.yml$"))
  }, integer(1), USE.NAMES = FALSE)
}

#' Render the folder tree as one HTML string.
#'
#' Directories become nested `<details>` elements; photographs become clickable
#' rows carrying their id, their name and a badge showing how many visits they
#' already have.
#'
#' Thumbnails are referenced at `thumbs/<id>.jpg`, which the app serves with
#' [shiny::addResourcePath()].
#'
#' @param idx A catalogue from [ph_read_index()].
#' @param counts Optional integer vector of visit counts, parallel to `idx`.
#' @param open_depth Directories at or above this depth start open. `0` opens
#'   only the root level; `Inf` opens everything.
#' @return A length-one character vector of HTML.
#' @examples
#' idx <- data.frame(id = 1:2, rel_path = c("a/x.jpg", "b.jpg"),
#'                   dir = c("a", ""), name = c("x.jpg", "b.jpg"),
#'                   stringsAsFactors = FALSE)
#' substr(ph_tree_html(idx), 1, 40)
#' @export
ph_tree_html <- function(idx, counts = NULL, open_depth = 1L) {
  if (!nrow(idx)) {
    return("<p class=\"ph-empty\">No photographs indexed yet.</p>")
  }
  # C-locale byte order makes every path sharing a directory prefix
  # contiguous, so the open/close walk below is one pass with no lookahead.
  ord <- order(idx$rel_path, method = "radix")
  idx <- idx[ord, , drop = FALSE]
  if (!is.null(counts)) counts <- counts[ord] else counts <- rep(0L, nrow(idx))

  segs <- strsplit(ifelse(is.na(idx$dir), "", idx$dir), "/", fixed = TRUE)
  segs <- lapply(segs, function(s) s[nzchar(s)])

  out <- character(0)
  prev <- character(0)
  for (i in seq_len(nrow(idx))) {
    cur <- segs[[i]]
    # Common prefix with the previous row: everything below it closes, and
    # everything new above it opens.
    n <- 0L
    while (n < length(cur) && n < length(prev) &&
           identical(cur[[n + 1L]], prev[[n + 1L]])) n <- n + 1L
    if (length(prev) > n) out <- c(out, strrep("</details>", length(prev) - n))
    if (length(cur) > n) {
      for (d in seq.int(n + 1L, length(cur))) {
        out <- c(out, sprintf("<details%s><summary class=\"ph-d\">%s</summary>",
                              if (d <= open_depth) " open" else "",
                              ph_escape(cur[[d]])))
      }
    }
    id <- as.integer(idx$id[i])
    nvis <- as.integer(counts[i])
    out <- c(out, paste0(
      "<div id=\"ph-p-", id, "\" class=\"ph-p\"",
      # One handler for the tree, regardless of row count.
      " onclick=\"Shiny.setInputValue(&#39;photo_pick&#39;,", id,
      ",{priority: &#39;event&#39;})\">",
      # loading="lazy": otherwise every thumbnail is fetched when the tree
      # first paints.
      "<img class=\"ph-t\" loading=\"lazy\" alt=\"\" src=\"thumbs/", id,
      ".jpg\">",
      "<span class=\"ph-n\">", ph_escape(idx$name[i]), "</span>",
      if (nvis > 0L) paste0("<span class=\"ph-b\">", nvis, "</span>") else "",
      "</div>"))
    prev <- cur
  }
  if (length(prev)) out <- c(out, strrep("</details>", length(prev)))
  paste0("<div class=\"ph-tree\">", paste0(out, collapse = ""), "</div>")
}

#' Photograph ids in tree order.
#'
#' The order the arrow keys step through, and the order the tree displays.
#'
#' @param idx A catalogue from [ph_read_index()].
#' @return An integer vector of ids.
#' @examples
#' idx <- data.frame(id = c(2L, 1L), rel_path = c("b.jpg", "a.jpg"),
#'                   stringsAsFactors = FALSE)
#' ph_tree_order(idx)
#' @export
ph_tree_order <- function(idx) {
  if (!nrow(idx)) return(integer(0))
  as.integer(idx$id[order(idx$rel_path, method = "radix")])
}
