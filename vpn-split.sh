#!/bin/bash
# vpn-split.sh — strip Check Point "hub mode" tiling routes, keep only needed routes on the VPN.
# Usage:  sudo ./vpn-split.sh [--dry-run]
# Revert: sudo ./vpn-restore.sh   (or just disconnect/reconnect the VPN)
set -euo pipefail

# ----- EDIT ME: what MUST go via the VPN -------------------------------------
NEEDED_ROUTES=(
  10.25.0.0/16       # internal (10.25.5.22, 10.25.8.118 app server, 10.25.6.x ...)
  10.26.0.0/16       # QA database db.internal.example.com = 10.26.4.27; also 10.26.4.221, 10.26.4.31
  # 10.210.0.7/32
  # 10.82.129.188/32
  # 10.226.21.4/32
)
# -----------------------------------------------------------------------------

DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
BASE="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$BASE/backups/$TS"

if [[ $DRY -eq 0 && $EUID -ne 0 ]]; then echo "run with sudo (or --dry-run)"; exit 1; fi

# --- detect VPN interface + gateway from the point-to-point link route (UHr) ---
read -r VPN_GW VPN_LOCAL VPN_IF < <(netstat -rn -f inet | awk '$3 ~ /^UHr$/ && $4 ~ /^utun/ {print $1, $2, $4; exit}')
if [[ -z "${VPN_IF:-}" ]]; then echo "No Check Point tunnel link route (UHr on utunN) found. Is the VPN connected?"; exit 1; fi
echo "VPN interface: $VPN_IF   gateway: $VPN_GW   local: $VPN_LOCAL"

# --- backup everything first ---------------------------------------------------
mkdir -p "$BK"
netstat -rn                > "$BK/netstat-rn.before.txt"
scutil --dns               > "$BK/scutil-dns.before.txt"
ifconfig "$VPN_IF"         > "$BK/ifconfig-$VPN_IF.txt"
echo "$VPN_IF $VPN_GW $VPN_LOCAL" > "$BK/vpn-if.txt"
: > "$BK/deleted_routes.txt"; : > "$BK/added_routes.txt"; : > "$BK/commands.log"
echo "Backup dir: $BK"

run() { echo "+ $*" >> "$BK/commands.log"; echo "+ $*" >&2; [[ $DRY -eq 1 ]] || "$@"; }

# netstat prints abbreviated destinations (8/7, 11, 255.255.254, 10.0.188.2/31). Expand to full CIDR.
expand() { # $1=dest $2=flags  -> prints "host X.X.X.X" or "net X.X.X.X/len"
  local d="$1" f="$2" ip len a b c e
  if [[ "$d" == */* ]]; then ip="${d%/*}"; len="${d#*/}"; else ip="$d"; len=""; fi
  IFS=. read -r a b c e <<<"$ip"; ip="${a}.${b:-0}.${c:-0}.${e:-0}"
  if [[ -z "$len" ]]; then
    if [[ "$f" == *H* ]]; then echo "host $ip"; return; fi
    # classful default mask, same as netstat's abbreviation
    if (( a < 128 )); then len=8; elif (( a < 192 )); then len=16; else len=24; fi
  fi
  echo "net $ip/$len"
}

# --- delete every route on the VPN interface except the link route -------------
echo "--- deleting tiling routes on $VPN_IF"
n=0
while read -r dest gw flags netif _; do
  [[ "$flags" == "UHr" ]] && continue          # keep the tunnel's own link route
  spec="$(expand "$dest" "$flags")"; kind="${spec%% *}"; cidr="${spec#* }"
  echo "$kind $cidr $gw" >> "$BK/deleted_routes.txt"
  run route -n delete -"$kind" "$cidr" "$gw" >/dev/null || echo "  (failed to delete $cidr, continuing)"
  n=$((n+1))
done < <(netstat -rn -f inet | awk -v IF="$VPN_IF" '$4==IF {print $1, $2, $3, $4}')
echo "deleted $n routes (list in $BK/deleted_routes.txt)"

# --- re-add only what we need ---------------------------------------------------
echo "--- adding needed routes via $VPN_GW"
for r in "${NEEDED_ROUTES[@]}"; do
  kind=net; [[ "$r" == */32 ]] && { kind=host; r="${r%/32}"; }
  echo "$kind $r $VPN_GW" >> "$BK/added_routes.txt"
  run route -n add -"$kind" "$r" "$VPN_GW" >/dev/null
done

[[ $DRY -eq 1 ]] && { echo "DRY RUN — nothing changed."; exit 0; }
netstat -rn > "$BK/netstat-rn.after.txt"

# --- verify ---------------------------------------------------------------------
echo "--- verify"
echo -n "public IP now: "; curl -s --max-time 8 ifconfig.me || echo "(curl failed)"; echo
echo "remaining routes on $VPN_IF: $(netstat -rn -f inet | awk -v IF="$VPN_IF" '$4==IF' | wc -l | tr -d ' ')"
for r in "${NEEDED_ROUTES[@]}"; do echo -n "route get ${r%/*}: "; route -n get "${r%/*}" 2>/dev/null | awk '/interface/ {print $2}'; done
echo
echo "Now wait 2-5 min and run ./vpn-check.sh — if the ~90 routes are back, Check Point re-enforces them."
echo "Revert: sudo $BASE/vpn-restore.sh $TS"
