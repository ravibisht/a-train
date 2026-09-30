#!/bin/bash
# install.sh — install the vpnsplitd root daemon.   Usage: sudo ~/vpn-split/install.sh
# - creates ~/vpn-split/config/{routes.conf,control.json} owned by you (if missing)
# - copies daemon/vpnsplitd.py to /usr/local/vpn-split (root-owned; nothing you run as a user can alter it)
# - loads /Library/LaunchDaemons/com.ravi.vpnsplitd.plist (starts at boot, restarted if it dies)
# Undo: sudo ~/vpn-split/uninstall.sh      Menu bar app: bash ~/vpn-split/app/build.sh (no sudo)
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "run with sudo"; exit 1; }
USER_NAME="${VPNSPLIT_USER:-${SUDO_USER:-}}"      # VPNSPLIT_USER: set by the .pkg postinstall
[[ -z "$USER_NAME" || "$USER_NAME" == root ]] && { echo "run this with sudo from your own account"; exit 1; }
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"   # not awk: homes may contain spaces
SRC="$(cd "$(dirname "$0")" && pwd)"
VHOME="$USER_HOME/vpn-split"
CONF="$VHOME/config"
DST=/usr/local/vpn-split
LABEL=com.ravi.vpnsplitd
PLIST=/Library/LaunchDaemons/$LABEL.plist
LOG=/var/log/vpnsplitd.log

# --- find a Python 3 that actually runs. /usr/bin/python3 is only a stub until Xcode's Command Line
#     Tools are installed; on such a Mac it pops a dialog and exits non-zero.
PY=""
for cand in /usr/bin/python3 /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
            /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if [[ -x "$cand" ]] && "$cand" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
if [[ -z "$PY" ]]; then
  cat <<'MSG'
No working Python 3 (3.9+) found. macOS ships one, but only after Apple's Command Line Tools are installed.
Run this, accept the dialog, wait for it to finish (a few minutes), then run the installer again:

    xcode-select --install

(Alternatively install Python 3 from python.org or Homebrew.)
MSG
  exit 1
fi
echo "using python: $PY ($("$PY" -I -c 'import platform; print(platform.python_version())'))"
"$PY" "$SRC/daemon/vpnsplitd.py" --self-test

mkdir -p "$CONF" "$DST/backups"
[[ -f "$CONF/routes.conf" ]]  || cp "$SRC/daemon/routes.conf.example" "$CONF/routes.conf"
[[ -f "$CONF/control.json" ]] || echo '{"mode": "split", "full_until": null}' > "$CONF/control.json"
[[ -f "$CONF/checks.conf" || ! -f "$SRC/daemon/checks.conf.example" ]] || cp "$SRC/daemon/checks.conf.example" "$CONF/checks.conf"
chown -R "$USER_NAME":staff "$CONF"
chmod 755 "$DST" "$DST/backups"
install -o root -g wheel -m 755 "$SRC/daemon/vpnsplitd.py" "$DST/vpnsplitd.py"
touch "$LOG"; chmod 644 "$LOG"
# rotate the log: keep 5 archives, rotate at 2 MB, bzip2-compressed (newsyslog runs from launchd daily)
echo "$LOG  644  5  2000  *  J" > /etc/newsyslog.d/vpnsplitd.conf

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>$LABEL</string>
  <key>ProgramArguments</key> <array><string>$PY</string><string>-u</string><string>$DST/vpnsplitd.py</string></array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>          <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>VPNSPLIT_HOME</key> <string>$VHOME</string>
    <key>VPNSPLIT_STATE</key><string>$DST</string>
  </dict>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

launchctl bootout system/$LABEL 2>/dev/null || true
launchctl bootstrap system "$PLIST"
# --- verify it really came up (status.json is rewritten by the daemon on start)
rm -f "$DST/status.json"
ok=""
for i in $(seq 1 15); do
  sleep 1
  if [[ -s "$DST/status.json" ]] && launchctl print system/$LABEL 2>/dev/null | grep -q 'state = running'; then ok=1; break; fi
done
echo "--- daemon:"; launchctl print system/$LABEL | grep -E 'state|pid|last exit' | head -3
echo "--- log tail:"; tail -n 8 "$LOG"
if [[ -z "$ok" ]]; then
  echo
  echo "WARNING: the daemon did not report status within 15 s. Check the log above; common causes:"
  echo "  - Python could not start (see the first lines of the log)"
  echo "  - another program owns /usr/local/vpn-split (permissions)"
  echo "You can re-run this installer any time; it is safe to repeat."
  exit 2
fi
echo
echo "installed. config: $CONF   status: $DST/status.json   log: $LOG"
echo "next: bash $VHOME/app/build.sh   (builds + opens the menu bar app, no sudo)"
