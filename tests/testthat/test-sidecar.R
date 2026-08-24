test_that("visit numbering starts at one and never reuses a number", {
  p <- make_project()
  rel <- "Trips/Skye/a b.jpg"
  expect_equal(ph_next_visit(p$cfg, rel), 1L)

  ph_write_sidecar(p$cfg, rel, 1L, list(place = "one"))
  expect_equal(ph_next_visit(p$cfg, rel), 2L)
  ph_write_sidecar(p$cfg, rel, 2L, list(place = "two"))
  ph_write_sidecar(p$cfg, rel, 3L, list(place = "three"))
  expect_equal(ph_next_visit(p$cfg, rel), 4L)

  # Deleting a visit from the middle must not let the next one silently take
  # its number and overwrite what is still there.
  unlink(file.path(ph_visit_dir(p$cfg, rel), "visit-0002.yml"))
  expect_equal(ph_next_visit(p$cfg, rel), 4L)

  # Even deleting the highest: numbering follows what is still on disk, but the
  # remaining sidecars keep their own numbers.
  unlink(file.path(ph_visit_dir(p$cfg, rel), "visit-0003.yml"))
  expect_equal(ph_next_visit(p$cfg, rel), 2L)
  expect_equal(ph_read_sidecar(
    file.path(ph_visit_dir(p$cfg, rel), "visit-0001.yml"))$visit, 1L)
})

test_that("an interrupted visit still claims its number", {
  p <- make_project()
  rel <- "top.jpg"
  part <- ph_audio_open(p$cfg, rel, 1L)
  expect_true(file.exists(part))
  # No sidecar was written, but the number is taken: leaving a photograph and
  # coming straight back must not reuse it.
  expect_equal(ph_next_visit(p$cfg, rel), 2L)
  # ...and it is not counted as a visit, because nothing was recorded.
  expect_equal(ph_visit_counts(p$cfg, rel), 0L)
})

test_that("sidecars mirror the photo tree, a directory per photograph", {
  p <- make_project()
  rel <- "Trips/Skye/c&d.jpg"
  out <- ph_write_sidecar(p$cfg, rel, 1L, list(place = "Elgol"))
  expect_equal(out, file.path(p$cfg$sidecar_dir, rel, "visit-0001.yml"))
  expect_true(dir.exists(file.path(p$cfg$sidecar_dir, "Trips", "Skye",
                                   "c&d.jpg")))
  # Nothing was written next to the photograph itself.
  expect_false(file.exists(file.path(p$photos, "Trips", "Skye",
                                     "c&d.jpg", "visit-0001.yml")))
})

test_that("a sidecar round-trips awkward values", {
  p <- make_project()
  rel <- "top.jpg"
  people <- c("Nana Vera", "Uncle Stefan, senior", "? child in blue",
              "Žofie")
  ph_write_sidecar(p$cfg, rel, 1L, list(
    session = "2026-08-23-1930", started = "2026-08-23T20:14:07Z",
    ended = "2026-08-23T20:15:41Z", duration = 94.23,
    audio = "visit-0001.webm", people = people,
    place = "Elgol, Isle of Skye", event = "the 1974 camping trip",
    when = "summer 1974"))
  s <- ph_read_sidecar(file.path(ph_visit_dir(p$cfg, rel), "visit-0001.yml"))
  expect_equal(s$people, people)
  expect_equal(s$place, "Elgol, Isle of Skye")
  expect_equal(s$duration, 94.2)
  expect_equal(s$visit, 1L)
  expect_equal(s$photo, rel)
})

test_that("every schema field is present, empty ones as an explicit null", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list())
  f <- file.path(ph_visit_dir(p$cfg, "top.jpg"), "visit-0001.yml")
  txt <- readLines(f)
  # transcript is reserved for a later offline pass: the key must exist now, so
  # adding it later is not a format change.
  expect_true(any(grepl("^transcript: ~", txt)))
  expect_true(any(grepl("^people: \\[\\]", txt)))
  s <- ph_read_sidecar(f)
  expect_setequal(names(s), ph_sidecar_fields)
  expect_equal(s$people, character(0))
  expect_null(s$place)
})

test_that("blank and NA fields are stored as empty, not as the string 'NA'", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L,
                   list(place = "", event = NA, people = c("", "  ", "Ada")))
  s <- ph_read_sidecar(file.path(ph_visit_dir(p$cfg, "top.jpg"),
                                 "visit-0001.yml"))
  expect_null(s$place)
  expect_null(s$event)
  expect_equal(s$people, "Ada")
})

test_that("visits for a photograph come back oldest first", {
  p <- make_project()
  rel <- "top.jpg"
  for (i in 1:3) ph_write_sidecar(p$cfg, rel, i, list(place = paste0("p", i)))
  v <- ph_visits_for(p$cfg, rel)
  expect_length(v, 3L)
  expect_equal(vapply(v, function(x) x$visit, integer(1)), 1:3)
  expect_equal(ph_last_visit(p$cfg, rel)$place, "p3")
  expect_equal(ph_visit_counts(p$cfg, rel), 3L)
})

test_that("audio_path is filled in only when there is audio", {
  p <- make_project()
  rel <- "top.jpg"
  ph_write_sidecar(p$cfg, rel, 1L, list(audio = "visit-0001.webm"))
  ph_write_sidecar(p$cfg, rel, 2L, list())
  v <- ph_visits_for(p$cfg, rel)
  expect_equal(basename(v[[1]]$audio_path), "visit-0001.webm")
  expect_true(is.na(v[[2]]$audio_path))
})

test_that("known people are gathered from every sidecar in the project", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(people = c("Ada", "Bo")))
  ph_write_sidecar(p$cfg, "Trips/x.png", 1L, list(people = c("Bo", "Cy")))
  expect_equal(ph_known_people(p$cfg), c("Ada", "Bo", "Cy"))
})

test_that("a corrupt sidecar is skipped, not fatal", {
  p <- make_project()
  rel <- "top.jpg"
  ph_write_sidecar(p$cfg, rel, 1L, list(place = "fine"))
  writeLines("this: [is: not: yaml", file.path(ph_visit_dir(p$cfg, rel),
                                               "visit-0002.yml"))
  v <- ph_visits_for(p$cfg, rel)
  expect_length(v, 1L)
  expect_equal(v[[1]]$place, "fine")
})
