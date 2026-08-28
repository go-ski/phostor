test_that("a session writes a header and a start row", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  expect_true(file.exists(file.path(d, "session.yml")))
  expect_true(file.exists(file.path(d, "path.tsv")))
  x <- ph_path_read(d)
  expect_equal(names(x), ph_path_cols)
  expect_equal(x$event, "start")
  meta <- yaml::read_yaml(file.path(d, "session.yml"))
  expect_equal(meta$photo_root, p$cfg$photo_root)
})

test_that("two sessions in one minute get separate directories", {
  p <- make_project()
  a <- ph_path_new(p$cfg)
  b <- ph_path_new(p$cfg)
  expect_false(identical(a, b))
  expect_equal(nrow(ph_sessions(p$cfg)), 2L)
})

test_that("the path records what happened, in order", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  ph_path_append(d, "show", rel_path = "top.jpg", visit = 1L)
  ph_path_append(d, "leave", rel_path = "top.jpg", visit = 1L,
                 duration = 94.23)
  ph_path_append(d, "show", rel_path = "Trips/x.png", visit = 1L)
  ph_path_append(d, "end")
  x <- ph_path_read(d)
  expect_equal(x$event, c("start", "show", "leave", "show", "end"))
  expect_equal(x$rel_path, c("-", "top.jpg", "top.jpg", "Trips/x.png", "-"))
  expect_equal(x$duration[3], "94.2")
  # Absent values are a dash, not an empty cell, which would shift columns.
  expect_equal(x$visit[1], "-")
  expect_true(all(nzchar(unlist(x))))
})

test_that("elapsed time is measured from the session's own first row", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  ph_path_append(d, "show", rel_path = "top.jpg", visit = 1L,
                 time = Sys.time() + 12)
  x <- ph_path_read(d)
  expect_equal(as.numeric(x$elapsed[1]), 0)
  expect_gte(as.numeric(x$elapsed[2]), 11)
})

test_that("an unknown event is refused rather than written", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  expect_error(ph_path_append(d, "wander"), "arg")
  expect_equal(nrow(ph_path_read(d)), 1L)
})

test_that("awkward filenames survive the tab-separated round trip", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  rel <- "Trips/Skye/c&d.jpg"
  ph_path_append(d, "show", rel_path = rel, visit = 1L)
  expect_equal(ph_path_read(d)$rel_path[2], rel)
})

test_that("the playlist holds the completed visits in view order", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  ph_path_append(d, "show", rel_path = "top.jpg", visit = 1L)
  ph_path_append(d, "leave", rel_path = "top.jpg", visit = 1L, duration = 30)
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(audio = "visit-0001.webm",
                                              duration = 30))
  ph_path_append(d, "show", rel_path = "Trips/x.png", visit = 1L)
  ph_path_append(d, "leave", rel_path = "Trips/x.png", visit = 1L,
                 duration = 12)
  ph_path_append(d, "show", rel_path = "top.jpg", visit = 2L)
  ph_path_append(d, "leave", rel_path = "top.jpg", visit = 2L, duration = 8)
  ph_write_sidecar(p$cfg, "top.jpg", 2L, list(audio = "visit-0002.webm",
                                              duration = 8))

  pl <- ph_playlist(p$cfg, d)
  expect_equal(pl$rel_path, c("top.jpg", "Trips/x.png", "top.jpg"))
  expect_equal(pl$visit, c(1L, 1L, 2L))
  expect_equal(pl$audio[1], "top.jpg/visit-0001.webm")
  # A visit that recorded nothing, and so has no sidecar, is still replayed,
  # using the duration recorded in the path.
  expect_true(is.na(pl$audio[2]))
  expect_equal(pl$duration[2], 12)
  idx <- ph_read_index(p$cfg)
  expect_equal(pl$id[1], idx$id[idx$rel_path == "top.jpg"])
})

test_that("a photograph no longer in the catalogue drops out of the playlist", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  ph_path_append(d, "leave", rel_path = "top.jpg", visit = 1L, duration = 5)
  ph_path_append(d, "leave", rel_path = "gone.jpg", visit = 1L, duration = 5)
  pl <- ph_playlist(p$cfg, d)
  expect_equal(pl$rel_path, "top.jpg")
})

test_that("sessions are listed newest first with their visit counts", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  ph_path_append(d, "leave", rel_path = "top.jpg", visit = 1L, duration = 5)
  s <- ph_sessions(p$cfg)
  expect_equal(nrow(s), 1L)
  expect_equal(s$visits, 1L)
  expect_equal(s$title, p$cfg$title)
  expect_equal(s$dir, d)
})

test_that("reading a missing or empty path returns an empty frame", {
  p <- make_project()
  expect_equal(nrow(ph_path_read(tempfile())), 0L)
  expect_equal(nrow(ph_sessions(p$cfg)), 0L)
})

test_that("the audio a visit recorded is read from its sidecar", {
  p <- make_project()
  d <- ph_path_new(p$cfg)
  ph_path_append(d, "leave", rel_path = "top.jpg", visit = 1L, duration = 5)
  # No sidecar yet: nothing was kept, so there is nothing to play.
  expect_true(is.na(ph_playlist(p$cfg, d)$audio[1]))

  # path.tsv does not carry the audio name, so it cannot drift from disk.
  ph_write_sidecar(p$cfg, "top.jpg", 1L,
                   list(audio = "visit-0001.webm", duration = 91.5))
  pl <- ph_playlist(p$cfg, d)
  expect_equal(pl$audio[1], "top.jpg/visit-0001.webm")
  expect_equal(pl$duration[1], 91.5)   # the sidecar takes precedence
  expect_false("audio" %in% ph_path_cols)
})
