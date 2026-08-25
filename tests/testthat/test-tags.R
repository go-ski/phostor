test_that("tags round trip through their own file", {
  p <- make_project()
  out <- ph_write_tags(p$cfg, "top.jpg",
                       list(people = c("Nana Vera", "Uncle Stefan"),
                            place = "Elgol, Isle of Skye",
                            event = "the 1974 camping trip",
                            when = "summer 1974"))
  expect_true(file.exists(out))
  expect_equal(basename(out), "tags.yml")

  t <- ph_tags(p$cfg, "top.jpg")
  expect_equal(t$people, c("Nana Vera", "Uncle Stefan"))
  expect_equal(t$place, "Elgol, Isle of Skye")
  expect_equal(t$event, "the 1974 camping trip")
  expect_equal(t$when, "summer 1974")
})

test_that("a photograph with nothing recorded has empty tags", {
  p <- make_project()
  t <- ph_tags(p$cfg, "top.jpg")
  expect_equal(t$people, character(0))
  expect_equal(t$place, "")
  expect_equal(t$event, "")
  expect_equal(t$when, "")
  expect_false(file.exists(file.path(ph_visit_dir(p$cfg, "top.jpg"), "tags.yml")))
})

test_that("nothing is written for a photograph with no tags", {
  p <- make_project()
  # Paging past a photograph must not leave a file behind on it.
  expect_true(is.na(ph_write_tags(p$cfg, "top.jpg", list())))
  expect_false(file.exists(file.path(ph_visit_dir(p$cfg, "top.jpg"), "tags.yml")))
  expect_true(is.na(ph_write_tags(p$cfg, "top.jpg",
                                  list(place = "  ", people = c("", " ")))))
})

test_that("clearing a field that had a value sticks", {
  p <- make_project()
  ph_write_tags(p$cfg, "top.jpg", list(place = "Elgol", people = "Vera"))
  expect_equal(ph_tags(p$cfg, "top.jpg")$place, "Elgol")

  # Emptied entirely: the file must still be written, or the old values would
  # come back on the next read.
  ph_write_tags(p$cfg, "top.jpg", list())
  t <- ph_tags(p$cfg, "top.jpg")
  expect_equal(t$place, "")
  expect_equal(t$people, character(0))
})

test_that("tags are read from the last visit until a tags.yml exists", {
  p <- make_project()
  # What a project recorded before tags had a file of their own.
  ph_write_sidecar(p$cfg, "top.jpg", 1L,
                   list(people = "Vera", place = "Elgol", event = "the trip",
                        when = "1974"))
  t <- ph_tags(p$cfg, "top.jpg")
  expect_equal(t$people, "Vera")
  expect_equal(t$place, "Elgol")
  expect_equal(t$when, "1974")

  # Once written, the photograph's own file wins over the older visit.
  ph_write_tags(p$cfg, "top.jpg", list(place = "Camasunary"))
  expect_equal(ph_tags(p$cfg, "top.jpg")$place, "Camasunary")
  expect_equal(ph_tags(p$cfg, "top.jpg")$people, character(0))
  # And the visit sidecar it migrated from is untouched.
  expect_equal(ph_last_visit(p$cfg, "top.jpg")$place, "Elgol")
})

test_that("the newest visit is the one tags migrate from", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(place = "first guess"))
  ph_write_sidecar(p$cfg, "top.jpg", 2L, list(place = "corrected later"))
  expect_equal(ph_tags(p$cfg, "top.jpg")$place, "corrected later")
})

test_that("a photograph path with a space keeps its own tags", {
  p <- make_project()
  ph_write_tags(p$cfg, "Trips/Skye/a b.jpg", list(place = "Skye"))
  expect_equal(ph_tags(p$cfg, "Trips/Skye/a b.jpg")$place, "Skye")
  expect_equal(ph_tags(p$cfg, "top.jpg")$place, "")
})

test_that("tags.yml is invisible to everything that walks visits", {
  p <- make_project()
  ph_write_tags(p$cfg, "top.jpg", list(place = "Elgol"))
  dir <- ph_visit_dir(p$cfg, "top.jpg")

  # It must not take a visit number, show in the badge, or appear as a visit.
  expect_equal(ph_visit_numbers(dir), integer(0))
  expect_equal(ph_next_visit(p$cfg, "top.jpg"), 1L)
  expect_equal(ph_visit_counts(p$cfg, "top.jpg"), 0L)
  expect_equal(length(ph_visits_for(p$cfg, "top.jpg")), 0L)
})

test_that("a corrupt tags.yml falls back rather than raising", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(place = "Elgol"))
  writeLines("{{ not yaml", file.path(ph_visit_dir(p$cfg, "top.jpg"), "tags.yml"))
  # A sitting must not stop because a file was hand-edited badly.
  expect_equal(ph_tags(p$cfg, "top.jpg")$place, "Elgol")
})

test_that("tags are cleaned into one shape however they arrive", {
  t <- ph_tags_clean(list(place = "  Elgol ", people = c("Vera", "", " Stefan"),
                          when = NA))
  expect_equal(t$people, c("Vera", "Stefan"))
  expect_equal(t$place, "Elgol")
  expect_equal(t$when, "")
  expect_equal(t$event, "")

  empty <- ph_tags_clean(list())
  expect_equal(empty$people, character(0))
  expect_equal(empty$place, "")

  # A hand-edited file can give people as a yaml list rather than a vector.
  expect_equal(ph_tags_clean(list(people = list("Vera", "Stefan")))$people,
               c("Vera", "Stefan"))
})

test_that("hand-edited tags.yml is read back as written", {
  p <- make_project()
  dir <- ph_visit_dir(p$cfg, "top.jpg", create = TRUE)
  writeLines(c("photo: top.jpg", "people:", "- Vera", "place: Elgol",
               "event: ~", "when: ~"), file.path(dir, "tags.yml"))
  t <- ph_tags(p$cfg, "top.jpg")
  expect_equal(t$people, "Vera")
  expect_equal(t$place, "Elgol")
  expect_equal(t$event, "")
})

test_that("autocomplete sees names typed outside a sitting", {
  p <- make_project()
  ph_write_tags(p$cfg, "top.jpg", list(people = "Nana Vera"))
  ph_write_sidecar(p$cfg, "Trips/Skye/a b.jpg", 1L,
                   list(people = "Uncle Stefan"))
  # Both sources, because a name typed outside a sitting only ever reaches
  # tags.yml and a name from before this only ever reached a sidecar.
  expect_equal(ph_known_people(p$cfg), c("Nana Vera", "Uncle Stefan"))
})
