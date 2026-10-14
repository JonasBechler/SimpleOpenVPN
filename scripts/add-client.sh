#!/usr/bin/env bash
# vpn-add-client NAME [--pass] [--ip N]
#
# Creates a client certificate, assigns a fixed IP in both VPN subnets and
# writes two inline .ovpn files to $OUT_DIR/NAME/:
#   NAME-split-udp.ovpn     UDP 1194, only VPN subnets routed
#   NAME-full-tcp443.ovpn   TCP 443, everything routed through the server
#
# --pass   protect the client's private key with a passphrase
# --ip N   use host number N (2-254) in both subnets, e.g. --ip 50 gives
#          10.8.0.50 and 10.8.1.50. Default: lowest free number from 10.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

NAME="${1:-}"; shift || true
PASS_OPT=nopass
WANT_OCTET=""
while (( $# )); do
  case $1 in
    --pass) PASS_OPT="" ;;
    --ip)   WANT_OCTET="${2:-}"; shift ;;
    --ip=*) WANT_OCTET="${1#--ip=}" ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ -n $NAME ]] || die "usage: vpn-add-client NAME [--pass] [--ip N]"
[[ $NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]] || die "NAME may contain letters, digits, '_', '.', '-'"
[[ $NAME != server ]] || die "'server' is reserved"
awk -F, -v n="$NAME" 'NR>1 && $1==n {found=1} END {exit !found}' "$CLIENTS_CSV" && die "client '$NAME' already exists (see vpn-list-clients)"
[[ -f $EASYRSA_DIR/pki/issued/$NAME.crt ]] && die "certificate for '$NAME' already exists in the PKI"

#--- host octet: requested, or next free (10..254) ------------------------------
used=$(awk -F, 'NR>1 {print $2}' "$CLIENTS_CSV" | sort -n)
octet=""
if [[ -n $WANT_OCTET ]]; then
  if ! [[ $WANT_OCTET =~ ^[0-9]+$ ]] || (( WANT_OCTET < 2 || WANT_OCTET > 254 )); then
    die "--ip must be a number from 2 to 254 (1 is the server)"
  fi
  if grep -qx "$WANT_OCTET" <<<"$used"; then
    owner=$(awk -F, -v o="$WANT_OCTET" 'NR>1 && $2==o {print $1" ("$6")"}' "$CLIENTS_CSV")
    die "host number $WANT_OCTET is taken by $owner"
  fi
  octet=$WANT_OCTET
else
  for i in $(seq 10 254); do
    if ! grep -qx "$i" <<<"$used"; then octet=$i; break; fi
  done
fi
[[ -n $octet ]] || die "no free IP left in the /24"
prefix_udp=${UDP_NET%.*}
prefix_tcp=${TCP_NET%.*}
UDP_IP="$prefix_udp.$octet"
TCP_IP="$prefix_tcp.$octet"

#--- certificate and per-client tls-crypt-v2 key -----------------------------------
cd "$EASYRSA_DIR"
# shellcheck disable=SC2086
./easyrsa --batch build-client-full "$NAME" $PASS_OPT
openvpn --tls-crypt-v2 "$SRV_DIR/tls-crypt-v2-server.key" --genkey tls-crypt-v2-client "pki/private/$NAME.tc2"
chmod 600 "pki/private/$NAME.tc2"

#--- fixed IPs via client-config-dir ---------------------------------------------
echo "ifconfig-push $UDP_IP $NETMASK" > "$SRV_DIR/ccd-udp/$NAME"
echo "ifconfig-push $TCP_IP $NETMASK" > "$SRV_DIR/ccd-tcp443/$NAME"

#--- client configs ------------------------------------------------------------------
out="$OUT_DIR/$NAME"
mkdir -p "$out"
chmod 700 "$OUT_DIR" "$out"

ca_pem=$(cat "$SRV_DIR/ca.crt")
cert_pem=$(openssl x509 -in "pki/issued/$NAME.crt")
key_pem=$(cat "pki/private/$NAME.key")
tc2_pem=$(cat "pki/private/$NAME.tc2")

client_common() {
cat <<CONF
client
dev tun
nobind
resolv-retry infinite
persist-key
persist-tun
remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
auth-nocache
verb 3

<ca>
$ca_pem
</ca>
<cert>
$cert_pem
</cert>
<key>
$key_pem
</key>
<tls-crypt-v2>
$tc2_pem
</tls-crypt-v2>
CONF
}

{
cat <<CONF
# $NAME - split tunnel over UDP $UDP_PORT
# Fixed address: $UDP_IP. Only $UDP_NET/24 and $TCP_NET/24 go through the VPN.
proto udp
remote $VPN_HOST $UDP_PORT
explicit-exit-notify
CONF
client_common
} > "$out/$NAME-split-udp.ovpn"

{
cat <<CONF
# $NAME - full tunnel over TCP $TCP_PORT
# Fixed address: $TCP_IP. All traffic, including DNS, goes through the VPN.
proto tcp-client
remote $VPN_HOST $TCP_PORT
connect-retry 2
CONF
client_common
} > "$out/$NAME-full-tcp443.ovpn"
chmod 600 "$out"/*.ovpn
if [[ -n ${ADMIN_USER:-} ]]; then chown -R "$ADMIN_USER:" "$OUT_DIR"; fi

#--- registry ------------------------------------------------------------------------
echo "$NAME,$octet,$UDP_IP,$TCP_IP,$(date -u +%F),active" >> "$CLIENTS_CSV"
vpn-dns-update

cat <<MSG
Client '$NAME' created.
  split tunnel (UDP $UDP_PORT): $UDP_IP   $out/$NAME-split-udp.ovpn
  full tunnel  (TCP $TCP_PORT): $TCP_IP   $out/$NAME-full-tcp443.ovpn
  DNS: $NAME.$VPN_DOMAIN (follows the live connection), $NAME.udp.$VPN_DOMAIN, $NAME.tcp.$VPN_DOMAIN

Copy to your device, then remove the keys from the server:
  scp -P $SSH_PORT '${ADMIN_USER:-root}@$VPN_HOST:$out/*.ovpn' .
  ${ADMIN_USER:+sudo }vpn-forget-client $NAME
MSG
