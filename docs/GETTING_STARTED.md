# Getting started

From nothing to your first two devices on the VPN. Budget about an hour, most
of it waiting for apt.

## 0. What you need

- A Debian 12 or 13 server with a public IPv4 address. Any small VPS works;
  one vCPU and 1 GB RAM is plenty.
- A DNS name pointing at it, for example `vpn.example.com`. The bare IP works
  but a name lets you move the server later without re-issuing profiles.
- An SSH key pair on your workstation (`ssh-keygen -t ed25519` if you have none).
- An OpenVPN client app on each device: OpenVPN Connect (iOS, Android,
  Windows, macOS), Tunnelblick (macOS), NetworkManager or `openvpn` (Linux).

## 1. Try it locally first (optional, recommended)

If you have Docker Desktop, run the full test harness once. It builds a
throwaway server, connects two clients and checks about seventy things.

```sh
cd test
./run.sh --clean
```

It should end with `failed: 0`. See `docs/4_TESTING.md` for what it covers.

## 2. Prepare the server

Create the VPS with your SSH public key. Most providers paste it into
`/root/.ssh/authorized_keys` for you. Check you can log in:

```sh
ssh root@vpn.example.com
```

Keep this session open until step 4 is done.

## 3. Install

**If you log in as root:**

```sh
apt-get update && apt-get install -y git
git clone <this repo> OpenVPN && cd OpenVPN
VPN_HOST=vpn.example.com ADMIN_USER=alice ./scripts/install.sh
```

**If you already have a user with sudo** (say `alice`, with your SSH key):

If `sudo` is missing on a minimal Debian, install it once as root
(`su -` if you cannot log in as root) and re-login afterwards:

```sh
apt-get update && apt-get install -y sudo && usermod -aG sudo alice
```

```sh
sudo apt-get update && sudo apt-get install -y git
git clone <this repo> OpenVPN && cd OpenVPN
sudo env VPN_HOST=vpn.example.com ADMIN_USER=alice ./scripts/install.sh
```

`sudo env` passes the variables through regardless of the sudoers policy.
The installer will:

- create the admin user if it does not exist (with your SSH key and
  passwordless sudo); an existing user is left as is, apart from being added
  to the `sudo` group if needed. Root login is disabled either way,
- turn off password authentication for SSH,
- enable automatic security updates with a 04:30 reboot when needed,
- build the certificate authority and ask you for a CA passphrase. Easy-RSA
  and OpenSSL each ask twice, so you type it four times. You need it every
  time you add or revoke a client. Use `CA_NOPASS=1` to skip this,
- start both OpenVPN instances, dnsmasq and the firewall.

Useful options: `SSH_PORT=2222`, `WAN_IF=ens3` if detection picks the wrong
interface, `BACKUP_AGE_RECIPIENT=age1...` for unattended backups (step 7).

## 4. Verify and switch to the admin user

Still on the server:

```sh
vpn-smoke-test
```

Every line should say PASS. From a second terminal on your workstation:

```sh
ssh alice@vpn.example.com
sudo vpn-list-clients
```

If that works, close the root session. From here on, all `vpn-*` commands are
run as `sudo vpn-...`.

## 5. Add your first device

```sh
sudo vpn-add-client laptop
```

This prints two files under `~/vpn-clients/laptop/` in the admin user's home
(`/root/vpn-clients/` when there is no admin user):

| File | Use it when |
|---|---|
| `laptop-split-udp.ovpn` | everyday. Only VPN addresses go through the tunnel, everything else is unchanged |
| `laptop-full-tcp443.ovpn` | hotel or office Wi-Fi, captive portals, untrusted networks. Everything goes through the server |

Copy them to your workstation:

```sh
scp 'alice@vpn.example.com:vpn-clients/laptop/*.ovpn' .
```

Then import a profile into your client app and connect.
Once the device works, remove the secrets from the server:

```sh
sudo vpn-forget-client laptop
```

Repeat for the phone:

```sh
sudo vpn-add-client phone
```

To get a profile onto a phone, either AirDrop or mail the `.ovpn` file to
yourself, or display it as a QR code for OpenVPN Connect:
`qrencode -t ansiutf8 < phone-split-udp.ovpn` (package `qrencode`). Delete
the mail afterwards; the file contains the device's private key.

## 6. Check it works

With both devices connected:

```sh
sudo vpn-list-clients
```

```
NAME    UDP 1194 (split)  TCP 443 (full)  CREATED     STATUS
laptop  10.8.0.10 *       10.8.1.10       2026-10-11  active
phone   10.8.0.11         10.8.1.11 *     2026-10-11  active
```

From the laptop:

```sh
ping phone.internal      # follows whichever profile the phone is using
ping server.internal
```

If names do not resolve on Linux with the plain `openvpn` command, add
`script-security 2` and `up /etc/openvpn/update-resolv-conf` to the profile,
or use NetworkManager. See `docs/2_OPENVPN.md`, section DNS.

## 7. Back up

```sh
sudo vpn-backup
scp 'alice@vpn.example.com:vpn-backups/*.tar.age' ~/safe-place/
```

Keep the passphrase (or the age private key) somewhere other than the
server. Without this backup, losing the server means re-enrolling every
device.

## 8. Day to day

| Task | Command |
|---|---|
| add a device | `sudo vpn-add-client NAME`, copy, `sudo vpn-forget-client NAME` |
| add with a chosen address | `sudo vpn-add-client nas --ip 50` gives 10.8.0.50 / 10.8.1.50 |
| who is online, which IP | `sudo vpn-list-clients` |
| device lost or retired | `sudo vpn-revoke-client NAME` |
| health check | `sudo vpn-smoke-test` |
| certificate lifetimes | `sudo vpn-check-expiry` (also runs weekly) |
| after changing anything | `sudo ./scripts/install.sh` from the repo, it is idempotent |

More detail in `docs/3_OPERATIONS.md`.

## If something goes wrong

- Installer stops with `no authorized_keys found`: add your public key to
  `/root/.ssh/authorized_keys` first.
- A client connects but has no internet on the full profile: check
  `WAN_IF` in `/etc/openvpn/vpn.env` matches `ip route show default`, re-run
  the installer.
- Client stuck on "connecting": `sudo journalctl -u openvpn-server@udp -f`
  while retrying. "certificate revoked" means it was revoked, "ccd-exclusive"
  means its registry entry is missing.
- Locked out of SSH: use the provider's console, then
  `rm /etc/ssh/sshd_config.d/10-hardening.conf && systemctl restart ssh`.
