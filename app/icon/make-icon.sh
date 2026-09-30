#!/bin/bash
# make-icon.sh — render atrain.svg into AppIcon.icns (all macOS sizes) + preview.png. Needs rsvg-convert (brew).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p AppIcon.iconset
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s atrain.svg -o "AppIcon.iconset/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) atrain.svg -o "AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rsvg-convert -w 512 -h 512 atrain.svg -o preview.png
echo "AppIcon.icns updated; run ../build.sh to rebuild the app with it"
