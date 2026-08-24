#!/usr/bin/env bash
# End-to-end tests for phostor's browser half -- the microphone, MediaRecorder,
# the chunk upload and the playback clock. None of it is reachable from the R
# suite, which fakes the browser entirely.
#
# Opt-in and developer-only: needs Node and a one-time `npm install` here.
# `.Rbuildignore` keeps it out of the package, so R CMD check never sees it.
#
#   tests/browser/run.sh                 every browser, every spec
#   tests/browser/run.sh --headed        watch it happen
#   tests/browser/run.sh 01-sitting      one spec file
#
# Chrome is used as installed. Firefox needs Playwright's own build:
#   npx --prefix tests/browser playwright install firefox
# If it is absent, Firefox is skipped and said so, rather than failing.
#
# Each browser gets its OWN photo collection, work directory and phostor
# instance. The specs assert on files -- "three sidecars exist" -- so sharing a
# work directory between browsers would have the second one counting the
# first's recordings.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
base_port="${PHOSTOR_PORT:-7699}"

for tool in Rscript vips node npx curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "need $tool on PATH" >&2; exit 1; }
done
[ -d "/Applications/Google Chrome.app" ] || {
  echo "need Google Chrome installed (playwright uses channel: chrome)" >&2
  exit 1
}
[ -d "$here/node_modules" ] || {
  echo "first run: installing playwright into $here" >&2
  (cd "$here" && npm install --silent)
}

tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# Which browsers can we actually drive?
projects=(chrome)
if [ -d "$HOME/Library/Caches/ms-playwright" ] &&
   ls "$HOME/Library/Caches/ms-playwright" 2>/dev/null | grep -q '^firefox-'; then
  projects+=(firefox)
else
  echo "note: firefox skipped -- npx --prefix tests/browser playwright install firefox"
fi

status=0
port="$base_port"

for proj in "${projects[@]}"; do
  photos="$tmp/$proj/photos"
  work="$tmp/$proj/work"
  mkdir -p "$photos/Trips/Skye" "$photos/Prague"

  echo "==> [$proj] building a fixture collection"
  gen() {
    vips gaussnoise "$photos/_t.v" "$2" "$3" >/dev/null 2>&1
    vips copy "$photos/_t.v" "$1" >/dev/null 2>&1
  }
  gen "$photos/top.jpg"              600 400
  gen "$photos/Trips/Skye/a b.jpg"   500 380
  gen "$photos/Trips/Skye/c&d.jpg"   420 320
  gen "$photos/Prague/bridge.jpg"    480 360
  gen "$photos/Prague/square.png"    360 360
  rm -f "$photos/_t.v"

  # Every byte of the collection, so the read-only invariant can be proved
  # after a browser has driven a whole sitting against it.
  before="$tmp/$proj-before.sha"
  find "$photos" -type f -exec shasum -a 256 {} \; | sort > "$before"

  echo "==> [$proj] preparing the project"
  Rscript -e "
    if (requireNamespace('phostor', quietly = TRUE)) library(phostor) else
      pkgload::load_all('$root', quiet = TRUE)
    suppressMessages(ph_init('$work', photo_root = '$photos',
                             title = 'Browser test collection',
                             min_visit_seconds = 0, chunk_seconds = 1))
    cfg <- ph_config('$work')
    suppressMessages(ph_index(cfg, quiet = TRUE))
    suppressMessages(ph_render_all(cfg, quiet = TRUE))
  " >/dev/null

  echo "==> [$proj] starting phostor on port $port"
  Rscript -e "
    if (requireNamespace('phostor', quietly = TRUE)) library(phostor) else
      pkgload::load_all('$root', quiet = TRUE)
    ph_app('$work', port = ${port}L, launch_browser = FALSE)
  " > "$tmp/$proj-server.log" 2>&1 &
  server_pid=$!

  for _ in $(seq 1 120); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then break; fi
    kill -0 "$server_pid" 2>/dev/null || { cat "$tmp/$proj-server.log" >&2; exit 1; }
    sleep 0.5
  done
  curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null || {
    echo "phostor did not start:" >&2; cat "$tmp/$proj-server.log" >&2; exit 1; }

  echo "==> [$proj] running the specs"
  PHOSTOR_WORK="$work" PHOSTOR_PHOTOS="$photos" \
  PHOSTOR_URL="http://127.0.0.1:$port" \
    npx --prefix "$here" playwright test \
        --config "$here/playwright.config.js" --project="$proj" "$@" || status=$?

  echo "==> [$proj] the photo directory must be untouched"
  after="$tmp/$proj-after.sha"
  find "$photos" -type f -exec shasum -a 256 {} \; | sort > "$after"
  if diff -q "$before" "$after" >/dev/null; then
    echo "    identical, $(wc -l < "$before" | tr -d ' ') files, byte for byte"
  else
    echo "    PHOTOGRAPHS WERE MODIFIED:" >&2
    diff "$before" "$after" >&2
    status=1
  fi

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  port=$((port + 1))
done

if [ "$status" -eq 0 ]; then
  echo "==> browser tests passed (${projects[*]})"
else
  echo "==> FAILED" >&2
fi
exit "$status"
