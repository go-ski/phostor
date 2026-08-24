# The recording half lives in the browser, where R can see nothing. What R owns
# is the wording -- turning an error name into something a room can act on --
# and that is what these tests pin down.

test_that("every known error name gets specific advice, not a fallback", {
  fallback <- ph_mic_advice("SomethingNobodyHasSeen", "Chrome")
  for (why in ph_mic_errors) {
    a <- ph_mic_advice(why, "Chrome")
    expect_true(nzchar(a), info = why)
    expect_false(identical(a, fallback), info = why)
    # Advice, not a diagnosis: every one must tell the reader to do something.
    expect_match(a, "Open|Click|Quit|Use|check|switch", info = why)
  }
})

test_that("NotFoundError names the real remedy -- the failure that prompted this", {
  # macOS had denied Firefox microphone access at the system level, so
  # getUserMedia rejected with NotFoundError. The old message said only
  # "no microphone (NotFoundError)", which is not actionable by anyone.
  a <- ph_mic_advice("NotFoundError", "Firefox")
  expect_match(a, "Firefox")
  expect_match(a, "Microphone", fixed = TRUE)
  # The step everyone misses: macOS applies the grant only on relaunch.
  expect_match(a, "quit .* completely and open it again")
})

test_that("the browser is named in the advice, or referred to neutrally", {
  expect_match(ph_mic_advice("NotAllowedError", "Chrome"), "Chrome")
  expect_match(ph_mic_advice("NotAllowedError", NULL), "your browser")
  expect_match(ph_mic_advice("NotAllowedError", NA_character_), "your browser")
  expect_match(ph_mic_advice("NotAllowedError", ""), "your browser")
})

test_that("advice distinguishes the four things that actually go wrong", {
  expect_match(ph_mic_advice("NotReadableError"), "Zoom|Teams|Webex")
  expect_match(ph_mic_advice("insecure"), "127\\.0\\.0\\.1|localhost")
  expect_match(ph_mic_advice("nocodec"), "Chrome or Firefox")
  expect_match(ph_mic_advice("nocodec"), "Safari")
  expect_match(ph_mic_advice("NotAllowedError"), "address bar")
})

test_that("aliases of the same failure give the same advice", {
  expect_equal(ph_mic_advice("NotFoundError", "Chrome"),
               ph_mic_advice("DevicesNotFoundError", "Chrome"))
  expect_equal(ph_mic_advice("NotAllowedError", "Chrome"),
               ph_mic_advice("PermissionDeniedError", "Chrome"))
  expect_equal(ph_mic_advice("NotReadableError"), ph_mic_advice("AbortError"))
})

test_that("an unknown or empty reason still says something useful", {
  a <- ph_mic_advice("WeirdError", "Chrome")
  expect_match(a, "WeirdError")          # do not hide what was reported
  expect_match(a, "Microphone", fixed = TRUE)
  expect_match(ph_mic_advice(""), "no reason")
  expect_match(ph_mic_advice(NULL), "no reason")
})

test_that("browsers are identified from their user agent", {
  ff <- "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:141.0) Gecko/20100101 Firefox/141.0"
  cr <- "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
  sa <- "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  ed <- paste0(cr, " Edg/151.0.0.0")
  expect_equal(ph_browser_name(ff), "Firefox")
  expect_equal(ph_browser_name(cr), "Chrome")
  # Every Chromium browser carries "Safari/", and Edge carries "Chrome/" too,
  # so the order the patterns are tried in is load-bearing.
  expect_equal(ph_browser_name(sa), "Safari")
  expect_equal(ph_browser_name(ed), "Microsoft Edge")
  expect_true(is.na(ph_browser_name("")))
  expect_true(is.na(ph_browser_name(NULL)))
  expect_true(is.na(ph_browser_name("curl/8.4.0")))
})

test_that("only browsers whose chunks concatenate are supported", {
  # Chunks from one MediaRecorder concatenate into a valid WebM. Safari
  # produces fragmented MP4, which does not, so it is refused by name.
  expect_true(ph_browser_records("Chrome"))
  expect_true(ph_browser_records("Firefox"))
  expect_false(ph_browser_records("Safari"))
})

test_that("the default browser is reported or honestly unknown", {
  d <- ph_browser_default()
  expect_length(d, 1L)
  expect_type(d, "character")
  if (!identical(Sys.info()[["sysname"]], "Darwin")) expect_true(is.na(d))
})

test_that("the launcher prefers a browser that can record", {
  l <- ph_browser_launcher()
  expect_true(is.list(l))
  expect_true(all(c("name", "launch") %in% names(l)))
  if (!is.na(l$name)) {
    expect_true(isTRUE(ph_browser_records(l$name)),
                info = "ph_app() must not default to a browser that cannot record")
    expect_type(l$launch, "closure")
  }
})

test_that("an unknown browser falls back rather than failing", {
  expect_warning(l <- ph_browser_launcher("Netscape Navigator"), "not found")
  expect_null(l$launch)
})

test_that("an explicit browser choice is honoured when it exists", {
  have <- ph_browser_apps[dir.exists(ph_browser_apps)]
  skip_if(!length(have), "no known browsers installed")
  l <- ph_browser_launcher(names(have)[[1]])
  expect_equal(l$name, names(have)[[1]])
  expect_type(l$launch, "closure")
})
