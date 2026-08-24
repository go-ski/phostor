# Browsers, microphones, and what to tell someone when it does not work.
#
# The recording half of phostor lives in the browser, where R can see nothing.
# All R can do is turn what the browser reports back into an instruction a
# person in a room can act on -- which is why the wording lives here, in R,
# where every branch of it can be unit-tested, rather than in app.R where none
# of it could be.
#
# The failure that prompted this file: macOS had denied Firefox microphone
# access at the system level, so getUserMedia() rejected with NotFoundError --
# a name that tells the room precisely nothing. The browser had never been the
# problem, and neither had the hardware.

# Every error name phostor knows how to explain. `insecure` and `nocodec` are
# phostor's own, sent by app.R when there is no getUserMedia at all and when
# MediaRecorder cannot produce WebM/Opus.
ph_mic_errors <- c(
  "NotFoundError", "DevicesNotFoundError", "OverconstrainedError",
  "NotAllowedError", "PermissionDeniedError",
  "NotReadableError", "TrackStartError", "AbortError",
  "SecurityError", "TypeError", "insecure", "nocodec"
)

# Browsers whose MediaRecorder produces WebM/Opus, whose chunks concatenate
# into a valid file. Safari records fragmented MP4, which does not.
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

# Where a person changes microphone permission for an application. Named per
# platform, because "check your privacy settings" helps nobody.
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
#' remedy is nearly always outside the browser, which is why the raw error name
#' is so unhelpful on its own.
#'
#' @param why An error name, e.g. `"NotFoundError"`. See `ph_mic_errors`.
#' @param browser A browser name from [ph_browser_name()], used to name the
#'   application in the instruction.
#' @return A single string of plain prose.
#' @examples
#' ph_mic_advice("NotFoundError", "Firefox")
#' ph_mic_advice("NotReadableError")
#' @export
ph_mic_advice <- function(why, browser = NULL) {
  b <- if (is.null(browser) || !length(browser) || is.na(browser[1]) ||
           !nzchar(browser[1])) "your browser" else as.character(browser)[1]
  why <- if (is.null(why) || !length(why)) "" else as.character(why)[1]
  pane <- ph_privacy_pane()

  # The relaunch is not optional and is the step everyone misses: macOS grants
  # the entitlement to the process, and an already-running browser keeps the
  # old answer until it is quit.
  grant <- sprintf(
    "Open %s, switch %s on, then quit %s completely and open it again -- the change only takes effect on relaunch.",
    pane, b, b)

  switch(
    why,
    NotFoundError = ,
    DevicesNotFoundError = ,
    OverconstrainedError = paste(
      sprintf("%s cannot see any microphone.", b), grant,
      "If it is already switched on, check that a microphone is connected and",
      "is not the only thing another program is using."),
    NotAllowedError = ,
    PermissionDeniedError = paste(
      sprintf("%s blocked the microphone for this page.", b),
      "Click the microphone icon in the address bar and allow it, then try again.",
      sprintf("If there is no icon there, the block is at the system level: %s",
              grant)),
    NotReadableError = ,
    TrackStartError = ,
    AbortError = paste(
      "Another program is holding the microphone -- Zoom, Teams and Webex all",
      "do this, even when they look idle. Quit it and try again."),
    SecurityError = ,
    TypeError = ,
    insecure = paste(
      "This page is not allowed to use a microphone at all.",
      "Open phostor at http://127.0.0.1:<port> or http://localhost:<port>,",
      "not at a network address -- browsers only permit recording on a local",
      "or encrypted page."),
    nocodec = paste(
      sprintf("%s cannot record Opus in WebM, which is the format phostor", b),
      "stores. Use Chrome or Firefox; Safari cannot do it."),
    paste(
      sprintf("The microphone did not open, and %s reported '%s'.", b,
              if (nzchar(why)) why else "no reason"),
      grant,
      "If that does not help, quit any program that might be using the",
      "microphone and try again.")
  )
}

# --- launching the right browser --------------------------------------------

# Bundle identifiers of the browsers worth naming, and where they live.
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
#' Best-effort and macOS-only: it reads the LaunchServices handler for `https`.
#' Returns `NA_character_` rather than guessing when it cannot tell -- which is
#' the honest answer, and the one [ph_preflight()] reports.
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
    # An explicit choice: a name we know, or a path to an application.
    if (browser %in% names(installed)) {
      name <- browser; app <- installed[[browser]]
    } else if (dir.exists(browser) || file.exists(browser)) {
      name <- basename(browser); app <- browser
    } else {
      warning("phostor: browser '", browser,
              "' not found; using the system default.", call. = FALSE)
    }
  } else if (darwin) {
    # No choice made: prefer a browser that can actually record, rather than
    # the system default -- which on this machine was Firefox with microphone
    # access denied, and the app opened there and failed with no explanation.
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
