#!/usr/bin/env bash
# vpn-smoke-test - verify the server side after install or reboot.
# Prints PASS/FAIL per check and exits non-zero if anything failed.
set -uo pipefail
# shellcheck disable=SC1091
source /etc/openvpn/vpn.env
D=${VPN_DOMAIN:-internal}
fail=0
ok()   { printf '\e[32mPASS\e[0m %s\n' "$*"; }
bad()  { printf '\e[31mFAIL\e[0m %s\n' "$*"; fail=1; }
check(){ local msg=$1; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }

echo "== services"
for u in openvpn-server@udp openvpn-server@tcp443 dnsmasq nftables openvpn-dns.path openvpn-dns.timer unattended-upgrades; do
  check "$u active" systemctl is-active --quiet "$u"
done
for u in openvpn-server@udp openvpn-server@tcp443 dnsmasq nftables openvpn-dns.path; do
  check "$u enabled" systemctl is-enabled --quiet "$u"
done

echo "== network"
check "tun-udp has ${UDP_NET%.*}.1" ip -4 addr show dev tun-udp | grep -q "${UDP_NET%.*}.1/"
check "tun-tcp has ${TCP_NET%.*}.1" ip -4 addr show dev tun-tcp | grep -q "${TCP_NET%.*}.1/"
check "ip_forward enabled"          test "$(sysctl -n net.ipv4.ip_forward)" = 1
check "udp $UDP_PORT listening"     ss -Hlnu "sport = :$UDP_PORT" | grep -q .
check "tcp $TCP_PORT listening"     ss -Hlnt "sport = :$TCP_PORT" | grep -q .
check "dnsmasq on ${UDP_NET%.*}.1:53" ss -Hlnu "sport = :53" | grep -q "${UDP_NET%.*}.1:53"
check "dnsmasq on ${TCP_NET%.*}.1:53" ss -Hlnu "sport = :53" | grep -q "${TCP_NET%.*}.1:53"
wan_ip=$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -1)
if [[ -z $wan_ip ]]; then
  bad "could not determine address of $WAN_IF"
elif ss -Hlnu "sport = :53" | grep -Eq "(^|\s)(0\.0\.0\.0|\*|$wan_ip):53"; then
  bad "port 53 exposed on $WAN_IF"
else
  ok "port 53 not on $WAN_IF"
fi

echo "== firewall"
check "nft input policy drop"        bash -c "nft list chain inet filter input | grep -q 'policy drop'"
check "nft forward policy drop"      bash -c "nft list chain inet filter forward | grep -q 'policy drop'"
check "nft masquerade for $TCP_NET/24" bash -c "nft list table ip nat | grep -q 'saddr $TCP_NET/24.*masquerade'"
check "nft allows ssh $SSH_PORT"     bash -c "nft list chain inet filter input | grep -q 'tcp dport $SSH_PORT accept'"

echo "== ssh / updates"
check "sshd PasswordAuthentication no"  bash -c "sshd -T | grep -qi '^passwordauthentication no'"
if [[ -n ${ADMIN_USER:-} ]]; then
  check "sshd PermitRootLogin no (admin user $ADMIN_USER)" bash -c "sshd -T | grep -Eqi '^permitrootlogin no'"
  check "admin user $ADMIN_USER has sudo" bash -c "sudo -l -U '$ADMIN_USER' | grep -q '(ALL'"
else
  check "sshd PermitRootLogin prohibit-password" bash -c "sshd -T | grep -Eqi '^permitrootlogin (prohibit-password|without-password)'"
fi
check "unattended-upgrades periodic on" grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades

echo "== pki / files"
check "ca.crt"            test -s "$SRV_DIR/ca.crt"
check "server.key 0600"   test "$(stat -c %a "$SRV_DIR/server.key")" = 600
check "tls-crypt-v2 key 0600" test "$(stat -c %a "$SRV_DIR/tls-crypt-v2-server.key")" = 600
check "crl.pem readable"  test "$(stat -c %a "$SRV_DIR/crl.pem")" = 644
check "crl not expired"   bash -c "openssl crl -in $SRV_DIR/crl.pem -noout -nextupdate | cut -d= -f2 | xargs -I{} date -d {} +%s | awk -v now=\$(date +%s) '\$1>now{exit 0}{exit 1}'"
check "clients.csv"       test -f "$CLIENTS_CSV"
check "dns hosts file"    test -s /etc/openvpn/dns/hosts
check "mgmt sockets"      bash -c "test -S /run/openvpn-server/mgmt-udp.sock && test -S /run/openvpn-server/mgmt-tcp443.sock"
check "state dirs owned by nobody" bash -c "test \"\$(stat -c %U /run/openvpn-dns/state/udp)\" = nobody"

echo "== certificate lifetimes"
if vpn-check-expiry >/dev/null 2>&1; then ok "nothing expires within 30 days"; else bad "vpn-check-expiry reports a problem (run it for details)"; fi

echo "== dns answers"
if command -v dig >/dev/null; then
  check "server.$D -> ${UDP_NET%.*}.1"     bash -c "dig +short @${UDP_NET%.*}.1 server.$D | grep -qx '${UDP_NET%.*}.1'"
  check "server.tcp.$D -> ${TCP_NET%.*}.1" bash -c "dig +short @${TCP_NET%.*}.1 server.tcp.$D | grep -qx '${TCP_NET%.*}.1'"
  check "upstream forwarding works"        bash -c "dig +short @${UDP_NET%.*}.1 debian.org | grep -q ."
  check "nxdomain.$D is NXDOMAIN"          bash -c "dig @${UDP_NET%.*}.1 doesnotexist.$D | grep -q NXDOMAIN"
else
  bad "dig not installed (apt-get install bind9-dnsutils)"
fi

echo
if (( fail )); then echo "SMOKE TEST FAILED"; exit 1; else echo "ALL CHECKS PASSED"; fi
