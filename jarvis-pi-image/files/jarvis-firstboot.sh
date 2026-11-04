#!/bin/bash
# Runs early on every boot: applies /boot/firmware/jarvis.txt (Wi-Fi, NAS, login, name).
# JARVIS_ROOT lets this be tested against a folder instead of a real Pi.
set -u
ROOT="${JARVIS_ROOT:-}"
CONFIG="$ROOT/boot/firmware/jarvis.txt"
TESTING="${JARVIS_TESTING:-}"
log() { echo "jarvis-setup: $*"; }

[ -f "$CONFIG" ] || { log "no jarvis.txt on the boot partition; nothing to do"; exit 0; }

# KEY=value lines; Windows line endings, spaces and stray quotes are fine.
get() {
  local value
  value=$(tr -d '\r' < "$CONFIG" | grep -E "^[[:space:]]*$1[[:space:]]*=" | tail -n 1 | cut -d= -f2-)
  value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"; value="${value%\"}"; value="${value#\'}"; value="${value%\'}"
  [ "$value" = "(saved)" ] && value=""
  printf '%s' "$value"
}
# Replaces a used secret on the card with (saved).
forget() {
  sed -i -E "s/^([[:space:]]*$1[[:space:]]*=).*/\1(saved)/" "$CONFIG"
}

WIFI_NAME=$(get WIFI_NAME)
WIFI_PASSWORD=$(get WIFI_PASSWORD)
WIFI_COUNTRY=$(get WIFI_COUNTRY); WIFI_COUNTRY=${WIFI_COUNTRY:-GB}
HUB_ADDRESS=$(get HUB_ADDRESS)
HUB_KEY=$(get HUB_KEY)
USERNAME=$(get USERNAME); USERNAME=${USERNAME:-jarvis}
PASSWORD=$(get PASSWORD)
NEW_HOSTNAME=$(get HOSTNAME)

# ---- Name on the network
if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$(cat "$ROOT/etc/hostname" 2>/dev/null)" ]; then
  if [[ "$NEW_HOSTNAME" =~ ^[A-Za-z0-9-]{1,63}$ ]]; then
    echo "$NEW_HOSTNAME" > "$ROOT/etc/hostname"
    sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" "$ROOT/etc/hosts"
    grep -q "^127.0.1.1" "$ROOT/etc/hosts" || printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> "$ROOT/etc/hosts"
    [ -z "$TESTING" ] && hostname "$NEW_HOSTNAME"
    log "name set to $NEW_HOSTNAME"
  else
    log "HOSTNAME may only use letters, numbers and dashes; kept the old name"
  fi
fi

# ---- Wi-Fi (NetworkManager), only when a new password is given
if [ -n "$WIFI_NAME" ] && [ -n "$WIFI_PASSWORD" ]; then
  mkdir -p "$ROOT/etc/NetworkManager/system-connections"
  FILE="$ROOT/etc/NetworkManager/system-connections/jarvis-wifi.nmconnection"
  umask 077
  cat > "$FILE" <<NM
[connection]
id=jarvis-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_NAME

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASSWORD

[ipv4]
method=auto

[ipv6]
method=auto
NM
  chmod 600 "$FILE"
  umask 022
  forget WIFI_PASSWORD
  log "Wi-Fi set to $WIFI_NAME"
fi
if [ -z "$TESTING" ]; then
  raspi-config nonint do_wifi_country "$WIFI_COUNTRY" >/dev/null 2>&1 || iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || true
  for state in /var/lib/systemd/rfkill/*:wlan; do [ -e "$state" ] && echo 0 > "$state"; done
fi

# ---- The NAS's Jarvis hub
ENV="$ROOT/etc/jarvis-voice.env"
if [ -n "$HUB_ADDRESS" ] || [ -n "$HUB_KEY" ]; then
  OLD_HOST=$(grep -s '^HUB_HOST=' "$ENV" | cut -d= -f2-)
  OLD_KEY=$(grep -s '^HUB_TOKEN=' "$ENV" | cut -d= -f2-)
  HOST=${HUB_ADDRESS:-$OLD_HOST}
  HOST=${HOST#http://}; HOST=${HOST#https://}; HOST=${HOST%%/*}; HOST=${HOST%%:*}
  KEY=${HUB_KEY:-$OLD_KEY}
  umask 077
  cat > "$ENV" <<ENVFILE
HUB_HOST=$HOST
HUB_PORT=10700
HUB_HTTP_PORT=10701
HUB_TOKEN=$KEY
SATELLITE_NAME=${NEW_HOSTNAME:-jarvis-pi}
ENVFILE
  umask 022
  [ -n "$HUB_KEY" ] && forget HUB_KEY
  log "Jarvis hub set to $HOST"
fi

# ---- Login for SSH
if [ -n "$TESTING" ]; then
  log "(testing: would set up user $USERNAME${PASSWORD:+ with a password})"
  [ -n "$PASSWORD" ] && forget PASSWORD
elif ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev "$USERNAME" 2>/dev/null \
    || useradd -m -s /bin/bash -G sudo,audio "$USERNAME"
  if [ -n "$PASSWORD" ]; then
    echo "$USERNAME:$PASSWORD" | chpasswd && forget PASSWORD
  else
    passwd -l "$USERNAME" >/dev/null
  fi
  log "created user $USERNAME"
elif [ -n "$PASSWORD" ]; then
  echo "$USERNAME:$PASSWORD" | chpasswd && passwd -u "$USERNAME" >/dev/null 2>&1
  forget PASSWORD
  log "password updated for $USERNAME"
fi
exit 0
