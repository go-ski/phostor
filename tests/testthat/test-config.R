test_that("the work directory is the directory config.yml is in", {
  work <- tempfile("work-")
  quiet_init(work, photo_root = tempfile("photos-"))
  expect_true(file.exists(file.path(work, "config.yml")))
  cfg <- ph_config(work)
  expect_equal(cfg$work_dir, ph_resolve_path(work))
  expect_equal(cfg$index_file, file.path(cfg$work_dir, "index.tsv"))
  expect_equal(cfg$sidecar_dir, file.path(cfg$work_dir, "sidecars"))
  # There is no work_dir key that could disagree with the actual location.
  expect_false("work_dir" %in% names(ph_config_defaults()))
})

test_that("work_dir may not overlap photo_root", {
  photos <- tempfile("photos-")
  dir.create(photos, recursive = TRUE)

  # the same directory
  expect_error(quiet_init(photos, photo_root = photos), "must not be")
  # work inside photos
  expect_error(quiet_init(file.path(photos, "w"), photo_root = photos),
               "must not be")
  # photos inside work
  work <- tempfile("work-")
  dir.create(file.path(work, "inner"), recursive = TRUE)
  expect_error(quiet_init(work, photo_root = file.path(work, "inner")),
               "must not be")
})

test_that("overlap is caught on load, not only on init", {
  photos <- tempfile("photos-")
  dir.create(photos, recursive = TRUE)
  work <- tempfile("work-")
  quiet_init(work, photo_root = tempfile("elsewhere-"))
  # Hand-edit the config into an unsafe state, as a user could.
  lines <- readLines(file.path(work, "config.yml"))
  lines <- ph_template_set(lines, "photo_root", dirname(ph_resolve_path(work)))
  writeLines(lines, file.path(work, "config.yml"))
  expect_error(ph_config(work), "must not be")
})

test_that("overlap detection folds case where the filesystem does", {
  # ph_paths_overlap() is the guard; tested directly so the result does not
  # depend on which filesystem tempdir() is on.
  a <- "/Volumes/Photo/lib"
  expect_true(ph_paths_overlap(a, a))
  expect_true(ph_paths_overlap(a, "/Volumes/Photo"))
  expect_true(ph_paths_overlap("/Volumes/Photo", a))
  expect_false(ph_paths_overlap(a, "/Volumes/Photograph"))
  expect_false(ph_paths_overlap("/a/b", "/c/d"))
  expect_false(ph_paths_overlap(NULL, a))
  expect_false(ph_paths_overlap("", a))

  expect_true(ph_path_under("/a/b/c", "/a/b"))
  expect_true(ph_path_under("/a/b", "/a/b"))
  expect_false(ph_path_under("/a/b", "/a/b/c"))

  # A case-differing prefix is one directory on APFS and two elsewhere, so the
  # answer must follow the filesystem rather than the string.
  if (ph_fs_case_insensitive(tempdir())) {
    expect_true(ph_paths_overlap(file.path(tempdir(), "Photo"),
                                 file.path(tempdir(), "photo")))
  }
})

test_that("an unknown config key is named rather than silently defaulted", {
  work <- tempfile("work-")
  quiet_init(work, photo_root = tempfile("photos-"))
  f <- file.path(work, "config.yml")
  writeLines(c(readLines(f), "thumb_sze: 100"), f)
  expect_warning(ph_config(work), "thumb_sze")
  expect_warning(ph_config(work), "thumb_size")
})

test_that("invalid values are all reported at once", {
  work <- tempfile("work-")
  quiet_init(work, photo_root = tempfile("photos-"))
  f <- file.path(work, "config.yml")
  l <- readLines(f)
  l <- ph_template_set(l, "display_size", 10L)
  l <- ph_template_set(l, "thumb_size", 99999L)
  writeLines(l, f)
  err <- tryCatch(ph_config(work), error = conditionMessage)
  expect_match(err, "display_size")
  expect_match(err, "thumb_size")
})

test_that("an empty or non-mapping config is handled without an error", {
  work <- tempfile("work-")
  dir.create(work, recursive = TRUE)
  writeLines(character(0), file.path(work, "config.yml"))
  expect_silent(cfg <- ph_config(work))
  expect_equal(cfg$title, ph_config_defaults()$title)

  writeLines("just a scalar", file.path(work, "config.yml"))
  expect_error(ph_config(work), "not a YAML mapping")
})

test_that("the template keeps its comments when fields are filled in", {
  work <- tempfile("work-")
  quiet_init(work, photo_root = "/tmp/nowhere-xyz", display_size = 1024L)
  txt <- readLines(file.path(work, "config.yml"))
  expect_true(any(grepl("^#", txt)))
  expect_true(any(grepl("^photo_root: /tmp/nowhere-xyz", txt)))
  expect_true(any(grepl("^display_size: 1024", txt)))
  expect_equal(ph_config(work)$display_size, 1024L)
})

test_that("re-init leaves an existing config alone unless told otherwise", {
  work <- tempfile("work-")
  quiet_init(work, photo_root = "/tmp/a-xyz")
  quiet_init(work, photo_root = "/tmp/b-xyz")
  expect_equal(ph_config(work)$photo_root, ph_resolve_path("/tmp/a-xyz"))
  quiet_init(work, photo_root = "/tmp/b-xyz", overwrite = TRUE)
  expect_equal(ph_config(work)$photo_root, ph_resolve_path("/tmp/b-xyz"))
  expect_true(length(list.files(file.path(work, "config.history"))) >= 1)
})

test_that("the resolved snapshot re-reads without warning", {
  work <- tempfile("work-")
  quiet_init(work, photo_root = tempfile("photos-"))
  cfg <- ph_config(work)
  out <- ph_config_snapshot(cfg)
  expect_true(file.exists(out))
  expect_silent(cfg2 <- ph_config(out))
  expect_equal(cfg2$title, cfg$title)
})
