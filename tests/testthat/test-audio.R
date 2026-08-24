test_that("chunks concatenate to exactly the bytes that were sent", {
  p <- make_project()
  part <- ph_audio_open(p$cfg, "top.jpg", 1L)
  set.seed(42)   # seeded here; the payload is arbitrary but must be stable
  chunks <- lapply(1:5, function(i) as.raw(sample(0:255, 400, replace = TRUE)))
  for (ch in chunks) ph_audio_append(part, base64enc::base64encode(ch))
  final <- ph_audio_close(part)
  expect_equal(final, "visit-0001.webm")
  got <- readBin(file.path(ph_visit_dir(p$cfg, "top.jpg"), final), "raw",
                 n = 1e6)
  expect_identical(got, unlist(chunks))
})

test_that("an empty take leaves no file and claims no audio", {
  p <- make_project()
  part <- ph_audio_open(p$cfg, "top.jpg", 1L)
  expect_true(file.exists(part))
  expect_true(is.na(ph_audio_close(part)))
  expect_false(file.exists(part))
  expect_false(file.exists(sub("\\.part$", "", part)))
})

test_that("an interrupted take leaves a .part and no sidecar audio", {
  p <- make_project()
  part <- ph_audio_open(p$cfg, "top.jpg", 1L)
  ph_audio_append(part, base64enc::base64encode(as.raw(1:100)))
  # The process dies here: close() is never called.
  expect_true(file.exists(part))
  expect_false(file.exists(sub("\\.part$", "", part)))
  expect_equal(ph_orphan_audio(p$cfg), part)
  # A zero-byte .part is not an interruption worth reporting.
  ph_audio_open(p$cfg, "Trips/x.png", 1L)
  expect_equal(ph_orphan_audio(p$cfg), part)
})

test_that("appending nothing is a no-op, not a zero-byte write", {
  p <- make_project()
  part <- ph_audio_open(p$cfg, "top.jpg", 1L)
  expect_equal(ph_audio_append(part, NULL), 0L)
  expect_equal(ph_audio_append(part, ""), 0L)
  expect_equal(file.size(part), 0)
})

test_that("discarding removes the take entirely", {
  p <- make_project()
  part <- ph_audio_open(p$cfg, "top.jpg", 1L)
  ph_audio_append(part, base64enc::base64encode(as.raw(1:50)))
  expect_true(ph_audio_discard(part))
  expect_false(file.exists(part))
  expect_false(ph_audio_discard(part))
})

test_that("reopening a visit clears whatever the last attempt left", {
  p <- make_project()
  part <- ph_audio_open(p$cfg, "top.jpg", 1L)
  ph_audio_append(part, base64enc::base64encode(as.raw(1:50)))
  again <- ph_audio_open(p$cfg, "top.jpg", 1L)
  expect_equal(again, part)
  expect_equal(file.size(again), 0)
})
