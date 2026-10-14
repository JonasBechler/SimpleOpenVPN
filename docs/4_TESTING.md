# 4. Test plan: disposable test server

Goal: prove the whole thing end to end on a throwaway host before touching the
real server. Budget: about two hours, under 1 EUR of cloud time.

## Option 0 (fastest): Docker Compose harness on your workstation

`test/run.sh` builds a systemd-based Debian 12 container that plays the VPS,
runs the unmodified installer in it, starts two client containers (split over
UDP, full over TCP 443) and a fake internet host that only the server can
reach, and asserts about 70 things: fixed IPs, cross-instance ping, NAT,
split versus full routing, every DNS behaviour, name following when a client
switches profile, revocation, reboot persistence and installer re-run.

```sh
cd test
./run.sh            # ~5 minutes, leaves containers up for poking around
./run.sh --clean    # same, then removes containers and volumes
./run.sh --down     # just tear down
```

Needs Docker Desktop or any Docker with compose v2. The server container runs
privileged because systemd and nftables need it. What this cannot prove: real
public reachability, MTU behaviour across the internet, IPv6 leaks, and the
behaviour of real client apps. Do a short run of Option A before going live.

## Option A (recommended for the final check): cheap cloud VPS with a public IP

A real public IP is the only way to test TCP 443 from hostile networks, NAT,
and that nothing else is exposed. Any provider with hourly billing and Debian
images works. Hetzner Cloud CX22 or a similar entry-level VPS is enough.

1. Create the VM with Debian 13 (or 12), add your SSH public key in the
   provider panel so it lands in `/root/.ssh/authorized_keys`.
2. Optional: point a test DNS name at it, for example `vpntest.example.com`.
   The bare IP works too.
3. Take a provider snapshot of the fresh VM. Reverting to it gives a clean
   second run in a minute.

## Option B: local VMs

Two VMs on one host (libvirt, VirtualBox, Multipass): `server` with a NAT
interface, `client` on the same NAT network. The installer detects the NAT
interface as `WAN_IF`. You can test everything except reachability from the
public internet and the full-tunnel public-IP change. Use the server's
NAT-network IP as `VPN_HOST`.

## Phase 1: install

On your workstation:

```sh
scp -r OpenVPN root@TESTHOST:
ssh root@TESTHOST
```

On the server, keep this session open the whole time:

```sh
cd OpenVPN
VPN_HOST=TESTHOST ./scripts/install.sh
vpn-smoke-test
```

| Check | Expected |
|---|---|
| Installer | ends with "done", no red ERROR |
| `vpn-smoke-test` | ALL CHECKS PASSED |
| New SSH session from workstation | key login works |
| `ssh -o PubkeyAuthentication=no root@TESTHOST` | "Permission denied (publickey)" |
| `nmap -sS -sU -p 22,53,443,1194 TESTHOST` from outside | 22 and 443 open, 53 closed/filtered, 1194 open\|filtered (tls-crypt, no reply) |

## Phase 2: first client, split tunnel

```sh
vpn-add-client laptop
vpn-list-clients
```

Copy `vpn-clients/laptop/*.ovpn` from the admin home to the laptop and connect with
`laptop-split-udp.ovpn`.

| Check on the laptop | Expected |
|---|---|
| tunnel address | `10.8.0.10` |
| `ping 10.8.0.1` and `ping 10.8.1.1` | both reply |
| `curl ifconfig.me` | your normal public IP, unchanged |
| `dig server.internal` or `ping server.internal` | `10.8.0.1` |
| `dig laptop.internal` | `10.8.0.10` only |
| `ip route` / route table | only `10.8.0.0/24` and `10.8.1.0/24` via tun |
| `vpn-list-clients` on the server | asterisk in the UDP column for laptop |

## Phase 3: full tunnel

Disconnect, connect with `laptop-full-tcp443.ovpn`.

| Check on the laptop | Expected |
|---|---|
| tunnel address | `10.8.1.10` |
| `curl ifconfig.me` | the server's public IP |
| `curl https://dnsleaktest.com` style check or `dig +short myip.opendns.com @resolver1.opendns.com` | server IP |
| `curl -6 https://ifconfig.co` on a dual-stack network | fails (IPv6 blackholed), no leak |
| `dig laptop.internal` | `10.8.1.10` only |
| `dig laptop.udp.internal` | `10.8.0.10` |
| `ping 10.8.0.1` | replies (cross-subnet route) |
| `cat /etc/openvpn/dns/hosts` on server | laptop.internal line moved to the 10.8.1 record |

