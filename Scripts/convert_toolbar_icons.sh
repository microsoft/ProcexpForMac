#!/bin/bash
#
# convert_toolbar_icons.sh — R1
# Convert the Windows Process Explorer toolbar icons (../ProcExp/exe/icons/*.ico)
# into macOS asset-catalog imagesets (18x18 @1x, 36x36 @2x) under
# App/Assets.xcassets. Requires ImageMagick (`magick`).
#
# The source Windows icons are colored (matching Process Explorer's toolbar), so
# color is preserved (no template rendering) for a faithful, legible look.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="/Users/markrussinovich/Source/ProcExp/exe/icons"
DST="$REPO/App/Assets.xcassets"

# assetName sourceIcoBasename (without .ico)
pairs=(
  "save save"
  "refresh refresh"
  "sysinfo sysinfo"
  "tree tree"
  "props process-properties"
  "kill delete"
  "split split"
  "dll dll"
  "handles view-handles"
  "find find"
  "target target"
)

for entry in "${pairs[@]}"; do
  name="${entry%% *}"
  ico="${entry##* }"
  srcfile="$SRC/$ico.ico"
  setdir="$DST/$name.imageset"

  if [[ ! -f "$srcfile" ]]; then
    echo "MISSING  $name  ($srcfile)"
    continue
  fi

  mkdir -p "$setdir"

  # Frame 0 is the largest per `identify`; downscale it for crisp results.
  frame="$srcfile[0]"

  # 1x — 18x18
  magick "$frame" -background none -alpha on \
      -resize 18x18 -gravity center -extent 18x18 \
      "$setdir/$name@1x.png"
  # 2x — 36x36
  magick "$frame" -background none -alpha on \
      -resize 36x36 -gravity center -extent 36x36 \
      "$setdir/$name@2x.png"

  cat > "$setdir/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$name@1x.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "$name@2x.png",
      "idiom" : "mac",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

  echo "OK       $name  <- $ico.ico"
done

echo "Done."
