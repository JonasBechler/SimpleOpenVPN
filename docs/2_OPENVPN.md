# 2. OpenVPN design

## Two instances, one PKI

| Instance | systemd unit | Port | Subnet | Routing |
|---|---|---|---|---|
| split | `openvpn-server@udp` | UDP 1194 | `10.8.0.0/24` | pushes only `10.8.1.0/24`; own subnet is implicit |
| full | `openvpn-server@tcp443` | TCP 443 | `10.8.1.0/24` | `redirect-gateway def1 ipv6`, DNS pushed, NAT on the server, IPv6 blackholed |

Both instances read the same CA, server certificate, `tls-crypt` key and CRL
from `/etc/openvpn/server/`. A client therefore has a single certificate and two
`.ovpn` files. It may be connected to both instances at the same time.

TCP 443 is chosen because it passes almost every captive portal and corporate
firewall. UDP 1194 is the fast path for everyday use.

## PKI (Easy-RSA 3)

Location: `/etc/openvpn/easy-rsa`, settings in `vars`:

- EC keys on `secp384r1`, SHA-256 signatures. Small, fast, no DH parameters
  needed (`dh none`).
- CA valid 10 years, certificates 5 years, CRL 10 years.
- The CA key is passphrase protected unless you installed with `CA_NOPASS=1`.
  You are asked for it when adding or revoking clients. During `build-ca`
  Easy-RSA 3.1 and OpenSSL each prompt twice; type the same passphrase four
  times.

## Fixed IPs

Each client gets one host octet and uses it in both subnets: client number
10 is `10.8.0.10` on the split instance and `10.8.1.10` on the full instance.
Automatic assignment takes the lowest free number from 10 upward;
`vpn-add-client NAME --ip N` pins any free number from 2 to 254. The mapping lives in two places:

- `/etc/openvpn/server/ccd-udp/NAME` and `ccd-tcp443/NAME` containing
  `ifconfig-push`, which OpenVPN enforces.
- `/etc/openvpn/clients.csv`, the human-readable registry that
  `vpn-list-clients` prints.

`ccd-exclusive` is set, so a certificate without a ccd file cannot connect.
Revoked clients keep their octet reserved so an address is never reused.

## Crypto and hardening in the server config

- `tls-crypt-v2`: the control channel is encrypted and authenticated before
  any TLS work, so port scanners see nothing that looks like OpenVPN. Unlike
  plain `tls-crypt`, every client has its own key, wrapped with the server key
  at creation time. A leaked or revoked profile does not expose a shared
  secret. Clients need OpenVPN 2.5 or newer, which every current app has.
- `remote-cert-tls client` on the server, `remote-cert-tls server` on the
  client: a client certificate cannot be used to impersonate the server.
- `crl-verify`: revocations take effect on the next handshake, no restart.
- `data-ciphers AES-256-GCM:CHACHA20-POLY1305`, `auth SHA256`,
  `tls-version-min 1.2`, `tls-cert-profile preferred`.
- Runs as `nobody:nogroup` after startup with `persist-key` / `persist-tun`.
- `client-to-client` inside an instance, kernel forwarding plus the nftables
  `tun-*` to `tun-*` rule between instances.
- IPv6 on the full tunnel: the server has no public IPv6 routing, so the
  instance hands out a ULA (`fd42:8:1::/64`), pushes `redirect-gateway ipv6`
  and `block-ipv6`. Dual-stack clients then get "unreachable" for IPv6 instead
  of leaking around the tunnel. The installer skips this when IPv6 is disabled
  on the server. A Linux client with IPv6 disabled must add
  `pull-filter ignore "ifconfig-ipv6"` and `pull-filter ignore "route-ipv6"`
  to its full-tunnel profile.

## DNS: the `.internal` domain

A dnsmasq instance on the server answers `*.internal` and forwards everything else
to the upstream resolvers (`DNS1`/`DNS2`). It listens only on `tun-udp` and
`tun-tcp` (`bind-dynamic`, so it survives the interfaces appearing after boot)
and is pushed to clients by both instances:

| Instance | pushed resolver | pushed search domain |
|---|---|---|
| split (UDP) | `10.8.0.1` | `internal` |
| full (TCP) | `10.8.1.1` | `internal` |

Names for a client with host octet N:

| Name | Resolves to |
|---|---|
| `NAME.udp.internal` | `10.8.0.N`, always |
| `NAME.tcp.internal` | `10.8.1.N`, always |
| `NAME.internal` | the address on the instance NAME is connected to right now; both addresses while it is offline |
| `server.internal`, `server.udp.internal`, `server.tcp.internal` | the server's tunnel addresses |

Because the two subnets are routed between each other, `laptop.internal` works
no matter which profile the asking device or the laptop itself is using.

How `NAME.internal` follows the live connection:

1. OpenVPN runs `/etc/openvpn/scripts/client-state.sh` on `client-connect` and
   `client-disconnect` (as `nobody`). It creates or removes
   `/run/openvpn-dns/state/<instance>/NAME`.
2. `openvpn-dns.path` watches those directories and runs `vpn-dns-update`
   (as root), which rewrites `/etc/openvpn/dns/hosts` from `clients.csv` plus the
   presence files and reloads dnsmasq. A two-minute timer is the safety net.
3. Presence files are wiped when an instance stops or starts, so a restart
   cannot leave stale names.

Client-side notes:

- Windows, macOS, iOS, Android and NetworkManager-based Linux apply pushed DNS
  automatically. Plain Linux `openvpn` CLI needs `script-security 2` plus
  `update-resolv-conf` or `update-systemd-resolved` in the client config.
- On the split profile some systems send all DNS through the tunnel rather
  than just `.internal`. That still works, dnsmasq forwards it upstream.
- `.internal` is reserved by ICANN for private use (July 2024), so it can never
  collide with a public domain. Set `VPN_DOMAIN=home.arpa` at install time if
  you prefer the RFC 8375 zone.

## Secrets on the server

The server must hold the CA key and its own key. It does not need to keep
client private keys. `vpn-add-client` writes them into the profiles under
`vpn-clients/NAME/` in the admin user's home; once copied to the device, run
`vpn-forget-client NAME` to shred the profiles, the client private key and its
tls-crypt-v2 key. The certificate stays valid and revocation keeps working.
`vpn-revoke-client` purges the same files.

## Files

```
/etc/openvpn/
  vpn.env              host, ports, subnets; sourced by the vpn-* scripts
  clients.csv          registry: name, octet, both IPs, created, status
  dns/hosts            generated *.internal records read by dnsmasq
  scripts/client-state.sh   connect/disconnect hook
  easy-rsa/pki/        Easy-RSA 3 PKI (vars lives inside, as 3.1 expects)
  server/
    udp.conf  tcp443.conf
    ca.crt  server.crt  server.key  tls-crypt-v2-server.key  crl.pem
    ccd-udp/  ccd-tcp443/
~ADMIN_USER/vpn-clients/NAME/   (or /root/vpn-clients/)
    NAME-split-udp.ovpn  NAME-full-tcp443.ovpn
/run/openvpn-server/
    status-udp.log  status-tcp443.log      used by vpn-list-clients
    mgmt-udp.sock   mgmt-tcp443.sock       used by vpn-revoke-client
/run/openvpn-dns/state/{udp,tcp443}/NAME   presence files
/etc/dnsmasq.d/openvpn.conf
/etc/systemd/system/openvpn-dns.{service,path,timer}
```
