# Tags: who is in a photograph, where, what was happening, and when.
#
# Facts about the photograph, not about any one visit to it, so they live in
# their own file in the photograph's sidecar directory:
#
#   sidecars/Trips/Skye/img_0421.jpg/tags.yml
#
# Named so that it does not begin `visit-`: ph_visit_numbers(),
# ph_visit_counts() and ph_visits_for() all match `^visit-[0-9]+`, and this
# file must not consume a visit number, add to the tree badge, or turn up in
# the visits panel.
#
# This is the one file phostor rewrites. Every other file under sidecars/ is
# written once and then only added to, and says so in its own header; this one
# says the opposite in its header, because a reader will otherwise assume the
# rule that holds for everything around it.
#
# Tags were once written into each visit's sidecar, which meant they could only
# be entered while a sitting was running. Those older sidecars are still read:
# a photograph with no tags.yml falls back to its most recent visit, so nothing
# recorded before this existed is lost, and the first edit writes the file.

# The empty answer, and the shape every reader gets back.
ph_tags_empty <- function() {
  list(people = character(0), place = "", event = "", when = "")
}

ph_tags_path <- function(cfg, rel_path) {
  file.path(ph_visit_dir(cfg, rel_path), "tags.yml")
}

#' Put a set of tags into their canonical shape.
#'
#' Trims, drops empty names, and gives every field the type it should have, so
#' that two sets of tags can be compared. Exported because `inst/shiny/app.R`
#' calls it to tell an edit from the seeding of the fields, and `runApp()`
#' sources that file with only `library(phostor)` attached.
#'
#' @param x A list with any of `people`, `place`, `event`, `when`; anything
#'   else is ignored, and anything missing comes back empty.
#' @return A list of `people` (a character vector), `place`, `event` and `when`
#'   (single strings, `""` when unset).
#' @examples
#' ph_tags_clean(list(place = "  Elgol ", people = c("Vera", "", " Stefan")))
#' @export
ph_tags_clean <- function(x) {
  people <- trimws(as.character(unlist(x$people %||% character(0),
                                       use.names = FALSE)))
  one <- function(k) {
    v <- x[[k]]
    if (is.null(v) || (length(v) == 1L && is.na(v))) return("")
    trimws(as.character(v)[1])
  }
  list(people = people[!is.na(people) & nzchar(people)],
       place = one("place"), event = one("event"), when = one("when"))
}

# Is there anything here worth a file?
ph_tags_empty_p <- function(tags) {
  !length(tags$people) && !any(nzchar(c(tags$place, tags$event, tags$when)))
}

#' The tags on one photograph.
#'
#' Reads `tags.yml`. A photograph that has none falls back to the most recent
#' visit that recorded any, which is where tags were kept before they became a
#' property of the photograph.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @return A list of `people` (a character vector, possibly empty), `place`,
#'   `event` and `when` (single strings, `""` when unset).
#' @examples
#' \dontrun{
#' ph_tags("~/phostor/family", "Trips/Skye/img_0421.jpg")
#' }
#' @export
ph_tags <- function(config, rel_path) {
  cfg <- ph_as_config(config)
  path <- ph_tags_path(cfg, rel_path)
  if (file.exists(path)) {
    x <- tryCatch(yaml::read_yaml(path), error = function(e) NULL)
    if (is.list(x)) return(ph_tags_clean(x))
    # A corrupt or hand-broken file is not worth stopping a sitting for; fall
    # through to the visits, which are still readable.
  }
  last <- ph_last_visit(cfg, rel_path)
  if (is.null(last)) return(ph_tags_empty())
  ph_tags_clean(last)
}

#' Write the tags on one photograph.
#'
#' Replaces `tags.yml`. Unlike a visit sidecar, this file is meant to be
#' rewritten: it holds what is currently known about the photograph rather than
#' a record of one sitting.
#'
#' Writes nothing when every field is empty and no file exists yet, so paging
#' through photographs does not leave one behind on each.
#'
#' @param config A work directory, a config path, or a config list.
#' @param rel_path Path of the photograph relative to `photo_root`.
#' @param tags A list of any of `people`, `place`, `event`, `when`.
#' @return The path written, or `NA_character_` when nothing was, invisibly.
#' @examples
#' \dontrun{
#' ph_write_tags(ph_config(), "Trips/Skye/img_0421.jpg", list(place = "Elgol"))
#' }
#' @export
ph_write_tags <- function(config, rel_path, tags) {
  cfg <- ph_as_config(config)
  t <- ph_tags_clean(tags)
  path <- ph_tags_path(cfg, rel_path)
  # Clearing the last field of a photograph that has a file must still write,
  # or the cleared values would come back on the next read.
  if (ph_tags_empty_p(t) && !file.exists(path)) return(invisible(NA_character_))

  ph_visit_dir(cfg, rel_path, create = TRUE)
  body <- list(photo = rel_path,
               updated = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  # Single-bracket assignment for the empty ones: `body[[k]] <- NULL` would
  # delete the key rather than write `~`. as.list() on people gives `[]` rather
  # than a dropped key when there are no names.
  body[["people"]] <- as.list(t$people)
  for (k in c("place", "event", "when")) {
    if (nzchar(t[[k]])) body[[k]] <- t[[k]] else body[k] <- list(NULL)
  }

  writeLines(c(
    sprintf("# phostor %s -- tags for %s", ph_pkg_version(), rel_path),
    "# Safe to hand-edit. Unlike a visit sidecar, phostor rewrites this file",
    "# whenever these fields change in the app.",
    yaml::as.yaml(body)
  ), path, useBytes = TRUE)
  invisible(path)
}
