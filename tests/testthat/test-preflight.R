test_that("preflight and SystemRequirements never drift apart", {
  f <- description_file()
  skip_if(is.null(f), "DESCRIPTION not reachable")
  sysreq <- paste(read.dcf(f)[1, "SystemRequirements"], collapse = " ")
  for (tool in c(names(ph_pf_required), names(ph_pf_optional))) {
    expect_match(sysreq, tool, fixed = TRUE,
                 info = paste("preflight checks", tool,
                              "but DESCRIPTION does not mention it"))
  }
})

test_that("preflight claims no tool phostor does not actually run", {
  # A checker that reports on tools nothing calls is a checker nobody trusts.
  app <- app_file()
  skip_if(is.null(app), "app.R not reachable")
  src <- c(package_source(), readLines(app))
  for (tool in c(names(ph_pf_required), names(ph_pf_optional))) {
    expect_true(any(grepl(paste0("\"", tool, "\""), src, fixed = TRUE)),
                info = paste("preflight checks", tool, "but nothing calls it"))
  }
})

test_that("preflight reports without throwing", {
  expect_type(suppressMessages(ph_preflight(quiet = TRUE)), "logical")
})

test_that("preflight reports the browsers, and which one would open", {
  msgs <- paste(capture_messages(ph_preflight()), collapse = "\n")
  expect_match(msgs, "browsers")
  # The trap that cost a sitting: the system default was a browser macOS had
  # denied the microphone, and the app opened there without saying so.
  expect_match(msgs, "default")
  expect_match(msgs, "Microphone")     # names the settings pane to check
  expect_match(msgs, "quit and reopen")
})

test_that("a browser that cannot record is named as such", {
  # Safari records fragmented MP4, whose chunks do not concatenate.
  expect_false(ph_browser_records("Safari"))
  expect_true(ph_browser_records("Chrome"))
  expect_true(ph_browser_records("Firefox"))
  expect_true(is.na(ph_browser_records(NA_character_)))
  if ("Safari" %in% names(ph_browser_apps[dir.exists(ph_browser_apps)])) {
    msgs <- paste(capture_messages(ph_preflight()), collapse = "\n")
    expect_match(msgs, "cannot record")
  }
})
