#!/usr/bin/env bash
# install.sh - turn a fresh Debian 12/13 host into a hardened OpenVPN server.
#
# Idempotent: safe to re-run. Existing PKI, client registry and ccd entries
# are preserved; server configs, firewall and system settings are rewritten.
#
# Usage (as root):
#   VPN_HOST=vpn.example.com ./install.sh
#
# Optional environment:
#   SSH_PORT=22        SSH port to keep open in the firewall
#   CA_NOPASS=1        create the CA without a passphrase (default: prompt)
#   WAN_IF=eth0        override auto-detected public interface
#   DNS1=1.1.1.1 DNS2=9.9.9.9   upstream resolvers for dnsmasq
#   VPN_DOMAIN=internal         private DNS zone (NAME.internal, NAME.udp.internal, ...)
#   ADMIN_USER=alice            create a sudo user with root's SSH keys and disable root login
#   BACKUP_AGE_RECIPIENT=age1.. public key for vpn-backup (otherwise it asks for a passphrase)
set -euo pipefail

#--- constants -----------------------------------------------------------------
EASYRSA_DIR=/etc/openvpn/easy-rsa
SRV_DIR=/etc/openvpn/server
ENV_FILE=/etc/openvpn/vpn.env
CLIENTS_CSV=/etc/openvpn/clients.csv
UDP_PORT=1194
TCP_PORT=443
UDP_NET=10.8.0.0   # split-tunnel instance
TCP_NET=10.8.1.0   # full-tunnel instance
TCP_NET6=fd42:8:1::/64   # ULA for the full-tunnel instance; only used to blackhole client IPv6
NETMASK=255.255.255.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\e[1;32m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[1;33mWARN: %s\e[0m\n' "$*" >&2; }
die()  { printf '\e[1;31mERROR: %s\e[0m\n' "$*" >&2; exit 1; }

#--- preflight -----------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run as root"
grep -qi debian /etc/os-release || die "this script targets Debian"

if [[ -f $ENV_FILE ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
VPN_HOST="${VPN_HOST:-}"
[[ -n $VPN_HOST ]] || die "set VPN_HOST to the public DNS name or IP of this server"
SSH_PORT="${SSH_PORT:-22}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-9.9.9.9}"
VPN_DOMAIN="${VPN_DOMAIN:-internal}"
ADMIN_USER="${ADMIN_USER:-}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '{print $5; exit}')}"
[[ -n $WAN_IF ]] || die "could not detect the public interface, set WAN_IF"

# Refuse to disable password auth if nobody could log in with a key afterwards.
if ! grep -qs . /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null; then
  die "no authorized_keys found for root or any user; add your SSH key first"
fi

if ss -Hlnu 'sport = :53' 2>/dev/null | grep -Eq '(0\.0\.0\.0|\*|\[::\]):53' && ! systemctl is-active --quiet dnsmasq; then
  die "something other than dnsmasq already listens on *:53"
fi

log "host=$VPN_HOST wan=$WAN_IF ssh=$SSH_PORT"

#--- packages ------------------------------------------------------------------
log "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q openssh-server sudo openvpn easy-rsa nftables unattended-upgrades socat openssl dnsmasq bind9-dnsutils bsdextrautils age

#--- admin user (optional) -----------------------------------------------------
permit_root=prohibit-password
OUT_DIR=/root/vpn-clients
BACKUP_DIR=/root/vpn-backups
if [[ -n $ADMIN_USER ]]; then
  [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid ADMIN_USER"
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    # Existing user: keep their sudo setup, just make sure they have sudo at all.
    if ! sudo -l -U "$ADMIN_USER" 2>/dev/null | grep -q '(ALL'; then
      log "adding $ADMIN_USER to the sudo group"
      usermod -aG sudo "$ADMIN_USER"
    fi
  else
    log "creating admin user $ADMIN_USER (passwordless sudo)"
    useradd -m -s /bin/bash "$ADMIN_USER"
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
    chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
    visudo -cq || die "sudoers invalid"
  fi
  home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  if [[ ! -s $home/.ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]; then
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
    install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "$home/.ssh/authorized_keys"
  fi
  [[ -s $home/.ssh/authorized_keys ]] || die "$ADMIN_USER has no authorized_keys; add one before disabling root login"
  permit_root=no
  OUT_DIR=$home/vpn-clients      # profiles and backups readable by the admin for scp
  BACKUP_DIR=$home/vpn-backups
fi

#--- ssh hardening -------------------------------------------------------------
log "hardening sshd (PermitRootLogin $permit_root)"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<CONF
Port $SSH_PORT
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin $permit_root
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
CONF
mkdir -p /run/sshd
sshd -t || die "sshd config invalid"
systemctl enable --quiet ssh 2>/dev/null || true
systemctl try-reload-or-restart ssh

#--- automatic security updates -----------------------------------------------
log "enabling unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'CONF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
CONF
systemctl enable --now unattended-upgrades

#--- kernel ----------------------------------------------------------------------
log "enabling ip forwarding"
cat > /etc/sysctl.d/99-openvpn.conf <<'CONF'
net.ipv4.ip_forward = 1
CONF
sysctl -q -p /etc/sysctl.d/99-openvpn.conf

#--- PKI -------------------------------------------------------------------------
if [[ ! -d $EASYRSA_DIR ]]; then
  log "creating Easy-RSA directory"
  make-cadir "$EASYRSA_DIR"
fi
rm -f "$EASYRSA_DIR/vars"   # Easy-RSA 3.1 wants vars inside the PKI directory
write_vars() {
cat > "$EASYRSA_DIR/pki/vars" <<CONF
set_var EASYRSA_PKI         "$EASYRSA_DIR/pki"
set_var EASYRSA_ALGO        ec
set_var EASYRSA_CURVE       secp384r1
set_var EASYRSA_DIGEST      sha256
set_var EASYRSA_CA_EXPIRE   3650
set_var EASYRSA_CERT_EXPIRE 1825
set_var EASYRSA_CRL_DAYS    3650
CONF
}
mkdir -p "$SRV_DIR"
cd "$EASYRSA_DIR"
if [[ ! -f pki/ca.crt ]]; then
  log "building CA"
  ./easyrsa --batch init-pki
  write_vars
  if [[ ${CA_NOPASS:-0} == 1 ]]; then
    ./easyrsa --batch --req-cn="OpenVPN CA" build-ca nopass
  else
    echo "Choose a CA passphrase. You will need it every time you add or revoke a client."
    echo "(Easy-RSA and OpenSSL each ask twice; enter the same passphrase all four times.)"
    ./easyrsa --batch --req-cn="OpenVPN CA" build-ca
  fi
fi
write_vars
if [[ ! -f pki/issued/server.crt ]]; then
  log "building server certificate"
  ./easyrsa --batch build-server-full server nopass
fi
if [[ ! -f pki/crl.pem ]]; then
  log "generating CRL"
  ./easyrsa --batch gen-crl
fi
if [[ ! -f "$SRV_DIR/tls-crypt-v2-server.key" ]]; then
  log "generating tls-crypt-v2 server key"
  openvpn --genkey tls-crypt-v2-server "$SRV_DIR/tls-crypt-v2-server.key"
fi

log "installing certificates into $SRV_DIR"
install -m 644 pki/ca.crt            "$SRV_DIR/ca.crt"
install -m 644 pki/issued/server.crt "$SRV_DIR/server.crt"
install -m 600 pki/private/server.key "$SRV_DIR/server.key"
install -m 644 pki/crl.pem           "$SRV_DIR/crl.pem"
chmod 600 "$SRV_DIR/tls-crypt-v2-server.key"
mkdir -p "$SRV_DIR/ccd-udp" "$SRV_DIR/ccd-tcp443"

#--- server configs --------------------------------------------------------------
log "writing server configs"
common_server_cfg() {
cat <<CONF
dev-type tun
topology subnet
client-config-dir $SRV_DIR/$1
ccd-exclusive
client-to-client
keepalive 10 60

ca   $SRV_DIR/ca.crt
cert $SRV_DIR/server.crt
key  $SRV_DIR/server.key
dh   none
tls-crypt-v2 $SRV_DIR/tls-crypt-v2-server.key
crl-verify $SRV_DIR/crl.pem
remote-cert-tls client
tls-version-min 1.2
tls-cert-profile preferred
data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA256

user nobody
group nogroup
persist-key
persist-tun
management /run/openvpn-server/mgmt-$2.sock unix
verb 3

# presence tracking for DNS (see vpn-dns-update)
setenv INSTANCE $2
script-security 2
client-connect    /etc/openvpn/scripts/client-state.sh
client-disconnect /etc/openvpn/scripts/client-state.sh
CONF
}

cat > "$SRV_DIR/udp.conf" <<CONF
# Split-tunnel instance: only the VPN subnets are routed through the tunnel.
port $UDP_PORT
proto udp
dev tun-udp
server $UDP_NET $NETMASK
push "route $TCP_NET $NETMASK"
push "dhcp-option DNS ${UDP_NET%.*}.1"
push "dhcp-option DOMAIN $VPN_DOMAIN"
explicit-exit-notify 1
$(common_server_cfg ccd-udp udp)
CONF

# IPv6 blackhole for full-tunnel clients needs IPv6 enabled on this host.
ipv6_cfg=""
if [[ -e /proc/net/if_inet6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) == 0 ]]; then
  ipv6_cfg=$(printf 'server-ipv6 %s\npush "redirect-gateway def1 bypass-dhcp ipv6"\npush "block-ipv6"' "$TCP_NET6")
else
  warn "IPv6 is disabled on this host; full-tunnel clients will not get the IPv6 blackhole"
  ipv6_cfg='push "redirect-gateway def1 bypass-dhcp"'
fi

cat > "$SRV_DIR/tcp443.conf" <<CONF
# Full-tunnel instance: all client traffic is routed and NATed through the server.
port $TCP_PORT
proto tcp-server
dev tun-tcp
server $TCP_NET $NETMASK
push "route $UDP_NET $NETMASK"
$ipv6_cfg
push "dhcp-option DNS ${TCP_NET%.*}.1"
push "dhcp-option DOMAIN $VPN_DOMAIN"
push "block-outside-dns"
tcp-nodelay
$(common_server_cfg ccd-tcp443 tcp443)
CONF

#--- registry, env, helper scripts -------------------------------------------------
if [[ ! -f $CLIENTS_CSV ]]; then
  echo "name,host_octet,udp_ip,tcp_ip,created,status" > "$CLIENTS_CSV"
fi
chmod 600 "$CLIENTS_CSV"

cat > "$ENV_FILE" <<CONF
# generated by install.sh; sourced by the vpn-* helper scripts
VPN_HOST=$VPN_HOST
WAN_IF=$WAN_IF
SSH_PORT=$SSH_PORT
DNS1=$DNS1
DNS2=$DNS2
VPN_DOMAIN=$VPN_DOMAIN
ADMIN_USER=$ADMIN_USER
BACKUP_AGE_RECIPIENT=$BACKUP_AGE_RECIPIENT
UDP_PORT=$UDP_PORT
TCP_PORT=$TCP_PORT
UDP_NET=$UDP_NET
TCP_NET=$TCP_NET
TCP_NET6=$TCP_NET6
NETMASK=$NETMASK
EASYRSA_DIR=$EASYRSA_DIR
SRV_DIR=$SRV_DIR
CLIENTS_CSV=$CLIENTS_CSV
OUT_DIR=$OUT_DIR
BACKUP_DIR=$BACKUP_DIR
CONF
chmod 600 "$ENV_FILE"

log "installing helper scripts to /usr/local/sbin"
install -m 755 "$SCRIPT_DIR/add-client.sh"    /usr/local/sbin/vpn-add-client
install -m 755 "$SCRIPT_DIR/list-clients.sh"  /usr/local/sbin/vpn-list-clients
install -m 755 "$SCRIPT_DIR/revoke-client.sh" /usr/local/sbin/vpn-revoke-client
install -m 755 "$SCRIPT_DIR/smoke-test.sh"    /usr/local/sbin/vpn-smoke-test
install -m 755 "$SCRIPT_DIR/forget-client.sh"  /usr/local/sbin/vpn-forget-client
install -m 755 "$SCRIPT_DIR/backup.sh"         /usr/local/sbin/vpn-backup
install -m 755 "$SCRIPT_DIR/check-expiry.sh"   /usr/local/sbin/vpn-check-expiry

#--- DNS: dnsmasq serving *.$VPN_DOMAIN ------------------------------------------------
log "configuring dnsmasq for the .$VPN_DOMAIN domain"
mkdir -p /etc/openvpn/dns /etc/openvpn/scripts
install -m 755 "$SCRIPT_DIR/client-state.sh" /etc/openvpn/scripts/client-state.sh
install -m 755 "$SCRIPT_DIR/dns-update.sh"   /usr/local/sbin/vpn-dns-update

cat > /etc/dnsmasq.d/openvpn.conf <<CONF
# Only answer on the VPN interfaces (they appear after dnsmasq starts).
bind-dynamic
interface=tun-udp
interface=tun-tcp
except-interface=$WAN_IF

# Upstream resolvers for everything that is not *.$VPN_DOMAIN
no-resolv
server=$DNS1
server=$DNS2
domain-needed
bogus-priv
cache-size=1000

# *.$VPN_DOMAIN is answered from our generated hosts file and never forwarded.
local=/$VPN_DOMAIN/
no-hosts
addn-hosts=/etc/openvpn/dns/hosts
CONF

cat > /etc/tmpfiles.d/openvpn-dns.conf <<'CONF'
d /run/openvpn-dns              0755 root   root    -
d /run/openvpn-dns/state        0755 root   root    -
d /run/openvpn-dns/state/udp    0755 nobody nogroup -
d /run/openvpn-dns/state/tcp443 0755 nobody nogroup -
CONF
systemd-tmpfiles --create /etc/tmpfiles.d/openvpn-dns.conf

# Regenerate hosts when a presence file appears or disappears, plus a
# safety-net timer in case an inotify event is missed.
cat > /etc/systemd/system/openvpn-dns.service <<'CONF'
[Unit]
Description=Regenerate private DNS hosts for dnsmasq
After=dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-dns-update
CONF
cat > /etc/systemd/system/openvpn-dns.path <<'CONF'
[Unit]
Description=Watch OpenVPN client presence for DNS updates

[Path]
PathChanged=/run/openvpn-dns/state/udp
PathChanged=/run/openvpn-dns/state/tcp443

[Install]
WantedBy=multi-user.target
CONF
cat > /etc/systemd/system/openvpn-dns.timer <<'CONF'
[Unit]
Description=Periodic private DNS hosts refresh

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
CONF

# Presence files are only valid while the instance runs: clear them around restarts.
for inst in udp tcp443; do
  mkdir -p "/etc/systemd/system/openvpn-server@$inst.service.d"
  cat > "/etc/systemd/system/openvpn-server@$inst.service.d/dns.conf" <<CONF
[Unit]
After=dnsmasq.service

[Service]
ExecStartPre=/bin/sh -c 'rm -f /run/openvpn-dns/state/$inst/*'
ExecStopPost=/bin/sh -c 'rm -f /run/openvpn-dns/state/$inst/*'
CONF
done

systemctl daemon-reload
systemctl enable --now openvpn-dns.path openvpn-dns.timer
vpn-dns-update
systemctl enable dnsmasq
systemctl restart dnsmasq

#--- weekly certificate expiry check --------------------------------------------
cat > /etc/systemd/system/openvpn-expiry.service <<'CONF'
[Unit]
Description=Warn about expiring OpenVPN certificates and CRL

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-check-expiry
CONF
cat > /etc/systemd/system/openvpn-expiry.timer <<'CONF'
[Unit]
Description=Weekly OpenVPN certificate expiry check

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
CONF
systemctl daemon-reload
systemctl enable --now openvpn-expiry.timer

#--- firewall --------------------------------------------------------------------
log "writing nftables ruleset"
cat > /etc/nftables.conf <<CONF
#!/usr/sbin/nft -f
flush ruleset

define wan          = "$WAN_IF"
define ssh_port     = $SSH_PORT
define vpn_udp_port = $UDP_PORT
define vpn_tcp_port = $TCP_PORT
define full_net     = $TCP_NET/24

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    tcp dport \$ssh_port accept
    udp dport \$vpn_udp_port accept
    tcp dport \$vpn_tcp_port accept
    iifname "tun-*" meta l4proto { icmp, ipv6-icmp } accept
    iifname "tun-*" udp dport 53 accept comment "dnsmasq"
    iifname "tun-*" tcp dport { 53, \$ssh_port } accept comment "dnsmasq, ssh"
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iifname "tun-*" oifname "tun-*" accept comment "client to client across instances"
    iifname "tun-tcp" oifname \$wan accept comment "full tunnel to internet"
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr \$full_net oifname \$wan masquerade
  }
}
CONF
nft -c -f /etc/nftables.conf || die "nftables ruleset invalid"
systemctl enable --now nftables
nft -f /etc/nftables.conf

#--- services ----------------------------------------------------------------------
log "starting OpenVPN instances"
systemctl enable --now openvpn-server@udp openvpn-server@tcp443
systemctl restart openvpn-server@udp openvpn-server@tcp443
sleep 1
systemctl --no-pager --quiet is-active openvpn-server@udp    || die "udp instance failed, see: journalctl -u openvpn-server@udp"
systemctl --no-pager --quiet is-active openvpn-server@tcp443 || die "tcp443 instance failed, see: journalctl -u openvpn-server@tcp443"

log "done"
cat <<MSG

OpenVPN is running:
  UDP $UDP_PORT  split tunnel   $UDP_NET/24
  TCP $TCP_PORT  full tunnel    $TCP_NET/24 (NAT via $WAN_IF)

DNS: clients resolve NAME.$VPN_DOMAIN, NAME.udp.$VPN_DOMAIN, NAME.tcp.$VPN_DOMAIN and server.$VPN_DOMAIN.

Next: verify, then create your first client
  vpn-smoke-test
  vpn-add-client laptop      # profiles land in $OUT_DIR; copy them off, then:
  vpn-forget-client laptop   # removes the private key and profiles from the server
  vpn-list-clients
  vpn-backup                 # encrypted copy of /etc/openvpn, keep it elsewhere
MSG
