#!/bin/bash
# make-dmg.sh — build a shareable A-Train-<version>.dmg with the app, the daemon tooling, docs and an installer.
# Usage: bash ~/vpn-split/dist/make-dmg.sh     -> ~/vpn-split/dist/A-Train-<version>.dmg (+ copy on the Desktop)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # ~/vpn-split
DIST="$ROOT/dist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/app/Info.plist")"
STAGE="$(mktemp -d)/A-Train"
mkdir -p "$STAGE/payload"

echo "- building installer package (also builds the app)"
bash "$DIST/make-pkg.sh" | sed 's/^/    /'
cp "$DIST/A-Train-$VERSION.pkg" "$STAGE/Install A-Train.pkg"
# The Terminal fallback (Install A-Train.command + raw payload) doubles the DMG; off by default now that
# the .pkg is the installer. ATRAIN_DMG_FALLBACK=1 puts it back.
if [[ "${ATRAIN_DMG_FALLBACK:-0}" == "1" ]]; then
cp -R "$(cat "$ROOT/app/.last-build-path" 2>/dev/null || echo "$HOME/Applications/A-Train.app")" "$STAGE/payload/A-Train.app"
# The background clip ships in the DMG (Ravi's call, 2026-09-25). Set ATRAIN_DMG_VIDEO=0 to leave it out.
if [[ "${ATRAIN_DMG_VIDEO:-1}" == "0" && -f "$STAGE/payload/A-Train.app/Contents/Resources/atrain.mp4" ]]; then
  rm -f "$STAGE/payload/A-Train.app/Contents/Resources/atrain.mp4"
  codesign --force --sign - "$STAGE/payload/A-Train.app" 2>/dev/null || true
  echo "- background video left out of the DMG (ATRAIN_DMG_VIDEO=0)"
elif [[ -f "$STAGE/payload/A-Train.app/Contents/Resources/atrain.mp4" ]]; then
  echo "- background video included in the DMG"
fi

echo "- staging tooling and docs"
rsync -a --exclude 'config/' --exclude 'backups/' --exclude 'dist/' --exclude '.git/' --exclude '.github/' --exclude '.DS_Store' --exclude 'app/build/' "$ROOT/" "$STAGE/payload/vpn-split/"
rsync -a --exclude '.DS_Store' "$ROOT/docs/" "$STAGE/payload/VPN-docs/"
cp "$DIST/payload/install-atrain.sh" "$STAGE/payload/install-atrain.sh"
cp "$DIST/payload/README.txt" "$STAGE/README.txt"
if ls "$DIST"/checkpoint/*.pkg >/dev/null 2>&1; then
  mkdir -p "$STAGE/payload/checkpoint"; cp "$DIST"/checkpoint/*.pkg "$STAGE/payload/checkpoint/"
  echo "- Check Point client package bundled: $(ls "$DIST"/checkpoint/*.pkg | xargs -n1 basename | tr '\n' ' ')"
else
  echo "- no Check Point package in dist/checkpoint/ (optional): DMG will not install the VPN client"
fi
cat > "$STAGE/Install A-Train.command" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")" && exec bash payload/install-atrain.sh
EOF
chmod +x "$STAGE/Install A-Train.command" "$STAGE/payload/install-atrain.sh"

else
  rmdir "$STAGE/payload" 2>/dev/null || true
  cp "$DIST/payload/README.txt" "$STAGE/README.txt"
  echo "- Terminal fallback left out (ATRAIN_DMG_FALLBACK=1 to include)"
fi

echo "- creating dmg"
OUT="$DIST/A-Train-$VERSION.dmg"
rm -f "$OUT"
cp "$ROOT/app/icon/AppIcon.icns" "$STAGE/.VolumeIcon.icns" && SetFile -a C "$STAGE" 2>/dev/null || true   # A-Train icon on the mounted volume
hdiutil create -volname "A-Train" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
APP_ID="${ATRAIN_SIGN_APP:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
NOTARY="${ATRAIN_NOTARY_PROFILE:-ATRAIN_NOTARY}"
if [[ -n "$APP_ID" ]]; then
  codesign --sign "$APP_ID" --timestamp "$OUT" && echo "- dmg signed"
  if xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    echo "- notarizing dmg"; xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY" --wait && xcrun stapler staple "$OUT"
  fi
fi
cp "$OUT" "$HOME/Desktop/" 2>/dev/null && echo "- copied to ~/Desktop"
# a zipped pkg travels through mail/chat services that strip or block .pkg and .dmg attachments
(cd "$DIST" && ditto -c -k --keepParent "A-Train-$VERSION.pkg" "A-Train-$VERSION.pkg.zip") && cp "$DIST/A-Train-$VERSION.pkg.zip" "$HOME/Desktop/" && echo "- zipped pkg for sending: A-Train-$VERSION.pkg.zip"
# archive copy per build, so an older DMG is never lost when the fixed-name one is overwritten
mkdir -p "$DIST/archive" && cp "$OUT" "$DIST/archive/A-Train-$VERSION-build$(plutil -extract CFBundleVersion raw "$(cat "$ROOT/app/.last-build-path")/Contents/Info.plist").dmg" && echo "- archived in dist/archive/"
rm -rf "$(dirname "$STAGE")"
# version.json for the in-app update check: host it anywhere (ATRAIN_UPDATE_URL = where the DMG will live)
BUILD="$(plutil -extract CFBundleVersion raw "$(cat "$ROOT/app/.last-build-path" 2>/dev/null || echo "$HOME/Applications/A-Train.app")/Contents/Info.plist" 2>/dev/null || echo 0)"
cat > "$DIST/version.json" <<JSON
{"version": "$VERSION", "build": "$BUILD", "url": "${ATRAIN_UPDATE_URL:-https://example.invalid/A-Train-$VERSION.dmg}", "notes": "${ATRAIN_UPDATE_NOTES:-}"}
JSON
echo "- wrote dist/version.json (build $BUILD); upload it next to the DMG and set that URL in A-Train > Settings > Updates"
ls -la "$OUT"
echo "share: $OUT"
