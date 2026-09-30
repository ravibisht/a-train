#!/bin/bash
# make-pkg.sh — build the A-Train installer package (double-click -> Installer.app -> password -> done).
# Usage: bash ~/vpn-split/dist/make-pkg.sh        -> ~/vpn-split/dist/A-Train-<version>.pkg
#
# Signing / notarization happen automatically when the pieces exist on this Mac, and are skipped otherwise:
#   - "Developer ID Application" identity in the login keychain   -> app signed with hardened runtime
#   - "Developer ID Installer" identity                            -> pkg signed
#   - notarytool keychain profile (ATRAIN_NOTARY_PROFILE, default ATRAIN_NOTARY):
#         xcrun notarytool store-credentials ATRAIN_NOTARY --apple-id <id> --team-id <TEAM> --password <app-specific pw>
#                                                                 -> pkg notarized and stapled
# Both identities come from a paid Apple Developer Program membership (Certificates > Developer ID).
# Override auto-detection with ATRAIN_SIGN_APP="Developer ID Application: …" / ATRAIN_SIGN_INSTALLER="…".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/app/Info.plist")"
OUT="$DIST/A-Train-$VERSION.pkg"
WORK="$(mktemp -d)"
STAGE="$WORK/root"
mkdir -p "$STAGE/Applications" "$STAGE/usr/local/vpn-split/pkg"

