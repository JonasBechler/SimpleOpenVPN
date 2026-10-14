#!/usr/bin/env bash
# vpn-list-clients - show every client, its fixed IPs and whether it is online.
#
# Live sessions are read from the management sockets (instant). If a socket is
# not reachable (instance down, or not running as root) the status file is used,
# which OpenVPN rewrites only every 60 seconds.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env

online_cns() {  # $1 = instance; prints CNs currently connected
  local sock=/run/openvpn-server/mgmt-$1.sock out=""
  if [[ -S $sock && -w $sock ]] && command -v socat >/dev/null; then
    # OpenVPN discards unsent output when it sees 'quit', so give 'status' a moment.
    out=$({ printf 'status 2\n'; sleep 0.5; printf 'quit\n'; } | socat -T3 - "UNIX-CONNECT:$sock" 2>/dev/null || true)
  fi
  if [[ -z $out && -r /run/openvpn-server/status-$1.log ]]; then
    out=$(cat "/run/openvpn-server/status-$1.log")
  fi
  awk -F, '/^CLIENT_LIST/ {print $2}' <<<"$out"
}
udp_on=$(online_cns udp)
tcp_on=$(online_cns tcp443)

{
  printf 'NAME\tUDP %s (split)\tTCP %s (full)\tCREATED\tSTATUS\n' "$UDP_PORT" "$TCP_PORT"
  awk -F, 'NR>1' "$CLIENTS_CSV" | sort -t, -k2,2n | while IFS=, read -r name _ udp_ip tcp_ip created status; do
    u=""; t=""
    grep -qx "$name" <<<"$udp_on" && u=" *"
    grep -qx "$name" <<<"$tcp_on" && t=" *"
    printf '%s\t%s%s\t%s%s\t%s\t%s\n' "$name" "$udp_ip" "$u" "$tcp_ip" "$t" "$created" "$status"
  done
} | if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi
echo
echo "* = connected right now"