Then connect both profiles at once (two VPN sessions). `dig laptop.internal`
should return both addresses.

## Phase 4: second client, client-to-client and name following

```sh
vpn-add-client phone
```

Phone on `phone-full-tcp443.ovpn`, laptop on `laptop-split-udp.ovpn`.

| Check | Expected |
|---|---|
| laptop: `ping phone.internal` | resolves to `10.8.1.11`, replies |
| phone: `ping laptop.internal` | resolves to `10.8.0.10`, replies |
| phone switches to `phone-split-udp.ovpn` | within seconds laptop's `dig phone.internal` returns `10.8.0.11` |
| phone disconnects | `dig phone.internal` returns both addresses |
| server: `vpn-list-clients` | asterisks match reality |

## Phase 5: revocation

```sh
vpn-revoke-client phone
```

| Check | Expected |
|---|---|
| phone, if connected | dropped within a few seconds |
| phone reconnects | fails; `journalctl -u openvpn-server@udp` shows "CRL CHECK FAILED" |
| `vpn-list-clients` | phone marked `revoked <date>`, octet 11 still listed |
| `vpn-add-client tablet` | gets octet 12, not 11 |

## Phase 6: restart and reboot

```sh
systemctl restart openvpn-server@udp
vpn-smoke-test
reboot
```

After the reboot, log in again:

| Check | Expected |
|---|---|
| `vpn-smoke-test` | ALL CHECKS PASSED |
| `nft list ruleset` | full ruleset present (not the empty default) |
| laptop auto-reconnects | yes, same fixed IP |
| `/run/openvpn-dns/state/*/` | only currently connected clients |

## Phase 7: re-run installer

```sh
VPN_HOST=TESTHOST ./scripts/install.sh
vpn-smoke-test
vpn-list-clients
```

Expected: no PKI rebuilt, clients and `clients.csv` intact, services restarted,
laptop reconnects.

## Phase 8: negative checks

| Check | Expected |
|---|---|
| Connect with a `.ovpn` whose `tls-crypt` block is altered | server logs nothing meaningful, client times out |
| Remove `ccd-udp/laptop`, reconnect | rejected (`ccd-exclusive`) |
| From outside: `dig @TESTHOST server.internal` | no answer |
| `unattended-upgrades --dry-run --debug` | runs without error |

## Done criteria

All tables pass. Record anything that needed a manual fix in this file,
patch the scripts, revert the VM to its snapshot and run Phase 1 to 3 once more
from scratch. Then destroy the VM.

## Verified so far (2026-10-11)

The Docker harness (Option 0) passes 71 of 71 checks on Debian 12 with
openvpn 2.6.14, easy-rsa 3.1.0, dnsmasq 2.90 and nftables 1.0.6, including the
hardening pass: per-client tls-crypt-v2, admin user with root login disabled,
tunnel-to-server firewall limited to ICMP/DNS/SSH, forget and revoke purging
client secrets, encrypted backup round trip, expiry check and timer. It also
verifies on Debian 12 with
openvpn 2.6.14, easy-rsa 3.1.0, dnsmasq 2.90 and nftables 1.0.6: installer,
smoke test, both instances, fixed IPs, cross-instance routing, split versus
full tunnel, NAT, IPv6 blackhole routes on the client, all DNS behaviours and
name following, revocation with CRL rejection, octet reservation, restart
persistence, client reconnection and an idempotent re-run.

Not covered by the harness and still to be done on a real host (Option A):
public reachability of UDP 1194 and TCP 443, the external port scan, MTU
across the internet, an actual IPv6 leak test, and real client apps on
Windows, macOS, iOS and Android.

## Known gaps to watch for during the test

- Debian's `dnsmasq` unit must support `systemctl reload`. If `vpn-dns-update`
  complains, replace the reload with `systemctl restart dnsmasq`.
- Easy-RSA version differences: `renew` and `--batch revoke` syntax changed
  between 3.0 and 3.1. Debian 12 ships 3.1.0, Debian 13 ships 3.2.
- If the provider VM uses `ens3` or `enp1s0`, the firewall file will say so.
  Confirm `WAN_IF` in the installer output.
