# Entry points: the app, and the command line that wraps it.

#' Prepare a project and launch the app.
#'
#' Indexes, renders and then starts the Shiny app: one call from a fresh work
#' directory to a running session.
#'
#' @param config A work directory, a config path, or a config list.
#' @param ... Passed to [ph_app()].
#' @return Whatever [ph_app()] returns, invisibly.
#' @examples
#' \dontrun{
#' ph_go("~/phostor/family")
#' }
#' @export
ph_go <- function(config = NULL, ...) {
  cfg <- ph_as_config(config, require_photos = TRUE)
  ph_index(cfg)
  ph_render_all(cfg)
  ph_app(cfg, ...)
}

#' Launch the Shiny app.
#'
#' The config is resolved to absolute paths before launching, because
#' [shiny::runApp()] changes the working directory to the app folder.
#'
#' Blocks until the app stops.
#'
#' Recording happens in the browser, so which browser opens matters. By default
#' phostor opens one that can record (Chrome, then Firefox) in preference to
#' the system default, which may be neither.
#'
#' @param config A work directory, a config path, or a config list.
#' @param port Port to serve on.
#' @param launch_browser Open a browser window.
#' @param browser Which browser to open: `"Chrome"`, `"Firefox"`, a path to an
#'   application, or `NULL` to let phostor choose one that can record.
#' @return Invisibly, whatever [shiny::runApp()] returned.
#' @examples
#' \dontrun{
#' ph_app("~/phostor/family")
#' ph_app("~/phostor/family", browser = "Firefox")
#' }
#' @export
ph_app <- function(config = NULL, port = 7655L,
                   launch_browser = interactive(), browser = NULL) {
  for (p in c("shiny", "bslib")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      stop("phostor: the app needs the '", p, "' package.", call. = FALSE)
    }
  }
  app_dir <- system.file("shiny", package = "phostor")
  # Running from a source tree (pkgload::load_all) rather than an installed
  # package: system.file() finds nothing, so fall back to the tree itself.
  if (!nzchar(app_dir)) {
    cands <- c(file.path(na_if_empty(Sys.getenv("PHOSTOR_SRC")) %||% ".",
                         "inst", "shiny"),
               file.path(getwd(), "inst", "shiny"))
    cands <- cands[dir.exists(cands)]
    if (!length(cands)) {
      stop("phostor: app not found. Reinstall the package.", call. = FALSE)
    }
    app_dir <- cands[[1]]
  }

  cfg <- ph_as_config(config, require_photos = TRUE)
  if (!nrow(ph_read_index(cfg))) {
    stop("phostor: no catalogue yet. Run ph_index() and ph_render_all(), ",
         "or ph_go() to do both and launch.", call. = FALSE)
  }
  # The resolved snapshot lives in work_dir, so it survives the app session.
  # runApp() chdirs, hence absolute paths.
  resolved <- ph_config_snapshot(cfg)
  old <- Sys.getenv("PHOSTOR_CONFIG", unset = NA)
  Sys.setenv(PHOSTOR_CONFIG = resolved)
  on.exit({
    if (is.na(old)) Sys.unsetenv("PHOSTOR_CONFIG")
    else Sys.setenv(PHOSTOR_CONFIG = old)
  }, add = TRUE)

  # Compile the transcriber now rather than when the first photograph is left:
  # the build takes about a second, and there it would land in the middle of a
  # sitting with the Shiny loop waiting on it. Cached after the first run, so
  # this is usually a no-op, and a machine that cannot build one carries on
  # recording without transcripts.
  if (isTRUE(cfg$transcribe)) ph_transcribe_build(quiet = TRUE)

  message(sprintf("phostor: http://127.0.0.1:%d", as.integer(port)))
  lb <- isTRUE(launch_browser)
  if (lb) {
    br <- ph_browser_launcher(browser)
    if (!is.null(br$launch)) {
      message("phostor: opening ", br$name)
      lb <- br$launch
    } else {
      # Nothing recognised: fall back to the system default and say so, since
      # the default may be a browser that cannot record.
      d <- ph_browser_default()
      message("phostor: opening the default browser",
              if (!is.na(d)) paste0(" (", d, ")") else "")
    }
  }
  invisible(shiny::runApp(app_dir, port = as.integer(port),
                          launch.browser = lb))
}

