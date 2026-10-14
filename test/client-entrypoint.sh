#!/bin/sh
# Waits for the profile to appear, then runs OpenVPN in the foreground.
# PROFILE is the .ovpn path under /configs (written by vpn-add-client on the server).
set -eu
: "${PROFILE:?set PROFILE, e.g. laptop/laptop-split-udp.ovpn}"
i=0
while [ ! -s "/configs/$PROFILE" ]; do
  i=$((i+1)); [ $i -gt 120 ] && { echo "profile /configs/$PROFILE never appeared"; exit 1; }
  sleep 1
done
exec openvpn --config "/configs/$PROFILE" --verb 3
