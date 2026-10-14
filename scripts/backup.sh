#!/usr/bin/env bash
# vpn-backup [DEST_DIR] - encrypted archive of everything needed to rebuild the server.
#
# Contents: /etc/openvpn (PKI, registry, configs, keys), /etc/nftables.conf,
# /etc/dnsmasq.d/openvpn.conf. Encrypted with age:
#   - to BACKUP_AGE_RECIPIENT from /etc/openvpn/vpn.env if set (non-interactive), or
#   - with a passphrase typed now.
# Restore: see docs/3_OPERATIONS.md.
set -euo pipefail
recipient_override="${BACKUP_AGE_RECIPIENT:-}"   # environment wins over vpn.env
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env
BACKUP_AGE_RECIPIENT="${recipient_override:-${BACKUP_AGE_RECIPIENT:-}}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v age >/dev/null || die "age is not installed (apt-get install age)"

dest="${1:-${BACKUP_DIR:-/root/vpn-backups}}"
mkdir -p "$dest"; chmod 700 "$dest"
stamp=$(date -u +%Y%m%d-%H%M%S)
out="$dest/openvpn-$(hostname)-$stamp.tar.age"

tar -C / --exclude='etc/openvpn/easy-rsa/pki/*/temp.*' \
    -cf - etc/openvpn etc/nftables.conf etc/dnsmasq.d/openvpn.conf \
  | if [[ -n ${BACKUP_AGE_RECIPIENT:-} ]]; then
      age -r "$BACKUP_AGE_RECIPIENT" -o "$out"
    else
      echo "No BACKUP_AGE_RECIPIENT set; encrypting with a passphrase." >&2
      age -p -o "$out"
    fi
chmod 600 "$out"
if [[ -n ${ADMIN_USER:-} && -z ${1:-} ]]; then chown -R "$ADMIN_USER:" "$dest"; fi
echo "Backup written: $out"
echo "Copy it off this server, e.g.:  scp '${ADMIN_USER:-root}@$VPN_HOST:$out' ."
