#!/bin/bash
# vpn-restore.sh — re-add routes deleted by vpn-split.sh from a backup (default: latest).
# Usage: sudo ./vpn-restore.sh [backup-timestamp]
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -ne 0 ]] && { echo "run with sudo"; exit 1; }
TS="${1:-$(ls -1 "$BASE/backups" | sort | tail -1)}"
BK="$BASE/backups/$TS"
[[ -f "$BK/deleted_routes.txt" ]] || { echo "no backup at $BK"; exit 1; }
read -r VPN_IF VPN_GW _ < "$BK/vpn-if.txt"
echo "Restoring from $BK (interface was $VPN_IF, gw $VPN_GW)"
if ! netstat -rn -f inet | awk '$3=="UHr"{print $1}' | grep -qx "$VPN_GW"; then
  echo "WARNING: tunnel gateway $VPN_GW is not up now. VPN probably reconnected and restored itself. Aborting."; exit 1
fi
# remove the specific routes we added
while read -r kind cidr gw; do route -n delete -"$kind" "$cidr" "$gw" >/dev/null 2>&1 || true; done < "$BK/added_routes.txt"
# re-add everything we deleted
n=0; while read -r kind cidr gw; do
  route -n add -"$kind" "$cidr" "$gw" >/dev/null 2>&1 || echo "  (could not re-add $cidr; may already exist)"; n=$((n+1))
done < "$BK/deleted_routes.txt"
echo "re-added $n routes. Routes on $VPN_IF now: $(netstat -rn -f inet | awk -v IF="$VPN_IF" '$4==IF' | wc -l | tr -d ' ')"
echo -n "public IP now: "; curl -s --max-time 8 ifconfig.me; echo
