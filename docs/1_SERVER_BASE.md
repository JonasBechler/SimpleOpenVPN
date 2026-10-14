# 1. Server base

What `scripts/install.sh` does to the operating system before OpenVPN is touched,
and why.

## Prerequisites

- Fresh Debian 12 or 13, minimal install, public IPv4.
- A DNS name pointing at the server (or use the IP as `VPN_HOST`).
- Your SSH public key already in `/root/.ssh/authorized_keys` or a user's
  `~/.ssh/authorized_keys`. The installer refuses to run otherwise, because it
  is about to switch off password login.

## Admin user (recommended)

With `ADMIN_USER=alice` the installer sets `PermitRootLogin no` and makes
that user the operator: profiles and backups are written to its home so they
can be fetched with plain `scp`. If the user does not exist it is created with
root's `authorized_keys` and passwordless sudo. If it already exists, its SSH
keys and sudo configuration are left untouched (it is added to the `sudo`
group if it had no sudo at all). The `vpn-*` commands are then run with
`sudo`. Without `ADMIN_USER`, root login stays allowed with a key only.

## SSH: key-only

`/etc/ssh/sshd_config.d/10-hardening.conf` disables password and
keyboard-interactive auth, sets `PermitRootLogin prohibit-password`, and lowers
`MaxAuthTries` and `LoginGraceTime`. The config is validated with `sshd -t`
before reload, so a typo cannot lock you out.

Keep your current session open and test a second login after the installer
finishes.

## Automatic security updates

`unattended-upgrades` with Debian's default origin list (security + stable
updates). Local overrides in `52unattended-upgrades-local`:

- remove unused kernels and dependencies,
- reboot automatically at 04:30 when a kernel update requires it.

The reboot briefly drops all VPN sessions once every few weeks. Clients
reconnect on their own. Remove the two `Automatic-Reboot` lines if you prefer
to reboot manually.

## Firewall: nftables

`/etc/nftables.conf`, policy drop on input and forward:

| Direction | Allowed |
|---|---|
| input | loopback, established, ICMP, SSH port, UDP 1194, TCP 443; from `tun-*` only ICMP, DNS (53) and SSH |
| forward | established, `tun-*` to `tun-*` (clients reach each other across both instances), `tun-tcp` to the public interface (full tunnel) |
| nat | masquerade `10.8.1.0/24` out of the public interface |

VPN clients can reach the server itself only on ICMP, DNS and SSH. Everything
else the server might listen on is dropped from the tunnel side, so a
compromised client cannot probe the host. dnsmasq is bound to the tunnel
interfaces only, so port 53 is never exposed on the public interface.

The split-tunnel subnet `10.8.0.0/24` is deliberately not NATed. Those clients
only ever talk to other VPN addresses.

## Kernel

`net.ipv4.ip_forward = 1` via `/etc/sysctl.d/99-openvpn.conf`.
