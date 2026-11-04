#!/bin/bash
# Rasterises the menu-bar glyphs (Resources/MenuBar/*.svg, 16 x 18 pt, black on transparent)
# into Sources/RelayUI/Resources/MenuBar at @1x and @2x. Needs rsvg-convert (brew install librsvg).
# The app loads the PNGs as template images, so macOS tints them for the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Sources/RelayUI/Resources/MenuBar
mkdir -p "$OUT"
for svg in Resources/MenuBar/*.svg; do
  name="$(basename "$svg" .svg)"
  rsvg-convert -w 16 -h 18 "$svg" -o "$OUT/$name.png"
  rsvg-convert -w 32 -h 36 "$svg" -o "$OUT/$name@2x.png"
done
echo "menubar-glyphs: $(ls "$OUT" | tr '\n' ' ')"
