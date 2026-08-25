# Browser and microphone detection, and the wording shown when a microphone
# fails to open.
#
# Recording happens in the browser, which R cannot inspect. R turns the error
# name the browser reports into an instruction. The wording lives here rather
# than in app.R so that it can be unit-tested; app.R is not reachable by
# R CMD check or testthat.
#
# The case this handles: macOS denies a browser microphone access at the system
# level, getUserMedia() rejects with NotFoundError, and the error name alone
# does not indicate the remedy.

# Every error name phostor explains. `insecure`, `nocodec` and `norecorder`
# are phostor's own, sent by app.R when there is no getUserMedia, when
# MediaRecorder can produce none of the containers phostor records in, and when
# a recorder that a visit needs did not start.
ph_mic_errors <- c(
  "NotFoundError", "DevicesNotFoundError", "OverconstrainedError",
  "NotAllowedError", "PermissionDeniedError",
  "NotReadableError", "TrackStartError", "AbortError",
  "SecurityError", "TypeError", "insecure", "nocodec", "norecorder"
)

# Browsers whose MediaRecorder produces a container phostor can assemble from
# chunks: Chrome records MP4, Firefox Ogg, and both fall back to WebM. Safari
# is absent because its fragmented MP4 chunks do not concatenate -- Chrome's
# do, which is why MP4 is preferred there and gets a transcript.
ph_browsers_supported <- c("Chrome", "Firefox", "Microsoft Edge", "Brave",
                           "Opera", "Chromium")

#' Which browser is this?
#'
#' @param ua A `navigator.userAgent` string.
#' @return A short browser name, or `NA_character_` if it is not recognised.
#' @examples
#' ph_browser_name("Mozilla/5.0 (Macintosh) Gecko/20100101 Firefox/141.0")
#' @export
ph_browser_name <- function(ua) {
  if (is.null(ua) || !length(ua) || is.na(ua[1]) || !nzchar(ua[1])) {
    return(NA_character_)
  }
  ua <- as.character(ua)[1]
  # Order matters: Edge and Opera both carry "Chrome/" in their user agent, and
  # every Chromium browser carries "Safari/".
  pats <- c(Firefox = "Firefox/", `Microsoft Edge` = "Edg/", Opera = "OPR/",
            Brave = "Brave/", Chrome = "Chrome/|CriOS/", Safari = "Safari/")
  for (nm in names(pats)) if (grepl(pats[[nm]], ua)) return(nm)
  NA_character_
}

#' Can this browser record for phostor?
#'
#' @param browser A name from [ph_browser_name()].
#' @return `TRUE`, `FALSE`, or `NA` when the browser is unknown.
#' @examples
#' ph_browser_records("Firefox")
#' ph_browser_records("Safari")
#' @export
ph_browser_records <- function(browser) {
  if (is.null(browser) || !length(browser) || is.na(browser[1])) return(NA)
  browser[1] %in% ph_browsers_supported
}

# Where microphone permission for an application is changed. Named per
# platform rather than left as "check your privacy settings".
ph_privacy_pane <- function() {
  if (identical(Sys.info()[["sysname"]], "Darwin")) {
    "System Settings > Privacy & Security > Microphone"
  } else if (identical(Sys.info()[["sysname"]], "Windows")) {
    "Settings > Privacy & security > Microphone"
  } else {
    "your system's microphone privacy settings"
  }
}

#' What to do about a microphone that did not open.
#'
#' Turns the `name` of a `getUserMedia()` rejection into an instruction. The
#' remedy is usually outside the browser, so the error name alone does not
#' indicate it.
#'
#' @param why An error name, e.g. `"NotFoundError"`. See `ph_mic_errors`.
#' @param browser A browser name from [ph_browser_name()], used to name the
#'   application in the instruction.
#' @return A single string.
#' @examples
#' ph_mic_advice("NotFoundError", "Firefox")
#' ph_mic_advice("NotReadableError")
#' @export
ph_mic_advice <- function(why, browser = NULL) {
  b <- if (is.null(browser) || !length(browser) || is.na(browser[1]) ||
           !nzchar(browser[1])) "your browser" else as.character(browser)[1]
  why <- if (is.null(why) || !length(why)) "" else as.character(why)[1]
  pane <- ph_privacy_pane()

  # The relaunch is required: macOS grants the entitlement to the process, and
  # an already-running browser keeps the previous answer until it is quit.
  grant <- sprintf(
    "Open %s, switch %s on, then quit %s completely and open it again -- the change only takes effect on relaunch.",
    pane, b, b)

  switch(
    why,
    NotFoundError = ,
    DevicesNotFoundError = ,
    OverconstrainedError = paste(
      sprintf("%s cannot see any microphone.", b), grant,
      "If it is already on, check that a microphone is connected and not in",
      "exclusive use by another program."),
    NotAllowedError = ,
    PermissionDeniedError = paste(
      sprintf("%s blocked the microphone for this page.", b),
      "Click the microphone icon in the address bar and allow it, then try again.",
      sprintf("If there is no icon there, the block is at the system level: %s",
              grant)),
    NotReadableError = ,
    TrackStartError = ,
    AbortError = paste(
      "Another program is using the microphone. Zoom, Teams and Webex hold it",
      "even when idle. Quit it and try again."),
    SecurityError = ,
    TypeError = ,
    insecure = paste(
      "This page may not use a microphone.",
      "Open phostor at http://127.0.0.1:<port> or http://localhost:<port>",
      "rather than a network address: browsers allow recording only on a",
      "local or encrypted page."),
    nocodec = paste(
      sprintf("%s cannot record Opus in WebM, the format phostor stores.", b),
      "Use Chrome or Firefox; Safari does not support it."),
    # Raised mid-sitting, when a microphone that was working stops being
    # available. Said plainly because nothing is being recorded from here on.
    norecorder = paste(
      "Recording has stopped: the microphone is no longer available to",
      sprintf("%s, and nothing is being recorded now.", b),
      "Check that it is still connected. Quit any program that may have",
      "taken it, then press 'Try the microphone again'."),
    paste(
      sprintf("The microphone did not open, and %s reported '%s'.", b,
              if (nzchar(why)) why else "no reason"),
      grant,
      "If that does not help, quit any program that might be using the",
      "microphone and try again.")
  )
}

