#!/usr/bin/env bash
# vpn-check-expiry [DAYS] - warn about certificates or the CRL expiring within DAYS (default 30).
# Exit 1 if anything is expiring or expired, so the weekly timer shows up in the journal.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env
days="${1:-30}"
limit=$(( $(date +%s) + days*86400 ))
rc=0

report() {  # label, expiry epoch
  local left=$(( ($2 - $(date +%s)) / 86400 ))
  if (( $2 <= limit )); then
    printf 'WARNING: %-28s expires in %d days\n' "$1" "$left"; rc=1
  else
    printf 'ok:      %-28s %d days left\n' "$1" "$left"
  fi
}
cert_end() { date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s; }

report "CA"                 "$(cert_end "$SRV_DIR/ca.crt")"
report "server certificate" "$(cert_end "$SRV_DIR/server.crt")"
report "CRL"                "$(date -d "$(openssl crl -in "$SRV_DIR/crl.pem" -noout -nextupdate | cut -d= -f2)" +%s)"
awk -F, 'NR>1 && $6=="active" {print $1}' "$CLIENTS_CSV" | while read -r name; do
  f="$EASYRSA_DIR/pki/issued/$name.crt"
  [[ -f $f ]] && report "client $name" "$(cert_end "$f")"
done
# the while loop runs in a subshell; recompute rc from a second pass for the exit code
while read -r name; do
  f="$EASYRSA_DIR/pki/issued/$name.crt"
  [[ -f $f ]] && (( $(cert_end "$f") <= limit )) && rc=1
done < <(awk -F, 'NR>1 && $6=="active" {print $1}' "$CLIENTS_CSV")
if (( rc )); then
  echo "Renew: see docs/3_OPERATIONS.md (server: easyrsa renew; CRL: easyrsa gen-crl; clients: revoke and re-add)." >&2
  logger -p daemon.warning -t vpn-check-expiry "certificates or CRL expire within $days days" || true
fi
exit $rc
