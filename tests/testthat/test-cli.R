test_that("usage names every command the dispatcher handles", {
  msgs <- capture_messages(ph_cli_usage())
  txt <- paste(msgs, collapse = "\n")
  # The switch() in ph_cli() and the usage text are two statements of the same
  # list, and a command documented but not dispatched is worse than neither.
  for (cmd in c("init", "index", "render", "app", "go", "status", "preflight")) {
    expect_match(txt, paste0("\\b", cmd, "\\b"))
  }
})

test_that("no argument, and --help, both print usage", {
  expect_message(ph_cli(character(0)), "usage:")
  expect_message(ph_cli("--help"), "usage:")
})

test_that("an unknown command is named rather than silently ignored", {
  msgs <- capture_messages(ph_cli("wander"))
  expect_match(paste(msgs, collapse = "\n"), "unknown command 'wander'")
})

test_that("flags are parsed off the argument vector", {
  expect_equal(ph_flag_value(c("index", "--work", "/tmp/x"), "--work"), "/tmp/x")
  expect_null(ph_flag_value(c("index"), "--work"))
  # A flag with nothing after it must not read off the end of the vector.
  expect_null(ph_flag_value(c("index", "--work"), "--work"))
  expect_equal(ph_flag_value(c("index"), "--work", "fallback"), "fallback")
  expect_true(ph_has_flag(c("render", "--force"), "--force"))
  expect_false(ph_has_flag(c("render"), "--force"))
})

test_that("init and status run end to end from the command line", {
  photos <- make_photos()
  work <- tempfile("work-")
  suppressMessages(ph_cli(c("init", "--work", work, "--photos", photos)))
  expect_true(file.exists(file.path(work, "config.yml")))
  expect_equal(ph_config(work)$photo_root, ph_resolve_path(photos))

  suppressMessages(ph_cli(c("index", "--work", work, "--quiet")))
  expect_equal(nrow(ph_read_index(ph_config(work))), 4L)

  out <- suppressMessages(ph_cli(c("status", "--work", work)))
  expect_equal(out$photos, 4L)
  expect_equal(out$sittings, 0L)
  expect_equal(out$visits, 0L)
})

test_that("status counts what a project holds", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(people = c("Ada", "Bo")))
  ph_write_sidecar(p$cfg, "top.jpg", 2L, list(people = "Cy"))
  ph_path_new(p$cfg)
  out <- suppressMessages(ph_status(p$cfg))
  expect_equal(out$visits, 2L)
  expect_equal(out$people, 3L)
  expect_equal(out$sittings, 1L)
  expect_equal(out$orphans, 0L)
})