#' What a project holds.
#'
#' @param config A work directory, a config path, or a config list.
#' @return Invisibly, a list of counts.
#' @examples
#' \dontrun{
#' ph_status("~/phostor/family")
#' }
#' @export
ph_status <- function(config = NULL) {
  cfg <- ph_as_config(config)
  ph_config_report(cfg)
  idx <- ph_read_index(cfg)
  sess <- ph_sessions(cfg)
  sidecars <- if (dir.exists(cfg$sidecar_dir)) {
    length(list.files(cfg$sidecar_dir, pattern = "^visit-[0-9]+\\.yml$",
                      recursive = TRUE))
  } else 0L
  orphans <- length(ph_orphan_audio(cfg))
  people <- ph_known_people(cfg)
  waiting <- ph_untranscribed(cfg)

  message("  photographs: ", nrow(idx))
  message("  sittings   : ", nrow(sess),
          if (nrow(sess)) paste0(" (latest ", sess$session[1], ")") else "")
  message("  visits     : ", sidecars)
  message("  people     : ", length(people),
          if (length(people)) paste0(" (", paste(utils::head(people, 6),
                                                 collapse = ", "),
                                     if (length(people) > 6) ", ..." else "",
                                     ")") else "")
  if (waiting) {
    message("  untranscribed: ", waiting, " recording(s) -- run ",
            "`phostor transcribe` to fill them in")
  }
  if (orphans) {
    message("  interrupted: ", orphans, " .part file(s) -- audio from a ",
            "visit that did not close; playable, and not deleted by phostor")
  }
  invisible(list(photos = nrow(idx), sittings = nrow(sess), visits = sidecars,
                 people = length(people), orphans = orphans,
                 untranscribed = waiting))
}

# ---------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------

ph_cli_usage <- function() {
  message(paste(c(
    "phostor -- an app that adds stories to photos",
    "",
    "usage: phostor <command> [--work <dir>] [options]",
    "",
    "  init       create a work directory   --photos <dir>",
    "  index      scan photo_root and build the catalogue",
    "  render     pre-render display copies and thumbnails   [--force]",
    "  app        launch the app                             [--port N]",
    "  go         index, render, then launch",
    "  status     what this project holds",
    "  preflight  check the tools phostor needs",
    "  transcribe write a transcript for every recording   [--force]",
    "",
    "The work directory is where config.yml lives. It is taken from --work,",
    "$PHOSTOR_WORK, or ./config.yml.",
    ""), collapse = "\n"))
  invisible(NULL)
}

ph_flag_value <- function(args, flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[[i + 1L]]
}

ph_has_flag <- function(args, flag) flag %in% args

#' Command line entry point.
#'
#' @param args Character vector of arguments, as from `commandArgs()`.
#' @return Invisibly, the command's return value.
#' @examples
#' \dontrun{
#' ph_cli(c("status", "--work", "~/phostor/family"))
#' }
#' @export
ph_cli <- function(args = character(0)) {
  if (!length(args) || ph_has_flag(args, "--help") || ph_has_flag(args, "-h")) {
    return(invisible(ph_cli_usage()))
  }
  cmd <- args[[1]]
  work <- ph_flag_value(args, "--work")
  quiet <- ph_has_flag(args, "--quiet")

  out <- switch(
    cmd,
    init = ph_init(work %||% ph_work_dir_default(),
                   photo_root = ph_flag_value(args, "--photos"),
                   overwrite = ph_has_flag(args, "--overwrite")),
    index = ph_index(work, quiet = quiet),
    render = ph_render_all(work, force = ph_has_flag(args, "--force"),
                           quiet = quiet),
    app = ph_app(work, port = as.integer(ph_flag_value(args, "--port", 7655L)),
                 launch_browser = TRUE),
    go = ph_go(work, port = as.integer(ph_flag_value(args, "--port", 7655L)),
               launch_browser = TRUE),
    status = ph_status(work),
    preflight = ph_preflight(quiet = quiet),
    transcribe = ph_transcribe_all(work, force = ph_has_flag(args, "--force"),
                                   quiet = quiet),
    {
      message("phostor: unknown command '", cmd, "'")
      ph_cli_usage()
      invisible(NULL)
    })
  invisible(out)
}

# `init` is the one command that may be run before a work directory exists, so
# it cannot ask ph_work_dir() to find one.
ph_work_dir_default <- function() {
  na_if_empty(Sys.getenv("PHOSTOR_WORK")) %||% getwd()
}
