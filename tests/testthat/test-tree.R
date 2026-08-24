mini <- function() {
  data.frame(
    id = 1:5,
    rel_path = c("Trips/Skye/b.jpg", "Trips/Skye/a.jpg", "Trips/x.jpg",
                 "top.jpg", "A&B/<odd>.jpg"),
    dir = c("Trips/Skye", "Trips/Skye", "Trips", "", "A&B"),
    name = c("b.jpg", "a.jpg", "x.jpg", "top.jpg", "<odd>.jpg"),
    stringsAsFactors = FALSE)
}

test_that("the tree nests directories and closes every one it opens", {
  h <- ph_tree_html(mini())
  expect_equal(lengths(regmatches(h, gregexpr("<details", h))),
               lengths(regmatches(h, gregexpr("</details>", h))))
  expect_equal(lengths(regmatches(h, gregexpr("class=\"ph-p\"", h))), 5L)
  # Skye is nested inside Trips, not a sibling of it.
  expect_match(h, "Trips</summary><details><summary[^>]*>Skye")
})

test_that("names are escaped, in the row and in the directory alike", {
  h <- ph_tree_html(mini())
  expect_match(h, "&lt;odd&gt;\\.jpg", fixed = FALSE)
  expect_match(h, "A&amp;B")
  expect_false(grepl("<odd>", h, fixed = TRUE))
})

test_that("one global input carries every click", {
  h <- ph_tree_html(mini())
  # Per-row Shiny inputs would mean per-row observers, which accumulate.
  expect_equal(lengths(regmatches(h, gregexpr("setInputValue", h))), 5L)
  expect_equal(lengths(regmatches(h, gregexpr("photo_pick", h))), 5L)
})

test_that("visit badges appear only where there are visits", {
  h <- ph_tree_html(mini(), counts = c(0L, 2L, 0L, 1L, 0L))
  expect_equal(lengths(regmatches(h, gregexpr("class=\"ph-b\"", h))), 2L)
  expect_match(h, ">2</span>")
})

test_that("counts follow the rows through the tree's own ordering", {
  idx <- mini()
  # counts arrive in idx order and must be reordered with it, or a badge lands
  # on the wrong photograph.
  h <- ph_tree_html(idx, counts = c(7L, 0L, 0L, 0L, 0L))
  # id 1 is Trips/Skye/b.jpg; its row must carry the 7.
  expect_match(h, "id=\"ph-p-1\"[^>]*>.*?>7</span>")
})

test_that("tree order is the order shown and the order the arrows step", {
  expect_equal(ph_tree_order(mini()), c(5L, 2L, 1L, 3L, 4L))
  expect_equal(ph_tree_order(mini()[0, ]), integer(0))
})

test_that("an empty catalogue renders a message, not broken markup", {
  h <- ph_tree_html(mini()[0, ])
  expect_match(h, "No photographs")
  expect_false(grepl("<details", h, fixed = TRUE))
})

test_that("thumbnails are referenced by id and load lazily", {
  h <- ph_tree_html(mini())
  expect_match(h, "src=\"thumbs/1\\.jpg\"")
  expect_equal(lengths(regmatches(h, gregexpr("loading=\"lazy\"", h))), 5L)
})

test_that("URL paths encode each segment but keep the separators", {
  expect_equal(ph_url_path("Trips/Isle of Skye/img #4.jpg"),
               "Trips/Isle%20of%20Skye/img%20%234.jpg")
  expect_equal(ph_url_path("a.jpg"), "a.jpg")
  expect_equal(length(ph_url_path(c("a b/c.jpg", "d.jpg"))), 2L)
})

test_that("escaping covers every character that could break the attribute", {
  expect_equal(ph_escape("a&b"), "a&amp;b")
  expect_equal(ph_escape("<x>"), "&lt;x&gt;")
  expect_match(ph_escape("say \"hi\""), "&quot;")
})

test_that("visit counts read from disk match the tree's badges", {
  p <- make_project()
  ph_write_sidecar(p$cfg, "top.jpg", 1L, list(place = "a"))
  ph_write_sidecar(p$cfg, "top.jpg", 2L, list(place = "b"))
  idx <- ph_read_index(p$cfg)
  counts <- ph_visit_counts(p$cfg, idx$rel_path)
  expect_equal(counts[idx$rel_path == "top.jpg"], 2L)
  expect_equal(sum(counts), 2L)
})
