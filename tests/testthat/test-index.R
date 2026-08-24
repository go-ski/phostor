test_that("the scan finds photographs and nothing else", {
  p <- make_project(index = FALSE)
  idx <- ph_scan(p$cfg)
  expect_setequal(idx$rel_path,
                  c("top.jpg", "Trips/Skye/a b.jpg", "Trips/Skye/c&d.jpg",
                    "Trips/x.png"))
  # cruft directories and non-photographs are not photographs
  expect_false(any(grepl("@eaDir", idx$rel_path)))
  expect_false("notes.txt" %in% idx$rel_path)
  expect_equal(idx$dir[idx$rel_path == "top.jpg"], "")
  expect_equal(idx$dir[idx$rel_path == "Trips/x.png"], "Trips")
})

test_that("the scan is ordered so that a directory's photographs are adjacent", {
  p <- make_project(index = FALSE)
  idx <- ph_scan(p$cfg)
  # This is what lets ph_tree_html() nest in one pass with no lookahead.
  expect_equal(idx$rel_path, idx$rel_path[order(idx$rel_path, method = "radix")])
  d <- idx$dir
  expect_equal(rle(d)$values, unique(d))
})

test_that("cruft matches whole path segments only", {
  p <- make_project(index = FALSE)
  dir.create(file.path(p$photos, "@eaDirectory"))
  file.copy(file.path(p$photos, "top.jpg"),
            file.path(p$photos, "@eaDirectory", "keep.jpg"))
  idx <- ph_scan(p$cfg)
  expect_true("@eaDirectory/keep.jpg" %in% idx$rel_path)
})

test_that("ids are stable when photographs are added", {
  p <- make_project()
  first <- ph_read_index(p$cfg)
  expect_equal(nrow(first), 4L)
  expect_equal(sort(first$id), 1:4)

  file.copy(file.path(p$photos, "top.jpg"), file.path(p$photos, "aaa-new.jpg"))
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  second <- ph_read_index(p$cfg)

  expect_equal(nrow(second), 5L)
  keep <- match(first$rel_path, second$rel_path)
  # Every previously-known photograph keeps its id, even though the new file
  # sorts before all of them -- position must never determine identity, or
  # every rendered copy would be renumbered.
  expect_equal(second$id[keep], first$id)
  expect_equal(second$id[second$rel_path == "aaa-new.jpg"], 5L)
})

test_that("a removed photograph leaves the catalogue but keeps its sidecars", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(place = "somewhere"))
  unlink(file.path(p$photos, "top.jpg"))
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  idx <- ph_read_index(p$cfg)
  expect_false("top.jpg" %in% idx$rel_path)
  expect_length(ph_visits_for(p$cfg, "top.jpg"), 1L)
})

test_that("a tab or newline in a filename is refused, not written out", {
  skip_on_os("windows")
  p <- make_project(index = FALSE)
  bad <- file.path(p$photos, "with\ttab.jpg")
  ok <- file.copy(file.path(p$photos, "top.jpg"), bad)
  skip_if_not(ok, "filesystem rejected a tab in a filename")
  expect_error(ph_scan(p$cfg), "tab or newline")
})

test_that("capture date falls back to CreateDate and says so", {
  cd <- ph_capture_date(c("1974:07:03 14:22:01", NA, NA),
                        c(NA, "2011:02:02 09:00:00", NA))
  expect_equal(cd$value, c("1974:07:03 14:22:01", "2011:02:02 09:00:00", NA))
  expect_equal(cd$source, c("DateTimeOriginal", "CreateDate", NA))
  # A recycled scalar second argument must not silently misalign.
  expect_length(ph_capture_date(c("a", NA))$value, 2L)
})

test_that("exiftool metadata reaches the catalogue", {
  skip_if_not(nzchar(Sys.which("exiftool")), "exiftool not installed")
  p <- make_project(index = FALSE)
  # shQuote the whole assignment: system2() joins its args with spaces and
  # quotes nothing, so an unquoted value with a space becomes two arguments.
  system2("exiftool", c("-overwrite_original", "-q", "-m",
                        shQuote("-DateTimeOriginal=1974:07:03 14:22:01"),
                        shQuote(file.path(p$photos, "Trips/Skye/a b.jpg"))),
          stdout = FALSE, stderr = FALSE)
  suppressMessages(ph_index(p$cfg, quiet = TRUE))
  idx <- ph_read_index(p$cfg)
  r <- idx[idx$rel_path == "Trips/Skye/a b.jpg", ]
  expect_equal(r$capture, "1974:07:03 14:22:01")
  expect_equal(r$capture_src, "DateTimeOriginal")
  expect_equal(r$width, 100L)
  expect_equal(r$height, 75L)
  # A photograph with no date is NA, not an empty string or a zero date.
  t0 <- idx[idx$rel_path == "top.jpg", ]
  expect_true(is.na(t0$capture))
})

test_that("EXIF carrying Latin-1 bytes does not corrupt the catalogue", {
  skip_if_not(nzchar(Sys.which("exiftool")), "exiftool not installed")
  p <- make_project(index = FALSE)
  # "Francois" with a Latin-1 cedilla: a byte sequence that is not valid UTF-8,
  # which is what an older camera or editor writes into a field declared UTF-8.
  # It goes to exiftool through an argfile written with useBytes, because
  # shQuote() cannot represent these bytes as an R string on this locale --
  # which is itself the hazard being tested for.
  argfile <- tempfile("exifargs-")
  con <- file(argfile, open = "wb")
  writeBin(charToRaw("-overwrite_original\n-q\n-m\n-charset\nexif=UTF8\n-Artist=Fran"),
           con)
  writeBin(as.raw(0xe7), con)
  writeBin(charToRaw(paste0("ois\n", file.path(p$photos, "top.jpg"), "\n")), con)
  close(con)
  system2("exiftool", c("-@", shQuote(argfile)), stdout = FALSE, stderr = FALSE)
  expect_silent(suppressMessages(ph_index(p$cfg, quiet = TRUE)))
  idx <- ph_read_index(p$cfg)
  expect_equal(nrow(idx), 4L)
  expect_true(all(validUTF8(idx$rel_path)))
})

test_that("the catalogue round-trips awkward names byte for byte", {
  p <- make_project()
  idx <- ph_read_index(p$cfg)
  expect_true("Trips/Skye/c&d.jpg" %in% idx$rel_path)
  expect_true("Trips/Skye/a b.jpg" %in% idx$rel_path)
  expect_type(idx$id, "integer")
  expect_type(idx$bytes, "double")
})

test_that("an empty photo directory indexes to an empty catalogue", {
  photos <- tempfile("photos-"); dir.create(photos)
  work <- tempfile("work-")
  quiet_init(work, photo_root = photos)
  cfg <- ph_config(work)
  suppressMessages(ph_index(cfg, quiet = TRUE))
  expect_equal(nrow(ph_read_index(cfg)), 0L)
  expect_equal(ph_tree_order(ph_read_index(cfg)), integer(0))
})
