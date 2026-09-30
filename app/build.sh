#!/bin/bash
# build.sh — compile the A-Train menu bar app into app/build/ and launch it. No sudo needed.
# Requires Xcode (swiftc). Rebuild and rerun after changing anything in Sources/.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
# Builds go to app/build/ by default: the installed app lives in /Applications (from the .pkg), and a second
# copy in ~/Applications made Installer relocate onto it (2026-09-27). ATRAIN_APP_DIR overrides.
APP="${ATRAIN_APP_DIR:-$HERE/build}/A-Train.app"
if [[ -e "$APP" && ! -w "$APP/Contents/MacOS" ]]; then
  echo "note: $APP is not writable; building into $HERE/build/ instead"
  APP="$HERE/build/A-Train.app"
fi
mkdir -p "$(dirname "$APP")"
echo "$APP" > "$HERE/.last-build-path"
BIN="$APP/Contents/MacOS/A-Train"

bash "$HERE/video/fetch.sh"                    # background clip: downloaded once, never stored in git
pkill -x "A-Train" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# universal binary (Apple Silicon + Intel) so the app can be shared
TMP="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -module-name ATrain -target "$arch-apple-macos13.0" ${ATRAIN_TESTHOOKS:+-D ATRAIN_TESTHOOKS} \
    -framework AppKit -framework ServiceManagement -framework Security -framework SwiftUI -framework AVFoundation -framework CoreImage -framework UserNotifications \
    -o "$TMP/A-Train-$arch" Sources/*.swift 2>&1 | grep -v DVTFilePathFSEvents || true
  [[ -x "$TMP/A-Train-$arch" ]] || { echo "build failed for $arch"; exit 1; }
done
lipo -create "$TMP/A-Train-arm64" "$TMP/A-Train-x86_64" -output "$BIN"
rm -rf "$TMP"
cp Info.plist "$APP/Contents/Info.plist"
# build number = build time, so receipts / About / pkg versions can tell builds apart (CFBundleShortVersionString stays 1.0)
plutil -replace CFBundleVersion -string "$(date +%Y%m%d.%H%M)" "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: see icon/make-icon.sh
cp icon/menubar/menu-*.png "$APP/Contents/Resources/"          # menu bar template icons (icon/menubar/*.svg)
if [[ -f video/atrain.mp4 ]]; then cp video/atrain.mp4 "$APP/Contents/Resources/atrain.mp4"; echo "bundled background video"; else rm -f "$APP/Contents/Resources/atrain.mp4"; fi
touch "$APP"                                                  # nudge Finder/Launchpad to refresh the icon
codesign --force --sign - "$APP" 2>&1 | grep -v 'replacing existing signature' || true
echo "built $APP"
open "$APP"
echo "A-Train is in the menu bar (shield icon). Quit it from its menu any time; the daemon keeps running."
