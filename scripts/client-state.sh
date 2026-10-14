#!/bin/sh
# Runs inside OpenVPN (as nobody) on client-connect / client-disconnect.
# Records which instance a client is connected to; vpn-dns-update turns that
# into DNS records. Must never fail: a non-zero exit would reject the client.
# shellcheck disable=SC2154  # common_name and script_type are set by OpenVPN
d="/run/openvpn-dns/state/${INSTANCE:-unknown}"
case "${script_type:-}" in
  client-connect)    : > "$d/$common_name" 2>/dev/null ;;
  client-disconnect) rm -f "$d/$common_name" 2>/dev/null ;;
esac
exit 0
