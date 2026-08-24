#!/usr/bin/env bash
# Build a tiny fixture photo directory: a nested tree, awkward names, EXIF
# dates, and cruft that must be ignored. Nothing is committed -- the images are
# generated, so the repository carries no photographs and the fixtures cannot
# drift out of step with the tools that read them.
#
#   top.jpg                       a photograph at the root
#   Trips/Skye/a b.jpg            a filename with a space, EXIF DateTimeOriginal
#   Trips/Skye/c&d.jpg            a filename needing HTML escaping
#   Trips/x.png                   a different container
#   Odd names/Fran<latin1>.jpg    EXIF Artist carrying raw Latin-1 bytes
#   @eaDir/SYNOPHOTO_THUMB.jpg    cruft, must never be indexed
#   notes.txt                     not a photograph, must never be indexed
#
# Usage: make-fixtures.sh OUTDIR
set -euo pipefail
out="${1:?output dir required}"
rm -rf "$out"
mkdir -p "$out/Trips/Skye" "$out/Odd names" "$out/@eaDir"

gen() {  # gen <path> <w> <h>
  vips gaussnoise "$out/_tmp.v" "$2" "$3" >/dev/null 2>&1
  vips copy "$out/_tmp.v" "$1" >/dev/null 2>&1
}

gen "$out/top.jpg"             120 90
gen "$out/Trips/Skye/a b.jpg"  100 75
gen "$out/Trips/Skye/c&d.jpg"   80 60
gen "$out/Trips/x.png"          64 64
gen "$out/Odd names/latin1.jpg" 96 72

if command -v exiftool >/dev/null 2>&1; then
  exiftool -overwrite_original -q -m \
           -DateTimeOriginal="1974:07:03 14:22:01" \
           "$out/Trips/Skye/a b.jpg" >/dev/null 2>&1 || true
  # CreateDate only: the app must label this as the fallback rather than
  # present a scanning date as though it were the date the picture was taken.
  exiftool -overwrite_original -q -m \
           -CreateDate="2011:02:02 09:00:00" \
           "$out/Trips/Skye/c&d.jpg" >/dev/null 2>&1 || true
  # An EXIF string carrying Latin-1 bytes in a field declared UTF-8, which is
  # what an older camera or editor writes. Indexing must survive it.
  printf -v artist 'Fran\xe7ois'
  exiftool -overwrite_original -q -m -charset exif=UTF8 \
           -Artist="$artist" "$out/Odd names/latin1.jpg" >/dev/null 2>&1 || true
fi

echo "synology thumb cruft" > "$out/@eaDir/SYNOPHOTO_THUMB.jpg"
echo "not a photograph" > "$out/notes.txt"
rm -f "$out/_tmp.v"
echo "fixtures created in $out"
