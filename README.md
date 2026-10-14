# Secure OpenVPN Setup Guide
## From Debian install to an automated OpenVPN server

A single-purpose Debian host that runs two OpenVPN instances from one PKI, so
all my devices share a private network reachable from anywhere.

**New here? Read [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).**

## What you get

- Two profiles per device: **UDP 1194 split tunnel** for everyday use, and
  **TCP 443 full tunnel** with NAT and IPv6 blackhole for hostile networks.
- Fixed IP per device, the same host number in both subnets, and a readable
  overview of who sits where and who is online.
- Internal DNS: `laptop.internal` follows the laptop's live connection,
  `laptop.udp.internal` and `laptop.tcp.internal` are fixed.
- Easy-RSA 3 PKI with EC keys, per-client `tls-crypt-v2`, CRL revocation that
  takes effect immediately, client secrets removable from the server.
- Key-only SSH with an admin user and root login disabled, unattended security
  updates, nftables with drop policy, dnsmasq bound to the tunnel only.
- Encrypted backups, weekly certificate expiry check, one-command health check.
- A Docker test harness that verifies all of it in about five minutes.

## Quick start

On a fresh Debian 12/13 with your SSH key installed:

```sh
git clone <this repo> OpenVPN && cd OpenVPN
VPN_HOST=vpn.example.com ADMIN_USER=alice ./scripts/install.sh
vpn-smoke-test
vpn-add-client laptop        # copy the profiles to the device, then:
vpn-forget-client laptop
vpn-list-clients
vpn-backup
```

## Documentation

| | |
|---|---|
| [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) | zero to first two devices, step by step |
| [docs/0_IDEA.md](docs/0_IDEA.md) | the original requirements |
| [docs/1_SERVER_BASE.md](docs/1_SERVER_BASE.md) | OS hardening: admin user, SSH, updates, firewall |
| [docs/2_OPENVPN.md](docs/2_OPENVPN.md) | design: instances, PKI, fixed IPs, DNS, crypto, secrets |
| [docs/3_OPERATIONS.md](docs/3_OPERATIONS.md) | add / list / revoke / forget, expiry, backup and restore |
| [docs/4_TESTING.md](docs/4_TESTING.md) | Docker harness, VPS test plan, what has been verified |

## Commands installed on the server

| Command | Purpose |
|---|---|
| `vpn-add-client NAME [--pass] [--ip N]` | issue a certificate, assign or pin fixed IPs, write both profiles |
| `vpn-forget-client NAME` | shred the client's private key and profiles from the server |
| `vpn-list-clients` | table of clients, IPs, status, who is online |
| `vpn-revoke-client NAME` | revoke, refresh CRL, kick live sessions, purge keys |
| `vpn-smoke-test` | server-side health checks |
| `vpn-check-expiry [DAYS]` | certificate and CRL lifetimes, also runs weekly |
| `vpn-backup [DIR]` | age-encrypted archive of PKI and configs |
| `vpn-dns-update` | regenerate `.internal` records (normally automatic) |

## Repository layout

```
scripts/   install.sh and the vpn-* commands it installs
docs/      design, operations, testing
test/      Docker Compose harness: ./test/run.sh --clean
```

## Status

Verified by the Docker harness: 71 of 71 checks on Debian 12. Not yet
exercised on a public VPS or with real client apps; see docs/4_TESTING.md.
