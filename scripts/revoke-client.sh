#!/usr/bin/env bash
# vpn-revoke-client NAME - revoke a client's certificate and kick it off the VPN.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
NAME="${1:-}"
[[ -n $NAME ]] || die "usage: vpn-revoke-client NAME"
[[ $NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]] || die "invalid client name"
awk -F, -v n="$NAME" 'NR>1 && $1==n && $6=="active" {found=1} END {exit !found}' "$CLIENTS_CSV" \
  || die "no active client named '$NAME'"

cd "$EASYRSA_DIR"
./easyrsa --batch revoke "$NAME"
./easyrsa --batch gen-crl
install -m 644 pki/crl.pem "$SRV_DIR/crl.pem"   # OpenVPN re-reads the CRL on every new connection

rm -f "$SRV_DIR/ccd-udp/$NAME" "$SRV_DIR/ccd-tcp443/$NAME"

# Drop any live session via the management sockets.
for inst in udp tcp443; do
  sock=/run/openvpn-server/mgmt-$inst.sock
  if [[ -S $sock ]]; then
    printf 'kill %s\nquit\n' "$NAME" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1 || true
  fi
done

tmp=$(mktemp)
awk -F, -v OFS=, -v n="$NAME" -v d="revoked $(date -u +%F)" 'NR>1 && $1==n {$6=d} 1' "$CLIENTS_CSV" > "$tmp"
install -m 600 "$tmp" "$CLIENTS_CSV"; rm -f "$tmp"
rm -rf "${OUT_DIR:?}/$NAME"
rm -f "pki/private/$NAME.key" "pki/private/$NAME.tc2" "pki/reqs/$NAME.req"
vpn-dns-update

echo "Client '$NAME' revoked. Its host octet stays reserved in $CLIENTS_CSV."
