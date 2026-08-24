# Allow the suite to run before `R CMD INSTALL` by sourcing R/ when the package
# namespace is not available.
if (!"phostor" %in% loadedNamespaces() &&
    !requireNamespace("phostor", quietly = TRUE)) {
  root <- normalizePath(file.path("..", ".."))
  for (f in list.files(file.path(root, "R"), pattern = "\\.R$",
                       full.names = TRUE)) {
    source(f)
  }
}
