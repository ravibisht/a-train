#!/bin/bash
# make-background.sh — render the Installer background images (light + dark, 1x + 2x) from the app icon.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGO="$HERE/../../app/icon/AppIcon.iconset/icon_512x512.png"
OUT="$HERE/resources"
for variant in light dark; do
  name="background"; [[ $variant == dark ]] && name="background-dark"
  swift "$HERE/render-background.swift" "$LOGO" "$OUT/$name.png" "$variant" 1
  swift "$HERE/render-background.swift" "$LOGO" "$OUT/$name@2x.png" "$variant" 2
done
echo "- installer backgrounds rendered in $OUT"
