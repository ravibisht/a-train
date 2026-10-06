#!/bin/bash
# uninstall.sh — stop and remove the vpnsplitd daemon.   Usage: sudo ~/vpn-split/uninstall.sh
# Keeps your config (~/vpn-split/config) and the backups (/usr/local/vpn-split/backups).
# Routes currently in effect are left as they are: disconnect/reconnect the VPN to get the full tunnel back.
# The menu bar app is separate: quit it from its menu and delete ~/Applications/A-Train.app if unwanted.
[[ $EUID -ne 0 ]] && { echo "run with sudo"; exit 1; }
LABEL=com.ravi.vpnsplitd
launchctl bootout system/$LABEL 2>/dev/null && echo "daemon stopped" || echo "daemon was not running"
rm -f /Library/LaunchDaemons/$LABEL.plist /etc/newsyslog.d/vpnsplitd.conf
# remove only the per-domain resolver files we created (they carry our marker on line 1)
if [ -d /etc/resolver ]; then
  for f in /etc/resolver/*; do
    [ -f "$f" ] && head -1 "$f" 2>/dev/null | grep -q 'managed by vpnsplitd' && rm -f "$f" && echo "removed resolver $(basename "$f")"
  done
fi
# if the daemon had the primary service's manual DNS slot set (Full VPN), return it to automatic
if [ -f /usr/local/vpn-split/applied.json ]; then
  svc=$(python3 -c 'import json;d=json.load(open("/usr/local/vpn-split/applied.json"));print(d.get("dns_service") or "" if d.get("dns_slot")=="vpn" else "")' 2>/dev/null)
  [ -n "$svc" ] && networksetup -setdnsservers "$svc" Empty && echo "DNS for $svc back to automatic"
fi
# remove our marked block from /etc/hosts, if present
if grep -q "# >>> vpnsplitd (via local pins" /etc/hosts 2>/dev/null; then
  sed -i '' '/# >>> vpnsplitd (via local pins/,/# <<< vpnsplitd <<</d' /etc/hosts && echo "removed hosts pins"
fi
rm -f /usr/local/vpn-split/vpnsplitd.py /usr/local/vpn-split/status.json /usr/local/vpn-split/status.json.tmp \
      /usr/local/vpn-split/applied.json /usr/local/vpn-split/applied.json.tmp
echo "removed. backups kept in /usr/local/vpn-split/backups, config kept in ~/vpn-split/config."
echo "reconnect the VPN now if you want the original full-tunnel routes back."
