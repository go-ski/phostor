# Fixture photographs are generated, not committed: the repository holds no
# images, and the fixtures cannot drift from the tools that read them.

have_vips <- function() nzchar(Sys.which("vips"))
have_vipsthumbnail <- function() nzchar(Sys.which("vipsthumbnail"))

skip_without_vips <- function() {
  testthat::skip_if_not(have_vips(), "vips not installed")
}

# A small nested photo directory with awkward names: a space, an ampersand
# that must be escaped into HTML, a nested directory, cruft that must be
# skipped, and a non-photograph that must be ignored.
make_photos <- function(dir = tempfile("photos-")) {
  skip_without_vips()
  dir.create(file.path(dir, "Trips", "Skye"), recursive = TRUE)
  dir.create(file.path(dir, "@eaDir"), recursive = TRUE)
  gen <- function(rel, w, h) {
    v <- file.path(dir, "_tmp.v")
    system2("vips", c("gaussnoise", shQuote(v), w, h),
            stdout = FALSE, stderr = FALSE)
    system2("vips", c("copy", shQuote(v), shQuote(file.path(dir, rel))),
            stdout = FALSE, stderr = FALSE)
    unlink(v)
  }
  gen("top.jpg", 600, 400)
  gen("Trips/Skye/a b.jpg", 100, 75)
  gen("Trips/Skye/c&d.jpg", 80, 60)
  gen("Trips/x.png", 64, 64)
  writeLines("cruft", file.path(dir, "@eaDir", "SYNOPHOTO_THUMB.jpg"))
  writeLines("not a photograph", file.path(dir, "notes.txt"))
  dir
}

# An initialised project: a work directory disjoint from the photographs.
make_project <- function(index = TRUE, render = FALSE, ...) {
  photos <- make_photos()
  work <- tempfile("work-")
  # `...` reaches ph_init(): a test that needs every visit kept asks for
  # min_visit_seconds = 0, since no time passes under testServer.
  suppressMessages(ph_init(work, photo_root = photos, ...))
  cfg <- ph_config(work)
  if (index) suppressMessages(ph_index(cfg, quiet = TRUE))
  if (render) {
    testthat::skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
    suppressMessages(ph_render_all(cfg, quiet = TRUE))
  }
  list(work = work, photos = photos, cfg = cfg)
}

# Every path under `dir`, with its size and mtime. Compared before and after
# to check the photo directory was not modified.
fs_snapshot <- function(dir) {
  f <- sort(list.files(dir, recursive = TRUE, all.files = TRUE, no.. = TRUE))
  if (!length(f)) return(data.frame())
  i <- file.info(file.path(dir, f), extra_cols = FALSE)
  data.frame(path = f, size = i$size, mtime = as.numeric(i$mtime),
             stringsAsFactors = FALSE)
}

# ph_init() warns when photo_root does not exist yet, which is noise in tests
# that are about something else.
quiet_init <- function(...) suppressWarnings(suppressMessages(ph_init(...)))

# --- reaching the package's own files from wherever the suite is running ----
#
# Under test_local() the source tree is two levels up. Under R CMD check the
# tests run from <pkg>.Rcheck/tests, where only the installed package exists.
# Any test that reads phostor's own files must handle both.

first_path <- function(...) {
  for (p in c(...)) if (nzchar(p) && file.exists(p)) return(p)
  NULL
}

app_file <- function() {
  first_path("../../inst/shiny/app.R",
             system.file("shiny", "app.R", package = "phostor"))
}

namespace_file <- function() {
  first_path("../../NAMESPACE", system.file("NAMESPACE", package = "phostor"))
}

description_file <- function() {
  first_path("../../DESCRIPTION",
             system.file("DESCRIPTION", package = "phostor"))
}

# Every line of phostor's own R code. Prefers the namespace, which exists
# whether the package was installed or loaded by pkgload; falls back to the
# source tree for a bare source() of R/ (tests/testthat/setup.R).
package_source <- function() {
  ns <- tryCatch(asNamespace("phostor"), error = function(e) NULL)
  if (!is.null(ns)) {
    return(unlist(lapply(ls(ns, all.names = TRUE), function(n) {
      o <- tryCatch(get(n, envir = ns), error = function(e) NULL)
      if (is.function(o)) deparse(o) else character(0)
    })))
  }
  files <- list.files("../../R", pattern = "\\.R$", full.names = TRUE)
  unlist(lapply(files, readLines))
}
