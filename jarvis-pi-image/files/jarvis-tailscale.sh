#!/bin/bash
# Joins Tailscale using TAILSCALE_AUTHKEY from /boot/firmware/jarvis.txt, then blanks the key.
# Runs after the network is up and before the voice speaker, so the NAS is reachable over Tailscale.
# No-op when no key is set (so a Pi on the local network is unaffected).
set -u
ROOT="${JARVIS_ROOT:-}"
CONFIG="$ROOT/boot/firmware/jarvis.txt"
TESTING="${JARVIS_TESTING:-}"
log() { echo "jarvis-tailscale: $*"; }

[ -f "$CONFIG" ] || exit 0

# KEY=value lines; Windows line endings, spaces and stray quotes are fine.
get() {
  local value
  value=$(tr -d '\r' < "$CONFIG" | grep -E "^[[:space:]]*$1[[:space:]]*=" | tail -n 1 | cut -d= -f2-)
  value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"; value="${value%\"}"; value="${value#\'}"; value="${value%\'}"
  [ "$value" = "(saved)" ] && value=""
  printf '%s' "$value"
}
forget() { sed -i -E "s/^([[:space:]]*$1[[:space:]]*=).*/\1(saved)/" "$CONFIG"; }

KEY=$(get TAILSCALE_AUTHKEY)
HOST=$(get HOSTNAME); HOST=${HOST:-jarvis-pi}

[ -n "$KEY" ] || { log "no auth key set; leaving Tailscale as it is"; exit 0; }

if [ -n "$TESTING" ]; then
  log "(testing: would run tailscale up as $HOST)"
  forget TAILSCALE_AUTHKEY
  exit 0
fi

command -v tailscale >/dev/null 2>&1 || { log "tailscale isn't installed on this image"; exit 0; }

systemctl start tailscaled 2>/dev/null || true
# Wait briefly for the daemon's socket.
for _ in $(seq 1 15); do [ -S /var/run/tailscale/tailscaled.sock ] && break; sleep 1; done

if tailscale up --authkey="$KEY" --hostname="$HOST" --timeout=30s >/dev/null 2>&1; then
  forget TAILSCALE_AUTHKEY
  log "connected to Tailscale as $HOST"
else
  log "tailscale up failed — check the auth key (it may have expired or already been used)"
fi
exit 0
