#!/usr/bin/env bash
# End-to-end test of the OpenVPN installer in Docker.
#
#   ./run.sh            build, install, run all phases, leave containers up
#   ./run.sh --clean    same, then tear everything down (including volumes)
#   ./run.sh --down     only tear down
#
# Needs Docker with compose v2 (Docker Desktop is fine). Takes 5-10 minutes.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

SERVER_PUBLIC=192.0.2.10
SERVER_INTERNET=198.51.100.10
WHOAMI=198.51.100.20
ALL_PROFILES=(--profile clients --profile switch --profile revoked)
pass=0; fail=0; failed=()

c()      { docker compose "$@"; }
srv()    { docker compose exec -T server "$@"; }
on()     { local svc=$1; shift; docker compose exec -T "$svc" "$@"; }
hr()     { printf '\n\e[1;34m== %s\e[0m\n' "$*"; }
ok()     { printf '\e[32mPASS\e[0m %s\n' "$*"; ((pass++)); }
bad()    { printf '\e[31mFAIL\e[0m %s\n' "$*"; ((fail++)); failed+=("$*"); }
expect() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }
not()    { ! "$@"; }
retry()  { local n=$1; shift; for ((i=0;i<n;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
tun_ip() { on "$1" ip -4 -o addr show dev tun0 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
has_ip() { [[ $(tun_ip "$1") == "$2" ]]; }
no_ip()  { [[ -z $(tun_ip "$1") ]]; }
dig1()   { on "$1" dig +short +time=2 +tries=1 @"$2" "$3" | sort | tr '\n' ' ' | sed 's/ $//'; }
dns_is() { [[ $(dig1 "$1" "$2" "$3") == "$4" ]]; }   # dns_is CLIENT RESOLVER NAME "expected ips"
srv_grep(){ srv grep -q "$1" "$2"; }
list_has(){ srv vpn-list-clients | grep "$1" >/dev/null; }
nat_ok() { on phone curl -s -m5 "http://$WHOAMI/" | grep "RemoteAddr: $SERVER_INTERNET:" >/dev/null; }
def_via_tun(){ on phone ip route | grep '^0.0.0.0/1 .* dev tun0' >/dev/null; }
nxdomain(){ on "$1" dig +time=2 +tries=1 @"$2" "$3" | grep NXDOMAIN >/dev/null; }
journal_has(){ srv journalctl --no-pager _COMM=openvpn | grep -i "$1" >/dev/null; }
show_logs(){ echo "--- server openvpn journal (tail)"; srv journalctl --no-pager _COMM=openvpn | tail -15; echo "--- phone-revoked client log (tail)"; c logs --tail 15 phone-revoked; }
pki_sum(){ srv md5sum /etc/openvpn/server/ca.crt /etc/openvpn/server/tls-crypt-v2-server.key /etc/openvpn/clients.csv; }
dropped(){ on laptop curl -s -m3 "http://10.8.0.1:9/" >/dev/null 2>&1; [[ $? -eq 28 ]]; }   # 28 = timeout, i.e. dropped not refused
sshd_opt(){ srv sshd -T | grep -i "^$1" >/dev/null; }

if [[ ${1:-} == --down ]]; then c "${ALL_PROFILES[@]}" down -v --remove-orphans; exit; fi

hr "build and start server + fake internet"
c "${ALL_PROFILES[@]}" build -q || { echo "build failed"; exit 1; }
c up -d server whoami || exit 1
retry 60 srv systemctl is-active --quiet multi-user.target || true
expect "systemd is up inside server" srv systemctl is-active --quiet dbus

hr "detect WAN interface (the one on the 'internet' network)"
wan_if=$(srv ip -o -4 addr show | awk -v ip="$SERVER_INTERNET" '$4 ~ ip"/" {print $2}')
[[ -n $wan_if ]] || { bad "could not find interface for $SERVER_INTERNET"; exit 1; }
echo "WAN_IF=$wan_if"

hr "run installer"
if srv bash -c "rm -rf /root/OpenVPN && cp -r /opt/OpenVPN /root/OpenVPN && cd /root/OpenVPN && VPN_HOST=$SERVER_PUBLIC WAN_IF=$wan_if CA_NOPASS=1 ADMIN_USER=admin ./scripts/install.sh"; then
  ok "install.sh finished"
else
  bad "install.sh failed"; c logs server | tail -50; exit 1
fi
expect "smoke test"               srv vpn-smoke-test
expect "masquerade rule present"  srv bash -c "nft list ruleset | grep masquerade >/dev/null"
expect "tls-crypt-v2 on server"   srv_grep '^tls-crypt-v2 ' /etc/openvpn/server/udp.conf
expect "admin user exists"        srv id admin
expect "admin has passwordless sudo" srv sudo -n -u admin sudo -n true
expect "root ssh login disabled"  sshd_opt 'permitrootlogin no'
expect "password auth disabled"   sshd_opt 'passwordauthentication no'
expect "expiry check clean"       srv vpn-check-expiry
expect "expiry check warns at 2000 days" not srv vpn-check-expiry 2000
expect "expiry timer enabled"     srv systemctl is-enabled --quiet openvpn-expiry.timer

hr "create clients"
expect "add laptop"               srv vpn-add-client laptop
expect "add phone"                srv vpn-add-client phone
expect "reject duplicate"         not srv vpn-add-client laptop
expect "reject bad name"          not srv vpn-add-client 'bad name!'
expect "laptop is octet 10"       srv_grep '^laptop,10,10.8.0.10,10.8.1.10,' /etc/openvpn/clients.csv
expect "profile has tls-crypt-v2" srv_grep '<tls-crypt-v2>' /home/admin/vpn-clients/laptop/laptop-split-udp.ovpn
expect "per-client tc2 key kept in pki" srv test -s /etc/openvpn/easy-rsa/pki/private/laptop.tc2
expect "phone is octet 11"        srv_grep '^phone,11,10.8.0.11,10.8.1.11,' /etc/openvpn/clients.csv
expect "add nas with --ip 50"     srv vpn-add-client nas --ip 50
expect "nas is octet 50"          srv_grep '^nas,50,10.8.0.50,10.8.1.50,' /etc/openvpn/clients.csv
expect "reject taken --ip"        not srv vpn-add-client other --ip 50
expect "reject --ip 1"            not srv vpn-add-client other --ip 1
expect "reject --ip 300"          not srv vpn-add-client other --ip 300


hr "connect: laptop split/UDP, phone full/TCP443"
c --profile clients up -d laptop phone
expect "laptop gets 10.8.0.10"    retry 40 has_ip laptop 10.8.0.10
expect "phone gets 10.8.1.11"     retry 40 has_ip phone 10.8.1.11
expect "list: laptop online on udp"  retry 10 list_has 'laptop *10.8.0.10 \*'
expect "list: phone online on tcp"   retry 10 list_has 'phone *10.8.0.11 *10.8.1.11 \*'
(( fail )) && { echo "--- vpn-list-clients output:"; srv vpn-list-clients; }

hr "reachability"
expect "laptop -> server udp side"        on laptop ping -c1 -W2 10.8.0.1
expect "laptop -> server tcp side"        on laptop ping -c1 -W2 10.8.1.1
expect "laptop -> phone (cross instance)" on laptop ping -c1 -W2 10.8.1.11
expect "phone -> laptop (cross instance)" on phone  ping -c1 -W2 10.8.0.10
expect "split: laptop cannot reach internet net" not on laptop curl -s -m3 "http://$WHOAMI/"
expect "full: phone reaches internet net"        on phone curl -s -m5 "http://$WHOAMI/"
expect "full: phone is NATed to server address"  nat_ok
expect "full: phone default route via tun"       def_via_tun
expect "server ports other than dns/ssh dropped from tunnel" dropped
expect "ssh from tunnel allowed"                 on laptop bash -c "exec 3<>/dev/tcp/10.8.0.1/22 && timeout 3 head -c 3 <&3 | grep SSH >/dev/null"

hr "dns"
expect "laptop: server.internal"               dns_is laptop 10.8.0.1 server.internal "10.8.0.1 10.8.1.1"
expect "laptop: phone.internal -> tcp ip"      retry 15 dns_is laptop 10.8.0.1 phone.internal "10.8.1.11"
expect "laptop: laptop.internal -> own udp ip" retry 15 dns_is laptop 10.8.0.1 laptop.internal "10.8.0.10"
expect "phone: laptop.internal -> udp ip"      retry 15 dns_is phone 10.8.1.1 laptop.internal "10.8.0.10"
expect "phone: laptop.udp.internal fixed"      dns_is phone 10.8.1.1 laptop.udp.internal "10.8.0.10"
expect "phone: laptop.tcp.internal fixed"      dns_is phone 10.8.1.1 laptop.tcp.internal "10.8.1.10"
expect "phone: nxdomain for unknown"           nxdomain phone 10.8.1.1 nope.internal
expect "phone: upstream forwarding"            bash -c "[[ -n \$(docker compose exec -T phone dig +short +time=3 @10.8.1.1 debian.org) ]]"
expect "dns not reachable on public address"   not on laptop dig +time=2 +tries=1 @"$SERVER_PUBLIC" server.internal

hr "name following: phone switches to split profile"
c stop phone >/dev/null 2>&1
expect "phone offline -> both addresses"  retry 15 dns_is laptop 10.8.0.1 phone.internal "10.8.0.11 10.8.1.11"
c --profile switch up -d phone-split
expect "phone-split gets 10.8.0.11"       retry 40 has_ip phone-split 10.8.0.11
expect "phone.internal now -> udp ip"     retry 15 dns_is laptop 10.8.0.1 phone.internal "10.8.0.11"
c stop phone-split >/dev/null 2>&1

hr "revocation"
srv cp -r /home/admin/vpn-clients/phone /home/admin/vpn-clients/phone-revoked   # keep the profile so the revoked client can try
expect "revoke phone"                     srv vpn-revoke-client phone
expect "csv marks revoked"                srv_grep '^phone,11,.*,revoked' /etc/openvpn/clients.csv
expect "ccd removed"                      not srv test -e /etc/openvpn/server/ccd-tcp443/phone
expect "phone gone from dns"              retry 15 dns_is laptop 10.8.0.1 phone.internal ""
c --profile revoked up -d phone-revoked
sleep 20
expect "revoked phone cannot connect"     no_ip phone-revoked
if journal_has 'revoked\|CRL'; then ok "server logs revoked cert"; else bad "server logs revoked cert"; show_logs; fi
c stop phone-revoked >/dev/null 2>&1
expect "add tablet"                       srv vpn-add-client tablet
expect "tablet gets octet 12, not 11"     srv_grep '^tablet,12,' /etc/openvpn/clients.csv
expect "revoke purged phone private key"  not srv test -e /etc/openvpn/easy-rsa/pki/private/phone.key

hr "forget client secrets"
expect "forget tablet"                    srv vpn-forget-client tablet
expect "tablet profiles gone"             not srv test -d /home/admin/vpn-clients/tablet
expect "tablet private key gone"          not srv test -e /etc/openvpn/easy-rsa/pki/private/tablet.key
expect "tablet tc2 key gone"              not srv test -e /etc/openvpn/easy-rsa/pki/private/tablet.tc2
expect "tablet cert still valid"          srv test -s /etc/openvpn/easy-rsa/pki/issued/tablet.crt
expect "forget unknown rejected"          not srv vpn-forget-client nobody

hr "encrypted backup"
srv bash -c "age-keygen -o /root/test-backup.key 2>/dev/null"
expect "backup with recipient"            srv bash -c "BACKUP_AGE_RECIPIENT=\$(age-keygen -y /root/test-backup.key) vpn-backup /root/bk"
expect "backup decrypts and contains CA key" srv bash -c "age -d -i /root/test-backup.key /root/bk/*.tar.age | tar -t | grep -x 'etc/openvpn/easy-rsa/pki/private/ca.key' >/dev/null"
expect "backup contains registry"         srv bash -c "age -d -i /root/test-backup.key /root/bk/*.tar.age | tar -t | grep -x 'etc/openvpn/clients.csv' >/dev/null"

hr "server restart (simulated reboot)"
before=$(pki_sum)
c restart server >/dev/null 2>&1
retry 90 srv systemctl is-active --quiet openvpn-server@udp || true
expect "smoke test after reboot"          srv vpn-smoke-test
expect "firewall restored after reboot"   srv bash -c "nft list ruleset | grep masquerade >/dev/null"
expect "laptop reconnected (dns shows it)" retry 180 dns_is laptop 10.8.0.1 laptop.internal "10.8.0.10"
expect "laptop keeps fixed ip"            has_ip laptop 10.8.0.10

hr "installer re-run is idempotent"
expect "second install run"               srv bash -c "cd /root/OpenVPN && ./scripts/install.sh"
after=$(pki_sum)
if [[ "$before" == "$after" ]]; then ok "pki and registry unchanged"; else
  bad "pki and registry unchanged"; echo "--- before"; echo "$before"; echo "--- after"; echo "$after"; fi
expect "laptop reconnected after re-run"  retry 180 dns_is laptop 10.8.0.1 laptop.internal "10.8.0.10"

hr "result"
echo "passed: $pass  failed: $fail"
for f in "${failed[@]+"${failed[@]}"}"; do echo "  - $f"; done
if [[ ${1:-} == --clean ]]; then c "${ALL_PROFILES[@]}" down -v --remove-orphans; fi
(( fail == 0 ))
