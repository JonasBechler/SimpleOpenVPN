# 3. Day-to-day operations

All commands run as root on the server. With an admin user, prefix them with
`sudo`.

## Install

```sh
apt-get install -y git
git clone <this repo> OpenVPN && cd OpenVPN
VPN_HOST=vpn.example.com ./scripts/install.sh
```

Options: `ADMIN_USER=alice` (recommended), `SSH_PORT=2222`, `CA_NOPASS=1`,
`WAN_IF=ens3`, `DNS1=`, `DNS2=`, `VPN_DOMAIN=internal`,
`BACKUP_AGE_RECIPIENT=age1...`.
Re-running the installer is safe. It keeps the PKI and the client registry and
rewrites configs and firewall.

## Add a client

```sh
vpn-add-client laptop          # key without passphrase, next free number (10, 11, ...)
vpn-add-client phone --pass    # key protected by a passphrase
vpn-add-client nas --ip 50     # pin the host number: 10.8.0.50 and 10.8.1.50
```

Host numbers 2 to 254 are allowed, 1 is the server. Automatic assignment
starts at 10, so 2 to 9 are free for things you want to remember.

Output lands in `~/vpn-clients/laptop/` of the admin user (or
`/root/vpn-clients/` without one). Fetch it from your workstation:

```sh
scp 'alice@vpn.example.com:vpn-clients/laptop/*.ovpn' .
```

Then remove the secrets from the server:

```sh
vpn-forget-client laptop
```

Import whichever profile you need:

- `laptop-split-udp.ovpn`: everyday use, only VPN addresses go through the tunnel.
- `laptop-full-tcp443.ovpn`: hostile networks, everything goes through the server.

## Who is where

```sh
vpn-list-clients
```

```
NAME     UDP 1194 (split)  TCP 443 (full)  CREATED     STATUS
laptop   10.8.0.10 *       10.8.1.10       2026-10-11  active
phone    10.8.0.11         10.8.1.11 *     2026-10-11  active
nas      10.8.0.12 *       10.8.1.12       2026-10-11  active
```

The asterisk marks a live session. Live detail (real address, bytes, connected
since) is in `/run/openvpn-server/status-*.log`.

## Reach devices by name

From any connected device:

```sh
ssh laptop.internal          # whichever instance the laptop is on right now
ssh laptop.udp.internal      # 10.8.0.10, split-tunnel address
ssh laptop.tcp.internal      # 10.8.1.10, full-tunnel address
ssh server.internal          # the VPN server itself
```

Check what the server currently answers:

```sh
cat /etc/openvpn/dns/hosts
dig @10.8.0.1 laptop.internal      # from a client
vpn-dns-update                # force a regeneration
```

## Revoke a client

```sh
vpn-revoke-client phone
```

Revokes the certificate, regenerates the CRL, deletes the ccd entries, kills
any live session through the management socket and marks the row in
`clients.csv` as revoked. The octet stays reserved.

## Logs and status

```sh
systemctl status openvpn-server@udp openvpn-server@tcp443 dnsmasq openvpn-dns.path
journalctl -u openvpn-server@tcp443 -f
nft list ruleset
```

## Renewal

Client certificates expire after 5 years, the server certificate too. To renew
the server certificate:

```sh
cd /etc/openvpn/easy-rsa
./easyrsa --batch renew server nopass     # Easy-RSA >= 3.1
./scripts/install.sh                      # copies the new cert and restarts
```

For a client, revoke it and add it again under a new name, or use
`./easyrsa renew NAME` and rebuild its `.ovpn` files by hand.

## Certificate expiry

`vpn-check-expiry [DAYS]` lists the CA, server certificate, CRL and every
active client with days left and exits non-zero if anything expires within
DAYS (default 30). A weekly systemd timer runs it and writes a warning to the
journal; `vpn-smoke-test` includes it. See it with:

```sh
journalctl -t vpn-check-expiry
```

## Backup and restore

```sh
vpn-backup                 # asks for a passphrase
vpn-backup /mnt/usb        # different destination
```

Writes an `age`-encrypted tar of `/etc/openvpn`, the firewall and the dnsmasq
config to `~/vpn-backups/` of the admin user (or `/root/vpn-backups/`). Copy it off the server. For unattended
backups generate a key pair on your workstation with `age-keygen`, put the
public key in `BACKUP_AGE_RECIPIENT` when installing (or edit
`/etc/openvpn/vpn.env`), and keep the private key off the server.

Restore on a fresh Debian:

```sh
apt-get install -y age
age -d -i backup.key openvpn-HOST-DATE.tar.age | tar -C / -xf -   # or: age -d -p ...
git clone <this repo> OpenVPN && cd OpenVPN
VPN_HOST=... ./scripts/install.sh     # re-creates services around the restored PKI
```

Client profiles keep working because CA, server certificate and the
tls-crypt-v2 server key come back unchanged.
