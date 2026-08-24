# Lightweight base-R progress feedback. Everything goes to stderr, so captured
# stdout and return values are unaffected, and animation is used only when
# stderr is a terminal -- redirected output falls back to milestone lines.

ph_is_tty <- function() {
  isTRUE(tryCatch(isatty(stderr()), error = function(e) FALSE))
}

ph_step <- function(msg, quiet = FALSE) {
  if (isTRUE(quiet)) return(invisible(NULL))
  message(sprintf("   -> %s", msg))
  invisible(NULL)
}

# Progress reporter over a known total. Returns a list of closures:
#   $tick(n = 1) advance by n; $done() finish.
# TTY -> live txtProgressBar; non-TTY -> a line every ~10%; quiet or a
# non-positive total -> no-ops.
ph_progress <- function(total, label = "", quiet = FALSE) {
  total <- suppressWarnings(as.integer(total))
  noop <- list(tick = function(n = 1L) invisible(NULL),
               done = function() invisible(NULL))
  if (isTRUE(quiet) || is.na(total) || total <= 0L) return(noop)

  cur <- 0L
  # done() is idempotent: callers close the bar explicitly so the summary
  # prints after it, and register an on.exit() so an error does not leave a
  # half-drawn bar on the terminal. Both paths fire on a normal return.
  shut <- FALSE
  if (ph_is_tty()) {
    if (nzchar(label)) message(sprintf("   -> %s (%d)", label, total))
    bar <- utils::txtProgressBar(min = 0L, max = total, style = 3L,
                                 file = stderr())
    list(
      tick = function(n = 1L) {
        cur <<- cur + as.integer(n)
        utils::setTxtProgressBar(bar, min(cur, total))
      },
      done = function() {
        if (shut) return(invisible(NULL))
        shut <<- TRUE
        utils::setTxtProgressBar(bar, total)
        close(bar)
      }
    )
  } else {
    lbl <- if (nzchar(label)) label else "progress"
    last <- -1L
    list(
      tick = function(n = 1L) {
        cur <<- cur + as.integer(n)
        step <- (as.integer(100 * cur / total) %/% 10L) * 10L
        if (step > last && step >= 10L) {
          last <<- step
          message(sprintf("   %s: %d%% (%d/%d)", lbl, step, min(cur, total),
                          total))
        }
      },
      done = function() invisible(NULL)
    )
  }
}
