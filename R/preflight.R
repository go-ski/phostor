# What phostor needs on the machine, checked in one report.
#
# The lists below and DESCRIPTION's SystemRequirements state the same set of
# tools; a test asserts they agree.

ph_pf_required <- c(
  vipsthumbnail = "install libvips (brew install vips)"
)

ph_pf_optional <- c(
  exiftool = "brew install exiftool; without it capture dates are blank"
)

ph_pf_line <- function(status, name, detail = "", quiet = FALSE) {
  txt <- sprintf("%-4s %-14s %s", tolower(status), name, detail)
  if (identical(status, "MISS") || !quiet) message(txt)
  invisible(NULL)
}

#' Check that the tools and packages phostor needs are present.
#'
#' `vipsthumbnail` is the only hard requirement: without it there is nothing to
#' display. `exiftool` is optional; without it capture dates and dimensions are
#' blank. Shiny and bslib are reported as well.
#'
#' @param quiet Suppress the per-tool report. Missing requirements are still
#'   reported.
#' @return `TRUE` if everything needed is present, otherwise `FALSE`,
#'   invisibly.
#' @examples
#' ph_preflight(quiet = TRUE)
#' @export
ph_preflight <- function(quiet = FALSE) {
  ok <- TRUE
  if (!quiet) message("== required tools ==")
  for (tool in names(ph_pf_required)) {
    where <- Sys.which(tool)
    if (nzchar(where)) {
      ph_pf_line("ok", tool, where, quiet = quiet)
    } else {
      ph_pf_line("MISS", tool, ph_pf_required[[tool]])
      ok <- FALSE
    }
  }

  if (!quiet) message("== optional tools ==")
  for (tool in names(ph_pf_optional)) {
    where <- Sys.which(tool)
    ph_pf_line(if (nzchar(where)) "ok" else "warn", tool,
               if (nzchar(where)) where else ph_pf_optional[[tool]],
               quiet = quiet)
  }

  if (!quiet) message("== R packages for the app ==")
  for (p in c("shiny", "bslib", "htmltools")) {
    have <- requireNamespace(p, quietly = TRUE)
    if (!have) ok <- FALSE
    ph_pf_line(if (have) "ok" else "MISS", p,
               if (have) as.character(utils::packageVersion(p))
               else sprintf("install.packages(\"%s\")", p),
               quiet = quiet)
  }

  # Optional, and a warn rather than a MISS: naming speakers is a corner of
  # phostor, and preflight must not fail for want of it.
  ph_pf_line(if (requireNamespace("tuneR", quietly = TRUE)) "ok" else "warn",
             "tuneR",
             if (requireNamespace("tuneR", quietly = TRUE)) {
               paste0(as.character(utils::packageVersion("tuneR")),
                      " -- for naming who spoke")
             } else {
               "install.packages(\"tuneR\") to name who spoke; optional"
             }, quiet = quiet)

  # Recording happens in the browser, which no R-side check can inspect. R can
  # see which browsers are installed and which one the system would open, and
  # the system default may be one that cannot record or has been denied
  # microphone access.
  if (!quiet) message("== browsers ==")
  have <- ph_browser_apps[dir.exists(ph_browser_apps)]
  for (nm in names(have)) {
    ph_pf_line(if (isTRUE(ph_browser_records(nm))) "ok" else "warn", nm,
               if (isTRUE(ph_browser_records(nm))) have[[nm]]
               else paste0(have[[nm]], "  (cannot record: chunks do not concatenate)"),
               quiet = quiet)
  }
  if (!length(have)) {
    ph_pf_line("warn", "browser", "none of the usual browsers found in /Applications",
               quiet = quiet)
  }

  dflt <- ph_browser_default()
  rec <- ph_browser_records(dflt)
  if (is.na(dflt)) {
    ph_pf_line("warn", "default", "could not determine the default browser",
               quiet = quiet)
  } else if (isTRUE(rec)) {
    ph_pf_line("ok", "default", paste0(dflt, "  (can record)"), quiet = quiet)
  } else {
    # Not an error: ph_app() opens a browser that can record regardless.
    ph_pf_line("warn", "default",
               paste0(dflt, "  (cannot record; ph_app() will open ",
                      ph_browser_launcher()$name %||% "another browser",
                      " instead)"), quiet = quiet)
  }
  # Transcription is optional: without it phostor records exactly as before,
  # so a missing transcriber is a warning and never makes preflight fail.
  if (!quiet) message("== transcription ==")
  if (!identical(Sys.info()[["sysname"]], "Darwin")) {
    ph_pf_line("warn", "transcriber", "macOS only; recordings are kept untranscribed",
               quiet = quiet)
  } else if (!nzchar(Sys.which("swiftc"))) {
    ph_pf_line("warn", "transcriber",
               "install Xcode command line tools (xcode-select --install)",
               quiet = quiet)
  } else {
    bin <- ph_transcribe_build(quiet = TRUE)
    if (is.na(bin)) {
      ph_pf_line("warn", "transcriber", "could not be built; needs macOS 26 or newer",
                 quiet = quiet)
    } else {
      chk <- suppressWarnings(system2(bin, "--check", stdout = TRUE, stderr = TRUE))
      if (identical(as.integer(attr(chk, "status") %||% 0L), 0L)) {
        loc <- sub("^installed: ", "", grep("^installed: ", chk, value = TRUE))
        ph_pf_line("ok", "transcriber", bin, quiet = quiet)
        ph_pf_line("ok", "languages", if (length(loc)) loc[1] else "none",
                   quiet = quiet)
      } else {
        ph_pf_line("warn", "transcriber",
                   if (length(chk)) chk[1] else "unavailable", quiet = quiet)
      }
    }
  }

  if (!quiet) {
    message("note microphone     if recording fails, check ",
            ph_privacy_pane(),
            " -- and quit and reopen the browser afterwards")
  }

  if (!quiet) message(if (ok) "preflight: ready." else "preflight: NOT ready.")
  invisible(ok)
}
