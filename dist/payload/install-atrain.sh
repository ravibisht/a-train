#!/bin/bash
# install-atrain.sh — one-step installer for a colleague's Mac. Run from the mounted DMG:
#     bash "/Volumes/A-Train/Install A-Train.command"      (or double-click that file)
# What it does:
#   1. copies the vpn-split tooling to ~/vpn-split and the guide to ~/VPN-docs (keeps an existing routes.conf)
#   2. copies A-Train.app to /Applications (falls back to ~/Applications) and removes the download quarantine
#   3. installs the root daemon (asks for your Mac password once) and starts it
#   4. opens A-Train
# Requirements: macOS 13 or newer, an admin account, Check Point Endpoint Security VPN. No Xcode needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "A-Train installer"
echo "================="
[[ "$(uname)" == "Darwin" ]] || { echo "macOS only"; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$major" -lt 13 ]]; then echo "A-Train needs macOS 13 or newer (you have $(sw_vers -productVersion))."; exit 1; fi
if [[ ! -x "/Library/Application Support/Checkpoint/Endpoint Connect/trac" ]]; then
  echo "NOTE: Check Point Endpoint Security VPN is not installed (or not where expected)."
  echo "      A-Train installs fine but does nothing until the VPN client is present."
fi
if ! id -Gn | grep -qw admin; then echo "You need an administrator account to install the background service."; exit 1; fi

# 1. tooling + docs
mkdir -p "$HOME/vpn-split" "$HOME/VPN-docs"
if [[ -f "$HOME/vpn-split/config/routes.conf" ]]; then
  echo "- keeping your existing ~/vpn-split/config/routes.conf"
fi
rsync -a --exclude 'config/routes.conf' --exclude 'config/control.json' --exclude 'backups' --exclude 'dist' \
  "$HERE/vpn-split/" "$HOME/vpn-split/"
rsync -a "$HERE/VPN-docs/" "$HOME/VPN-docs/"
chmod +x "$HOME"/vpn-split/*.sh "$HOME"/vpn-split/app/*.sh "$HOME"/vpn-split/daemon/*.py 2>/dev/null || true
echo "- tooling in ~/vpn-split, guide in ~/VPN-docs"

# 1b. Check Point client (only if a package was bundled and the client is missing)
TRAC="/Library/Application Support/Checkpoint/Endpoint Connect/trac"
CPPKG="$(ls "$HERE"/checkpoint/*.pkg 2>/dev/null | head -1 || true)"
if [[ ! -x "$TRAC" && -n "$CPPKG" ]]; then
  echo "- Check Point VPN client is not installed; installing $(basename "$CPPKG") (enter your Mac password)"
  if sudo /usr/bin/installer -pkg "$CPPKG" -target / >/tmp/atrain-checkpoint-install.log 2>&1; then
    echo "  installed. If macOS shows a 'System Extension Blocked' notice, allow it in"
    echo "  System Settings > Privacy & Security, then continue."
    for i in $(seq 1 20); do [[ -x "$TRAC" ]] && break; sleep 1; done
    if [[ -x "$TRAC" ]]; then
      echo "  add your company site in the Check Point app if it is not listed (Options > Sites)"
    fi
  else
    echo "  Check Point install failed; see /tmp/atrain-checkpoint-install.log. Continuing with A-Train only."
  fi
elif [[ ! -x "$TRAC" ]]; then
  echo "- Check Point client not present and no package bundled: A-Train will idle until the VPN client is installed."
fi

# 2. the app
DEST="${ATRAIN_APP_DEST:-/Applications}"          # ATRAIN_APP_DEST overrides (used by tests)
[[ -w "$DEST" || -n "${ATRAIN_APP_DEST:-}" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x "A-Train" 2>/dev/null || true
rm -rf "$DEST/A-Train.app"
cp -R "$HERE/A-Train.app" "$DEST/A-Train.app"
xattr -dr com.apple.quarantine "$DEST/A-Train.app" 2>/dev/null || true
echo "- A-Train.app installed in $DEST"

# 3. the daemon (needs sudo)
if [[ "${ATRAIN_SKIP_DAEMON:-}" == "1" ]]; then
  echo "- skipping daemon install (ATRAIN_SKIP_DAEMON=1)"
else
  echo "- installing the background daemon; enter your Mac password when asked"
  sudo "$HOME/vpn-split/install.sh"
fi

# 4. go
open "$DEST/A-Train.app" 2>/dev/null || true
cat <<EOF

Done. A-Train is the shield icon in your menu bar.
  - Solid italic "A" with speed streaks = split mode: only the routes in ~/vpn-split/config/routes.conf use the VPN
  - Menu > Switch to Full VPN when you need a company website that only allows the office IP
  - Menu > Routes via VPN > Add domain or IP...  to route more through the VPN
Guide: ~/VPN-docs/GUIDE.md      Remove everything: sudo ~/vpn-split/uninstall.sh, then delete A-Train.app
EOF
