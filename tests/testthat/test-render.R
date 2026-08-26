# Where a render should be, spelled out rather than via ph_render_rel(), so a
# mistake in that function cannot agree with itself here.
render_at <- function(cfg, rel_path, kind) {
  root <- if (identical(kind, "display")) cfg$display_dir else cfg$thumb_dir
  size <- if (identical(kind, "display")) cfg$display_size else cfg$thumb_size
  file.path(root, as.integer(size), paste0(rel_path, ".jpg"))
}

test_that("every photograph gets a display copy and a thumbnail", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  idx <- ph_read_index(p$cfg)
  for (rel in idx$rel_path) {
    expect_true(file.exists(render_at(p$cfg, rel, "display")), label = rel)
    expect_true(file.exists(render_at(p$cfg, rel, "thumb")), label = rel)
  }
})

test_that("a render is named after its photograph, under its size", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  # The mirror survives a nested directory, a space and an ampersand.
  for (rel in c("top.jpg", "Trips/Skye/a b.jpg", "Trips/Skye/c&d.jpg")) {
    expect_true(file.exists(render_at(p$cfg, rel, "display")), label = rel)
  }
  expect_equal(ph_render_rel(p$cfg, "Trips/Skye/a b.jpg", "display"),
               file.path(p$cfg$display_size, "Trips/Skye/a b.jpg.jpg"))
  expect_equal(ph_render_rel(p$cfg, "top.jpg", "thumb"),
               file.path(p$cfg$thumb_size, "top.jpg.jpg"))
})

test_that("two photographs sharing a stem do not render onto each other", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project()
  # `.jpg` is appended rather than substituted for exactly this: a folder
  # holding both is ordinary straight off a phone.
  file.copy(file.path(p$photos, "top.jpg"), file.path(p$photos, "same.jpg"))
  file.copy(file.path(p$photos, "Trips", "x.png"),
            file.path(p$photos, "same.png"))
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  suppressMessages(ph_render_all(p$cfg, quiet = TRUE))

  a <- render_at(p$cfg, "same.jpg", "display")
  b <- render_at(p$cfg, "same.png", "display")
  expect_true(file.exists(a))
  expect_true(file.exists(b))
  expect_false(identical(a, b))
})

test_that("changing display_size renders afresh instead of skipping", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  photos <- make_photos()
  work <- tempfile("work-")
  quiet_init(work, photo_root = photos, display_size = 512L, thumb_size = 64L)
  cfg <- ph_config(work)
  suppressMessages(ph_index(cfg, quiet = TRUE))
  suppressMessages(ph_render_all(cfg, quiet = TRUE))
  expect_true(file.exists(render_at(cfg, "top.jpg", "display")))

  # The size is a path segment, so the smaller copies are somewhere else
  # entirely rather than something to notice.
  quiet_init(work, photo_root = photos, display_size = 256L, thumb_size = 32L,
             overwrite = TRUE)
  small <- ph_config(work)
  out <- suppressMessages(ph_render_all(small, quiet = TRUE))
  expect_gt(out$rendered, 0L)
  expect_equal(out$skipped, 0L)
  expect_true(file.exists(render_at(small, "top.jpg", "display")))
  # And the earlier size is still there, untouched.
  expect_true(file.exists(render_at(cfg, "top.jpg", "display")))
})

test_that("a source restored with an older date is re-rendered", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project(render = TRUE)
  src <- file.path(p$photos, "top.jpg")
  # A backup restore, or cp -p: same path, content changed, date not newer.
  # Comparing "render no older than source" would skip this for ever.
  Sys.setFileTime(src, Sys.time() - 86400)
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  out <- suppressMessages(ph_render_all(p$cfg, quiet = TRUE))
  expect_equal(out$rendered, 2L)
})

test_that("old flat renders are reported and left alone", {
  p <- make_project()
  dir.create(p$cfg$display_dir, recursive = TRUE, showWarnings = FALSE)
  writeBin(as.raw(1:32), file.path(p$cfg$display_dir, "7.jpg"))
  writeBin(as.raw(1:32), file.path(p$cfg$display_dir, "8.jpg"))
  got <- ph_render_orphans(p$cfg)
  expect_equal(length(got), 2L)
  expect_true(all(file.exists(got)))
  # A render in the current layout is not an orphan.
  dir.create(file.path(p$cfg$display_dir, "4096"), showWarnings = FALSE)
  writeBin(as.raw(1:32), file.path(p$cfg$display_dir, "4096", "a.jpg.jpg"))
  expect_equal(length(ph_render_orphans(p$cfg)), 2L)
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
  f <- render_at(p$cfg, "Trips/x.png", "display")
  expect_true(file.exists(f))
  # JPEG magic bytes: the file was rendered, not copied.
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
  # top.jpg is the one fixture larger than 256.
  dims <- system2("exiftool", c("-T", "-ImageWidth", "-ImageHeight",
                                shQuote(render_at(cfg, "top.jpg", "display"))),
                  stdout = TRUE)
  wh <- as.integer(strsplit(dims, "\t")[[1]])
  expect_lte(max(wh), 256L)
})

test_that("an unreadable source is counted as failed, not fatal", {
  skip_if_not(have_vipsthumbnail(), "vipsthumbnail not installed")
  p <- make_project()
  # A file with a photograph's extension and no image data.
  writeLines("not an image", file.path(p$photos, "broken.jpg"))
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  out <- suppressMessages(ph_render_all(p$cfg, quiet = TRUE))
  expect_equal(out$failed, 1L)
  expect_gt(out$rendered, 0L)
})

test_that("rendering without a catalogue reports it rather than failing", {
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
