test_that("every photograph gets a display copy and a thumbnail", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  idx <- ph_read_index(p$cfg)
  for (id in idx$id) {
    expect_true(file.exists(file.path(p$cfg$display_dir, paste0(id, ".jpg"))))
    expect_true(file.exists(file.path(p$cfg$thumb_dir, paste0(id, ".jpg"))))
  }
})

test_that("rendering is idempotent and re-renders only what changed", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  again <- suppressMessages(ph_render_all(p$cfg, quiet = TRUE))
  expect_equal(again$rendered, 0L)
  expect_equal(again$skipped, 8L)     # 4 photographs, display + thumb each

  # A touched source is picked up: the check is source mtime, not existence.
  idx <- ph_read_index(p$cfg)
  Sys.setFileTime(file.path(p$photos, "top.jpg"), Sys.time() + 5)
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  third <- suppressMessages(ph_render_all(p$cfg, quiet = TRUE))
  expect_equal(third$rendered, 2L)
  expect_equal(third$skipped, 6L)
})

test_that("force re-renders everything", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  out <- suppressMessages(ph_render_all(p$cfg, force = TRUE, quiet = TRUE))
  expect_equal(out$rendered, 8L)
  expect_equal(out$skipped, 0L)
})

test_that("a PNG is rendered to a JPEG the browser can show", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  idx <- ph_read_index(p$cfg)
  id <- idx$id[idx$rel_path == "Trips/x.png"]
  f <- file.path(p$cfg$display_dir, paste0(id, ".jpg"))
  expect_true(file.exists(f))
  # JPEG magic: rendering, not copying, is what makes HEIC and TIFF displayable.
  expect_equal(readBin(f, "raw", 3), as.raw(c(0xff, 0xd8, 0xff)))
})

test_that("the display copy is bounded by display_size", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  skip_if_not(nzchar(Sys.which("exiftool")), "exiftool not installed")
  photos <- make_photos()
  work <- tempfile("work-")
  quiet_init(work, photo_root = photos, display_size = 256L,
             thumb_size = 32L)
  cfg <- ph_config(work)
  suppressMessages(ph_index(cfg, quiet = TRUE))
  suppressMessages(ph_render_all(cfg, quiet = TRUE))
  idx <- ph_read_index(cfg)
  id <- idx$id[idx$rel_path == "top.jpg"]   # the one fixture larger than 256
  dims <- system2("exiftool", c("-T", "-ImageWidth", "-ImageHeight",
                                shQuote(file.path(cfg$display_dir,
                                                  paste0(id, ".jpg")))),
                  stdout = TRUE)
  wh <- as.integer(strsplit(dims, "\t")[[1]])
  expect_lte(max(wh), 256L)
})

test_that("an unreadable source is reported, not fatal", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project()
  # A file with a photograph's name and none of its bytes.
  writeLines("not an image", file.path(p$photos, "broken.jpg"))
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  out <- suppressMessages(ph_render_all(p$cfg, quiet = TRUE))
  expect_equal(out$failed, 1L)
  expect_gt(out$rendered, 0L)
})

test_that("rendering without a catalogue says so rather than failing", {
  photos <- make_photos()
  work <- tempfile("work-")
  quiet_init(work, photo_root = photos)
  expect_message(ph_render_all(ph_config(work)), "ph_index")
})

test_that("web formats are recognised for what a browser can display", {
  expect_true(ph_is_web_format("a.JPG"))
  expect_true(ph_is_web_format("dir/a.png"))
  expect_false(ph_is_web_format("a.heic"))
  expect_false(ph_is_web_format("a.tif"))
  expect_false(ph_is_web_format("noext"))
})
