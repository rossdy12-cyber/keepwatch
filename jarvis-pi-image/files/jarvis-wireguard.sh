#!/bin/bash
# Brings up a WireGuard tunnel so the Pi can reach a hub on the internet (e.g. a VPS) securely.
# Drop a `wireguard.conf` onto the boot partition (next to jarvis.txt). On boot it's moved to
# /etc/wireguard/wg0.conf (so the private key isn't left on the card) and the tunnel is started.
# Runs after the network is up and before the voice speaker. No-op when there's no config.
set -u
ROOT="${JARVIS_ROOT:-}"
TESTING="${JARVIS_TESTING:-}"
BOOTCONF="$ROOT/boot/firmware/wireguard.conf"
DEST="$ROOT/etc/wireguard/wg0.conf"
log() { echo "jarvis-wireguard: $*"; }

# A new config dropped on the boot partition replaces the installed one, then the boot copy
# (which holds the private key) is removed.
if [ -f "$BOOTCONF" ]; then
  mkdir -p "$ROOT/etc/wireguard"
  (umask 077; cp "$BOOTCONF" "$DEST")
  chmod 600 "$DEST"
  rm -f "$BOOTCONF"
  log "installed WireGuard config from the boot partition"
fi

[ -f "$DEST" ] || { log "no WireGuard config; skipping"; exit 0; }

if [ -n "$TESTING" ]; then
  log "(testing: would bring up wg0)"
  exit 0
fi

command -v wg-quick >/dev/null 2>&1 || { log "wireguard-tools isn't installed on this image"; exit 0; }

systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
if systemctl restart wg-quick@wg0 >/dev/null 2>&1; then
  log "WireGuard tunnel wg0 is up"
else
  log "couldn't bring up WireGuard (check wireguard.conf)"
fi
exit 0
