# inst/shiny/app.R is the one file R CMD check never sources, and runApp()
# sources it with only library(phostor) attached, so only exports are visible.
# The suite itself runs inside the package namespace, where internals resolve.
# An app calling an unexported function would therefore pass every check and
# fail when a photograph is shown. These tests cover both sides: statically,
# and by driving the real server.

# first_path()/app_file()/namespace_file() live in helper-project.R, because
# test-preflight.R needs the same both-worlds path resolution.

# Every symbol used in call position, anywhere in the file.
called_functions <- function(path) {
  acc <- new.env(parent = emptyenv())
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    if (is.name(e[[1]])) assign(as.character(e[[1]]), TRUE, envir = acc)
    for (i in seq_along(e)) {
      # A call can hold missing arguments (x[, 1]), which error on access.
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(path)) walk(ex)
  ls(acc)
}

# The body of `output$<name> <- render*({ ... })`.
output_body <- function(path, name) {
  found <- NULL
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    if (length(e) >= 3L && is.name(e[[1]]) &&
        as.character(e[[1]]) %in% c("<-", "=")) {
      lhs <- e[[2]]
      if (is.call(lhs) && identical(as.character(lhs[[1]]), "$") &&
          identical(as.character(lhs[[2]]), "output") &&
          identical(as.character(lhs[[3]]), name)) {
        found <<- e[[3]]
      }
    }
    for (i in seq_along(e)) {
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(path)) walk(ex)
  found
}

# Does `e` contain the expression `rv$<field>` anywhere, outside isolate()?
reads_reactive <- function(e, field) {
  hit <- FALSE
  walk <- function(x) {
    if (!is.call(x)) return(invisible(NULL))
    if (is.name(x[[1]]) && identical(as.character(x[[1]]), "isolate")) {
      return(invisible(NULL))          # isolate() is the documented escape
    }
    if (identical(as.character(x[[1]]), "$") && length(x) >= 3L &&
        identical(as.character(x[[2]]), "rv") &&
        identical(as.character(x[[3]]), field)) {
      hit <<- TRUE
    }
    for (i in seq_along(x)) {
      tryCatch(if (!is.null(x[[i]])) walk(x[[i]]), error = function(...) NULL)
    }
    invisible(NULL)
  }
  walk(e)
  hit
}

test_that("every phostor function the app calls is exported", {
  app <- app_file(); ns <- namespace_file()
  skip_if(is.null(app) || is.null(ns), "app.R or NAMESPACE not reachable")

  # Reads the NAMESPACE file rather than the loaded namespace, so this behaves
  # identically whether R/ was sourced or the package was installed.
  exported <- sub("^export\\((.*)\\)$", "\\1",
                  grep("^export\\(", readLines(ns), value = TRUE))
  defined <- unlist(lapply(parse(app), function(e) {
    if (is.call(e) && length(e) >= 3L &&
        as.character(e[[1]]) %in% c("<-", "=") && is.name(e[[2]])) {
      as.character(e[[2]])
    }
  }))
  used <- setdiff(grep("^ph_", called_functions(app), value = TRUE), defined)

  expect_true(length(used) > 0L)          # the walk found something at all
  expect_equal(setdiff(used, exported), character(0))
})

test_that("the tree is not rebuilt to move the highlight", {
  app <- app_file(); skip_if(is.null(app))
  body <- output_body(app, "tree")
  expect_false(is.null(body))
  # Reading rv$current here would re-render the tree on every click. The
  # highlight is moved on the client instead (the ph_current handler).
  expect_false(reads_reactive(body, "current"))
})

test_that("no observer is created inside a loop", {
  app <- app_file(); skip_if(is.null(app))
  # One observeEvent per photograph is a known Shiny leak: they accumulate on
  # every render. Every click in this app goes through one global input.
  bad <- FALSE
  walk <- function(e, in_loop = FALSE) {
    if (!is.call(e)) return(invisible(NULL))
    head <- if (is.name(e[[1]])) as.character(e[[1]]) else ""
    if (in_loop && head %in% c("observe", "observeEvent")) bad <<- TRUE
    loop_now <- in_loop ||
      head %in% c("for", "while", "repeat", "lapply", "sapply", "vapply",
                  "Map", "mapply")
    for (i in seq_along(e)) {
      tryCatch(if (!is.null(e[[i]])) walk(e[[i]], loop_now),
               error = function(...) NULL)
    }
    invisible(NULL)
  }
  for (ex in parse(app)) walk(ex)
  expect_false(bad)
})