APP_ID="${ATRAIN_SIGN_APP:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
INST_ID="${ATRAIN_SIGN_INSTALLER:-$(security find-identity -v 2>/dev/null | grep -o '"Developer ID Installer: [^"]*"' | head -1 | tr -d '"' || true)}"
NOTARY="${ATRAIN_NOTARY_PROFILE:-ATRAIN_NOTARY}"
HAS_NOTARY=""; xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1 && HAS_NOTARY=1

if [[ "${ATRAIN_SKIP_BUILD:-}" != "1" ]]; then
  echo "- building universal app"
  bash "$ROOT/app/build.sh" >/dev/null
fi
BUILT="$(cat "$ROOT/app/.last-build-path" 2>/dev/null || echo "$HOME/Applications/A-Train.app")"
[[ -d "$BUILT" ]] || { echo "no built app at $BUILT (run app/build.sh)"; exit 1; }
echo "- packaging $BUILT"
cp -R "$BUILT" "$STAGE/Applications/A-Train.app"
BUILD="$(plutil -extract CFBundleVersion raw "$STAGE/Applications/A-Train.app/Contents/Info.plist" 2>/dev/null || echo 1)"
echo "- app $VERSION build $BUILD"
if [[ "${ATRAIN_DMG_VIDEO:-1}" == "0" ]]; then rm -f "$STAGE/Applications/A-Train.app/Contents/Resources/atrain.mp4"; fi
if [[ -n "$APP_ID" ]]; then
  echo "- signing app with: $APP_ID"
  codesign --force --deep --options runtime --timestamp --sign "$APP_ID" "$STAGE/Applications/A-Train.app"
else
  codesign --force --deep --sign - "$STAGE/Applications/A-Train.app"      # ad-hoc: Gatekeeper will need Open Anyway
fi
codesign --verify --deep --strict "$STAGE/Applications/A-Train.app"

echo "- staging tooling and docs"
rsync -a --exclude 'config/' --exclude 'backups/' --exclude 'dist/' --exclude '.git/' --exclude '.github/' --exclude '.DS_Store' --exclude '__pycache__' \
  --exclude 'app/build/' --exclude 'app/.last-build-path' "$ROOT/" "$STAGE/usr/local/vpn-split/pkg/vpn-split/"
rsync -a --exclude '.DS_Store' "$ROOT/docs/" "$STAGE/usr/local/vpn-split/pkg/VPN-docs/"   # docs/ in the repo -> ~/VPN-docs on the target
if ls "$DIST"/checkpoint/*.pkg >/dev/null 2>&1; then
  mkdir -p "$STAGE/usr/local/vpn-split/pkg/checkpoint"; cp "$DIST"/checkpoint/*.pkg "$STAGE/usr/local/vpn-split/pkg/checkpoint/"
  echo "- Check Point client package bundled"
fi
# Internal build: dist/profile/ (gitignored) overrides the public example defaults
if [[ -d "$DIST/profile" ]]; then
  [[ -f "$DIST/profile/routes.conf" ]] && cp "$DIST/profile/routes.conf" "$STAGE/usr/local/vpn-split/pkg/vpn-split/daemon/routes.conf.example"
  [[ -f "$DIST/profile/checks.conf" ]] && cp "$DIST/profile/checks.conf" "$STAGE/usr/local/vpn-split/pkg/vpn-split/daemon/checks.conf.example"
  [[ -f "$DIST/profile/sites.txt" ]]   && cp "$DIST/profile/sites.txt"   "$STAGE/usr/local/vpn-split/pkg/vpn-split/daemon/sites.txt"
  echo "- company profile applied from dist/profile/ (internal build)"
else
  echo "- no dist/profile/: public build with example.com defaults"
fi
chmod -R go-w "$STAGE/usr/local/vpn-split/pkg"
xattr -cr "$STAGE"                      # no AppleDouble (._*) junk in the payload; bundle signatures live in _CodeSignature
codesign --verify --deep --strict "$STAGE/Applications/A-Train.app"

echo "- building component package"
cp -R "$DIST/pkg/scripts" "$WORK/scripts"; chmod +x "$WORK/scripts"/*
# Installer "relocates" a bundle onto any existing copy with the same bundle id (it put the app into
# ~/Applications on 2026-09-27). BundleIsRelocatable=false pins it to /Applications.
pkgbuild --analyze --root "$STAGE" "$WORK/components.plist" >/dev/null
/usr/bin/python3 -I - "$WORK/components.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f: items = plistlib.load(f)
for it in items:
    it["BundleIsRelocatable"] = False          # every bundle pkgbuild found (the app, and the app sources folder)
    it["BundleIsVersionChecked"] = False        # always install our build, even over a "newer" CFBundleVersion
with open(p, "wb") as f: plistlib.dump(items, f)
print("- component plist: %d bundle(s) pinned, not relocatable" % len(items))
PY
pkgbuild --root "$STAGE" --scripts "$WORK/scripts" --component-plist "$WORK/components.plist" \
  --identifier com.ravi.atrain.pkg --version "$VERSION.$BUILD" --install-location / --ownership recommended \
  "$WORK/A-Train-component.pkg" >/dev/null

bash "$DIST/pkg/make-background.sh"
echo "- building installer"
sed "s/__VERSION__/$VERSION.$BUILD/" "$DIST/pkg/distribution.xml" > "$WORK/distribution.xml"
rm -f "$OUT"
SIGN=()
if [[ -n "$INST_ID" ]]; then SIGN=(--sign "$INST_ID" --timestamp); echo "- signing installer with: $INST_ID"; fi
productbuild --distribution "$WORK/distribution.xml" --resources "$DIST/pkg/resources" --package-path "$WORK" \
  ${SIGN[@]+"${SIGN[@]}"} "$OUT" >/dev/null       # bash 3.2 + set -u safe when SIGN is empty

if [[ -n "$INST_ID" && -n "$HAS_NOTARY" ]]; then
  echo "- notarizing (this takes a few minutes)"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$OUT"
  echo "- notarized and stapled: recipients just double-click"
elif [[ -n "$INST_ID" ]]; then
  echo "- signed but NOT notarized (no notarytool profile '$NOTARY'): Gatekeeper may still warn on macOS 15+"
else
  echo "- UNSIGNED package: recipients must allow it once in System Settings > Privacy & Security (Open Anyway)"
fi
rm -rf "$WORK"
pkgutil --check-signature "$OUT" 2>/dev/null | head -3 || true
ls -la "$OUT"
echo "pkg: $OUT"
