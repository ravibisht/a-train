#!/bin/bash
# vpn-check.sh [host ...] — show VPN interface, route count, public IP, and which interface each host would use.
read -r VPN_GW VPN_LOCAL VPN_IF < <(netstat -rn -f inet | awk '$3 ~ /^UHr$/ && $4 ~ /^utun/ {print $1, $2, $4; exit}')
[[ -z "$VPN_IF" ]] && { echo "VPN not connected (no UHr utun route)"; exit 0; }
echo "VPN if: $VPN_IF  gw: $VPN_GW"
echo "routes on $VPN_IF: $(netstat -rn -f inet | awk -v IF="$VPN_IF" '$4==IF' | wc -l | tr -d ' ')   (full hub-mode tiling is ~90)"
echo -n "public IP: "; curl -s --max-time 8 ifconfig.me; echo "   (203.0.113.10 = via VPN)"
for h in "$@"; do echo -n "route to $h: "; route -n get "$h" 2>/dev/null | awk '/interface/ {print $2}'; done
netstat -rn -f inet | awk -v IF="$VPN_IF" '$4==IF'