test_that("the app never writes outside the work directory", {
  app <- app_file(); skip_if(is.null(app))
  src <- readLines(app)
  # Every path the app builds is rooted at a cfg$*_dir. A literal photo_root
  # join in a writing call would break that.
  expect_false(any(grepl("file.path\\(cfg\\$photo_root", src)))
})

# --- driving the real server ------------------------------------------------

app_project <- function() {
  skip_on_os("windows")
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not(have_vips(), "vips not installed")
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  skip_if(is.null(app_file()), "app.R not reachable")
  make_project(render = TRUE)
}

# Points PHOSTOR_CONFIG at the project and returns the app directory, restoring
# the environment when the calling test finishes. Not a wrapper around
# testServer(): that captures its `expr` argument unevaluated, so forwarding an
# expression through another function evaluates it in the wrong frame.
app_dir_for <- function(p) {
  withr::local_envvar(c(PHOSTOR_CONFIG = ph_config_snapshot(p$cfg)),
                      .local_envir = parent.frame())
  dirname(app_file())
}

test_that("a scripted sitting records visits, revisits and the path", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  # The app opens on the first photograph in tree order, and starting a
  # sitting opens a visit for whatever is on screen. Drive from there.
  ord <- ph_tree_order(idx)
  rel_of <- function(id) idx$rel_path[match(id, idx$id)]
  a <- ord[1]; b <- ord[2]

  before <- fs_snapshot(p$photos)

  shiny::testServer(app_dir_for(p), {
    session$setInputs(start = 1)
    # The microphone is declined: the path is still recorded and every visit
    # still gets a sidecar. This is the synchronous half of the protocol.
    session$setInputs(mic_ready = list(ok = FALSE, why = "test"))

    session$setInputs(people = c("Nana Vera", "Uncle Stefan"),
                      place = "Elgol", event = "the camping trip",
                      when = "summer 1974")
    session$setInputs(photo_pick = b)
    session$setInputs(people = character(0), place = "somewhere else",
                      event = "", when = "")
    session$setInputs(photo_pick = a)     # a revisit
    session$setInputs(place = "Elgol, again")
    session$setInputs(stop_sitting = 1)
  })

  # 1. The photographs were not touched.
  expect_equal(fs_snapshot(p$photos), before)

  # 2. Three visits, with the revisit numbered 2 rather than overwriting 1.
  expect_equal(ph_visit_counts(p$cfg, rel_of(a)), 2L)
  expect_equal(ph_visit_counts(p$cfg, rel_of(b)), 1L)
  v1 <- ph_visits_for(p$cfg, rel_of(a))
  expect_equal(vapply(v1, function(x) x$visit, integer(1)), 1:2)
  expect_equal(v1[[1]]$people, c("Nana Vera", "Uncle Stefan"))
  expect_equal(v1[[1]]$place, "Elgol")
  expect_equal(v1[[1]]$when, "summer 1974")
  # The revisit is a separate record; the first is unchanged.
  expect_equal(v1[[2]]$place, "Elgol, again")

  # 3. The path records the route, and ends after the last visit is written.
  sess <- ph_sessions(p$cfg)
  expect_equal(nrow(sess), 1L)
  path <- ph_path_read(sess$dir[1])
  expect_equal(path$event[1], "start")
  expect_equal(path$event[nrow(path)], "end")
  expect_equal(path$rel_path[path$event == "leave"],
               c(rel_of(a), rel_of(b), rel_of(a)))
  expect_equal(path$visit[path$event == "leave"], c("1", "1", "2"))

  # 4. The playlist replays that same route.
  pl <- ph_playlist(p$cfg, sess$dir[1])
  expect_equal(pl$rel_path, c(rel_of(a), rel_of(b), rel_of(a)))
  expect_equal(pl$visit, c(1L, 1L, 2L))
})

