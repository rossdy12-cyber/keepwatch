#!/bin/bash
# Sets up WireGuard on your VPS (the Jarvis hub) and prints the wireguard.conf to copy onto the Pi's card.
# Run it on the VPS as root:   sudo bash vps-wireguard-setup.sh [PUBLIC_IP_OR_HOSTNAME]
# If you don't pass an address, it tries to detect the VPS's public IP.
set -euo pipefail

WG_NET="10.9.0"           # tunnel subnet: VPS = .1, Pi = .2
WG_PORT="${WG_PORT:-51820}"
ENDPOINT="${1:-}"

[ "$(id -u)" = 0 ] || { echo "Run with sudo/root."; exit 1; }

echo "== Installing WireGuard"
if command -v apt-get >/dev/null; then
  apt-get update -qq && apt-get install -y -qq wireguard-tools iproute2
elif command -v dnf >/dev/null; then
  dnf install -y wireguard-tools
fi

if [ -z "$ENDPOINT" ]; then
  ENDPOINT=$(curl -fsS https://api.ipify.org 2>/dev/null || curl -fsS https://ifconfig.me 2>/dev/null || true)
fi
[ -n "$ENDPOINT" ] || { echo "Couldn't detect the public IP; pass it as the first argument."; exit 1; }

umask 077
mkdir -p /etc/wireguard
cd /etc/wireguard

# Keep the server key stable across re-runs; always make a fresh Pi key.
[ -f server.key ] || wg genkey > server.key
SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | wg pubkey)
PI_PRIV=$(wg genkey)
PI_PUB=$(printf '%s' "$PI_PRIV" | wg pubkey)

cat > wg0.conf <<CONF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

[Peer]
# Jarvis Pi
PublicKey = ${PI_PUB}
AllowedIPs = ${WG_NET}.2/32
CONF
chmod 600 wg0.conf

echo "== Starting WireGuard"
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0

echo "== Opening UDP ${WG_PORT}"
if command -v ufw >/dev/null; then ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true; fi
if command -v firewall-cmd >/dev/null; then firewall-cmd --add-port="${WG_PORT}/udp" --permanent >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi

cat <<DONE

============================================================================
 WireGuard is up on the VPS.
 The Jarvis hub is now reachable at ${WG_NET}.1 over the tunnel.

 1) Save the text below as a file called  wireguard.conf  and copy it onto
    the Pi's card (the "bootfs" drive, next to jarvis.txt).
 2) In jarvis.txt set:   HUB_ADDRESS=${WG_NET}.1
 3) You can now CLOSE the public hub ports (10700, 10701) on the VPS — the
    Pi reaches them privately over WireGuard. Only UDP ${WG_PORT} needs to be open.
----------------------------- wireguard.conf -------------------------------
[Interface]
PrivateKey = ${PI_PRIV}
Address = ${WG_NET}.2/24

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_NET}.0/24
PersistentKeepalive = 25
----------------------------------------------------------------------------
DONE
