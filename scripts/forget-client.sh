#!/usr/bin/env bash
# vpn-forget-client NAME - delete a client's private key, tls-crypt-v2 key and
# generated profiles from the server. Run it once the profiles are on the device.
# The certificate stays valid; only the copies of the secrets are removed.
# After this, "renew" is no longer possible for that client: revoke and re-add instead.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
NAME="${1:-}"
[[ -n $NAME ]] || die "usage: vpn-forget-client NAME"
[[ $NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]] || die "invalid client name"
awk -F, -v n="$NAME" 'NR>1 && $1==n {found=1} END {exit !found}' "$CLIENTS_CSV" || die "unknown client '$NAME'"

removed=0
for f in "$EASYRSA_DIR/pki/private/$NAME.key" "$EASYRSA_DIR/pki/private/$NAME.tc2" "$EASYRSA_DIR/pki/reqs/$NAME.req"; do
  [[ -e $f ]] && { shred -u "$f" 2>/dev/null || rm -f "$f"; removed=1; }
done
if [[ -d "${OUT_DIR:?}/$NAME" ]]; then
  find "$OUT_DIR/$NAME" -type f -exec shred -u {} + 2>/dev/null || rm -rf "${OUT_DIR:?}/$NAME"
  rm -rf "${OUT_DIR:?}/$NAME"
  removed=1
fi
(( removed )) && echo "Secrets for '$NAME' removed from this server." || echo "Nothing to remove for '$NAME'."