test_that("a visit's audio is assembled from the chunks the browser sends", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  ord <- ph_tree_order(idx)
  rel_of <- function(id) idx$rel_path[match(id, idx$id)]
  a <- ord[1]; b <- ord[2]
  set.seed(7)    # seeded here; the payload stands in for an Opus stream
  payload <- lapply(1:3, function(i) as.raw(sample(0:255, 256, replace = TRUE)))

  before <- fs_snapshot(p$photos)

  shiny::testServer(app_dir_for(p), {
    session$setInputs(start = 1)
    # Arming the microphone opens the first visit of the sitting: key "v1",
    # because open_visit() is what advances the counter.
    session$setInputs(mic_ready = list(ok = TRUE, mime = "audio/webm"))

    for (i in seq_along(payload)) {
      session$setInputs(audio_chunk = list(
        key = "v1", seq = i, b64 = base64enc::base64encode(payload[[i]]),
        last = FALSE))
    }
    # A chunk from a recorder the server no longer knows must be dropped, not
    # appended to another visit's take. This is what makes the start, stop and
    # discard races safe.
    session$setInputs(audio_chunk = list(
      key = "v999", seq = 99, b64 = base64enc::base64encode(as.raw(1:64)),
      last = TRUE))

    session$setInputs(photo_pick = b)        # closes v1, awaits the browser
    session$setInputs(visit_done = list(key = "v1", at = 1))
    session$setInputs(stop_sitting = 1)
    session$setInputs(visit_done = list(key = "v2", at = 2))
  })

  expect_equal(fs_snapshot(p$photos), before)

  v <- ph_visits_for(p$cfg, rel_of(a))
  expect_length(v, 1L)
  expect_equal(v[[1]]$audio, "visit-0001.webm")
  got <- readBin(v[[1]]$audio_path, "raw", n = 1e6)
  expect_identical(got, unlist(payload))    # exactly the bytes, in order
  # Nothing was left half-written, and the stray chunk landed nowhere.
  expect_equal(ph_orphan_audio(p$cfg), character(0))
})

test_that("browsing without a sitting records nothing at all", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = idx$id[1])
    session$setInputs(photo_pick = idx$id[2])
    session$setInputs(photo_pick = idx$id[1])
  })
  expect_equal(nrow(ph_sessions(p$cfg)), 0L)
  expect_equal(sum(ph_visit_counts(p$cfg, idx$rel_path)), 0L)
})

test_that("a visit too brief to hold a conversation leaves only a path row", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = idx$id[1])
    session$setInputs(start = 1)
    session$setInputs(mic_ready = list(ok = FALSE, why = "test"))
    # No audio, nothing typed, and no time passes under testServer.
    session$setInputs(photo_pick = idx$id[2])
    session$setInputs(stop_sitting = 1)
  })
  expect_equal(sum(ph_visit_counts(p$cfg, idx$rel_path)), 0L)
  path <- ph_path_read(ph_sessions(p$cfg)$dir[1])
  expect_true("leave" %in% path$event)
})

test_that("something typed is kept however brief the visit", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = idx$id[1])
    session$setInputs(start = 1)
    session$setInputs(mic_ready = list(ok = FALSE, why = "test"))
    session$setInputs(people = "Ada")
    session$setInputs(photo_pick = idx$id[2])
    session$setInputs(stop_sitting = 1)
  })
  expect_equal(ph_visit_counts(p$cfg, rel), 1L)
  expect_equal(ph_visits_for(p$cfg, rel)[[1]]$people, "Ada")
})

test_that("a closed browser still writes the visit in progress", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  rel <- idx$rel_path[1]
  shiny::testServer(app_dir_for(p), {
    session$setInputs(photo_pick = idx$id[1])
    session$setInputs(start = 1)
    session$setInputs(mic_ready = list(ok = FALSE, why = "test"))
    session$setInputs(place = "half-said")
    # No stop_sitting, no navigation: the tab simply closes.
  })
  expect_equal(ph_visit_counts(p$cfg, rel), 1L)
  expect_equal(ph_visits_for(p$cfg, rel)[[1]]$place, "half-said")
})

test_that("the path reads in the order photographs were viewed", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  ord <- ph_tree_order(idx)
  set.seed(11)
  chunk <- function() base64enc::base64encode(as.raw(sample(0:255, 128, TRUE)))

  shiny::testServer(app_dir_for(p), {
    session$setInputs(start = 1)
    session$setInputs(mic_ready = list(ok = TRUE, mime = "audio/webm"))
    session$setInputs(audio_chunk = list(key = "v1", seq = 1, b64 = chunk(),
                                         last = FALSE))
    session$setInputs(photo_pick = ord[2])
    session$setInputs(audio_chunk = list(key = "v2", seq = 2, b64 = chunk(),
                                         last = FALSE))
    session$setInputs(photo_pick = ord[3])
    # The browser flushes the first two recorders here, after both
    # photographs were left.
    session$setInputs(visit_done = list(key = "v1", at = 1))
    session$setInputs(visit_done = list(key = "v2", at = 2))
    session$setInputs(stop_sitting = 1)
    session$setInputs(visit_done = list(key = "v3", at = 3))
  })

  path <- ph_path_read(ph_sessions(p$cfg)$dir[1])
  ev <- path$event
  # An audio visit finalizes asynchronously, so a `leave` written at finalize
  # time would land after the next photograph's `show`. It is written when the
  # photograph is left, so show and leave alternate.
  expect_equal(ev, c("start", rep(c("show", "leave"), 3), "end"))
  expect_equal(path$rel_path[ev == "show"], path$rel_path[ev == "leave"])
  expect_equal(ev[length(ev)], "end")
})