# --- choosing a browser to launch -------------------------------------------

# Bundle identifiers of the recognised browsers, and where they are installed.
ph_browser_apps <- c(
  Chrome = "/Applications/Google Chrome.app",
  Firefox = "/Applications/Firefox.app",
  `Microsoft Edge` = "/Applications/Microsoft Edge.app",
  Brave = "/Applications/Brave Browser.app",
  Chromium = "/Applications/Chromium.app",
  Safari = "/Applications/Safari.app"
)

ph_browser_bundles <- c(
  "org.mozilla.firefox" = "Firefox",
  "com.google.chrome" = "Chrome",
  "com.microsoft.edgemac" = "Microsoft Edge",
  "com.brave.browser" = "Brave",
  "org.chromium.chromium" = "Chromium",
  "com.apple.safari" = "Safari",
  "company.thebrowser.browser" = "Arc"
)

#' The system's default browser.
#'
#' Best-effort and macOS-only: reads the LaunchServices handler for `https`.
#' Returns `NA_character_` when it cannot tell, which is what
#' [ph_preflight()] reports.
#'
#' @return A browser name, or `NA_character_`.
#' @examples
#' ph_browser_default()
#' @export
ph_browser_default <- function() {
  if (!identical(Sys.info()[["sysname"]], "Darwin")) return(NA_character_)
  out <- tryCatch(
    suppressWarnings(system2(
      "defaults",
      c("read", "com.apple.LaunchServices/com.apple.launchservices.secure"),
      stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  if (!length(out)) return(NA_character_)

  # Each handler is a dict holding LSHandlerRoleAll then LSHandlerURLScheme.
  # A nested LSHandlerPreferredVersions dict carries its own LSHandlerRoleAll
  # of "-", which must not be mistaken for the answer.
  scheme <- grep("LSHandlerURLScheme\\s*=\\s*https\\s*;", out)
  if (!length(scheme)) return(NA_character_)
  roles <- grep("LSHandlerRoleAll\\s*=", out)
  before <- roles[roles < scheme[[1]]]
  for (i in rev(before)) {
    id <- sub('.*LSHandlerRoleAll\\s*=\\s*"?([^";]+)"?\\s*;.*', "\\1", out[[i]])
    id <- tolower(trimws(id))
    if (identical(id, "-") || !nzchar(id)) next
    nm <- ph_browser_bundles[[id]]
    return(if (is.null(nm)) id else nm)
  }
  NA_character_
}

# A launcher for shiny::runApp(launch.browser=). Returns the browser's name and
# a function(url), or a NULL function meaning "let the system decide".
ph_browser_launcher <- function(browser = NULL) {
  darwin <- identical(Sys.info()[["sysname"]], "Darwin")
  installed <- ph_browser_apps[dir.exists(ph_browser_apps)]

  app <- NULL
  name <- NULL
  if (!is.null(browser) && nzchar(browser)) {
    # An explicit choice: a recognised name, or a path to an application.
    if (browser %in% names(installed)) {
      name <- browser; app <- installed[[browser]]
    } else if (dir.exists(browser) || file.exists(browser)) {
      name <- basename(browser); app <- browser
    } else {
      warning("phostor: browser '", browser,
              "' not found; using the system default.", call. = FALSE)
    }
  } else if (darwin) {
    # No choice made: prefer a browser that can record over the system
    # default, which may be one that cannot.
    for (nm in c("Chrome", "Firefox", "Microsoft Edge", "Brave", "Chromium")) {
      if (nm %in% names(installed)) { name <- nm; app <- installed[[nm]]; break }
    }
  }

  if (is.null(app) || !darwin) {
    return(list(name = name %||% NA_character_, launch = NULL))
  }
  list(name = name, launch = function(url) {
    system2("open", c("-a", shQuote(app), shQuote(url)),
            stdout = FALSE, stderr = FALSE)
    invisible(NULL)
  })
}