# --- the browser half: what the server can be held to ------------------------

test_that("the app exposes DOM state hooks for the browser tests", {
  app <- app_file(); skip_if(is.null(app))
  src <- paste(readLines(app), collapse = "\n")
  # Playwright waits on state rather than sleeping. These three hooks are the
  # contract the specs in tests/browser/ are written against.
  for (hook in c("phMic", "phVisit", "phChunks")) {
    expect_match(src, hook, fixed = TRUE)
  }
  # ...and the ids those specs click.
  for (id in c("ph-mic-panel", "ph-mic-run", "ph-mic-test", "ph-mic-close",
               "ph-mic-device", "ph-level-fill", "ph-test-audio")) {
    expect_match(src, id, fixed = TRUE)
  }
})

test_that("arming retries once before giving up", {
  app <- app_file(); skip_if(is.null(app))
  src <- paste(readLines(app), collapse = "\n")
  # On macOS the system grant often lands just after the first rejection, so
  # one retry recovers it. Once only, and only for the two errors that behave
  # that way.
  expect_match(src, "NotFoundError", fixed = TRUE)
  expect_match(src, "arm(true)", fixed = TRUE)
  expect_match(src, "function arm(isRetry)", fixed = TRUE)
})

test_that("a failed microphone reports a remedy, not just the error name", {
  p <- app_project()
  idx <- ph_read_index(p$cfg)
  shiny::testServer(app_dir_for(p), {
    session$setInputs(browser_env = list(
      secure = TRUE, hasMedia = TRUE, mimes = list("audio/webm;codecs=opus"),
      mime = "audio/webm;codecs=opus",
      ua = "Mozilla/5.0 (Macintosh; rv:141.0) Gecko/20100101 Firefox/141.0"))
    session$setInputs(start = 1)
    # Permission granted in the page, refused by macOS underneath.
    session$setInputs(mic_ready = list(ok = FALSE, why = "NotFoundError"))

    msg <- output$sitting_info
    expect_match(msg, "Firefox")
    expect_match(msg, "Microphone")
    expect_false(grepl("^no microphone", msg))
    # The sitting continues: the path is still recorded.
    expect_true(nrow(ph_sessions(p$cfg)) == 1L)

    # There is a way to retry once the permission is fixed.
    session$setInputs(mic_retry = 1)
    session$setInputs(mic_ready = list(ok = TRUE, mime = "audio/webm"))
    expect_match(output$sitting_info, "sitting")
  })
})

test_that("a browser that cannot record is reported before a sitting starts", {
  p <- app_project()
  shiny::testServer(app_dir_for(p), {
    session$setInputs(browser_env = list(
      secure = TRUE, hasMedia = TRUE, mimes = list("audio/mp4"), mime = NULL,
      ua = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"))
    html <- as.character(output$browser_banner$html)
    expect_match(html, "cannot record")
    expect_match(html, "Chrome or Firefox")
  })
})

test_that("a capable browser raises no banner", {
  p <- app_project()
  shiny::testServer(app_dir_for(p), {
    session$setInputs(browser_env = list(
      secure = TRUE, hasMedia = TRUE, mimes = list("audio/webm;codecs=opus"),
      mime = "audio/webm;codecs=opus",
      ua = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36"))
    # renderUI() returning NULL yields no html.
    expect_false(any(grepl("cannot record",
                           as.character(output$browser_banner$html))))
  })
})

test_that("the check establishes which browser later advice names", {
  p <- app_project()
  shiny::testServer(app_dir_for(p), {
    # The check is where the browser identifies itself. MockShinySession does
    # not record custom messages, so assert the consequence: later advice names
    # the browser the check recorded.
    session$setInputs(mic_check = list(
      ok = FALSE, why = "NotFoundError", secure = TRUE, devices = list(),
      mimes = list("audio/webm;codecs=opus"),
      ua = "Mozilla/5.0 (Macintosh; rv:141.0) Gecko/20100101 Firefox/141.0"))
    session$setInputs(start = 1)
    session$setInputs(mic_ready = list(ok = FALSE, why = "NotFoundError"))
    expect_match(output$sitting_info, "Firefox")
  })
})

test_that("pause and a failed microphone are different states", {
  app <- app_file(); skip_if(is.null(app))
  src <- paste(readLines(app), collapse = "\n")
  # Pausing offers Resume; a microphone that never opened offers a retry.
  expect_match(src, "Try the microphone again", fixed = TRUE)
  expect_match(src, "rv$paused", fixed = TRUE)
})
