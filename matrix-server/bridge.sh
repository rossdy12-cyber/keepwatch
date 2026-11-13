#!/bin/sh
# Configures and starts a mautrix bridge (BRIDGE=whatsapp or discord) without any manual editing.
set -e
: "${BRIDGE:?}" "${PORT:?}" "${SERVER_NAME:?}" "${MATRIX_USER:?}"
BIN=/usr/bin/mautrix-$BRIDGE
CFG=/data/config.yaml
export ADMIN="@$MATRIX_USER:$SERVER_NAME"
export HS="http://synapse:8008"
export AS="http://$BRIDGE:$PORT"
export DB="file:/data/mautrix-$BRIDGE.db?_txlock=immediate"

if [ ! -f "$CFG" ]; then
    echo "First start: creating the $BRIDGE bridge config"
    if [ "$BRIDGE" = discord ]; then
        cp /opt/mautrix-discord/example-config.yaml "$CFG"
    else
        "$BIN" -c "$CFG" -e
    fi
fi

# Settings applied on every start, so the YAML on TrueNAS stays the source of truth.
yq -i '
  .homeserver.address = strenv(HS) |
  .homeserver.domain = strenv(SERVER_NAME) |
  .appservice.address = strenv(AS) |
  .appservice.hostname = "0.0.0.0" |
  .appservice.port = (strenv(PORT) | tonumber)
' "$CFG"

if [ "$BRIDGE" = whatsapp ]; then
    yq -i '
      .database.type = "sqlite3-fk-wal" |
      .database.uri = strenv(DB) |
      .bridge.permissions = {"*": "relay"} |
      .bridge.permissions[strenv(SERVER_NAME)] = "user" |
      .bridge.permissions[strenv(ADMIN)] = "admin" |
      .bridge.personal_filtering_spaces = true |
      .bridge.private_chat_portal_meta = true |
      .encryption.allow = false |
      .encryption.default = false |
      .network.os_name = "Mautrix-WhatsApp bridge" |
      .network.displayname_template = "{{or .FullName .BusinessName .PushName .Phone \"Unknown\"}}" |
      .network.history_sync.request_full_sync = false |
      .backfill.enabled = true |
      .backfill.max_initial_messages = 50 |
      .backfill.max_catchup_messages = 500 |
      .logging.writers = [.logging.writers[0]]
    ' "$CFG"
else
    yq -i '
      .appservice.database.type = "sqlite3-fk-wal" |
      .appservice.database.uri = strenv(DB) |
      .bridge.permissions = {"*": "relay"} |
      .bridge.permissions[strenv(SERVER_NAME)] = "user" |
      .bridge.permissions[strenv(ADMIN)] = "admin" |
      .bridge.encryption.allow = false |
      .bridge.encryption.default = false |
      .bridge.private_chat_portal_meta = "always" |
      .bridge.startup_private_channel_create_limit = 25 |
      .bridge.backfill.forward_limits.initial.dm = 50 |
      .bridge.backfill.forward_limits.initial.channel = 50 |
      .bridge.backfill.forward_limits.initial.thread = 20 |
      .bridge.backfill.forward_limits.missed.dm = 200 |
      .bridge.backfill.forward_limits.missed.channel = 200 |
      .logging.file_name_format = ""
    ' "$CFG"
fi

if [ ! -f /data/registration.yaml ]; then
    echo "Generating the $BRIDGE appservice registration"
    "$BIN" -g -c "$CFG" -r /data/registration.yaml
fi
mkdir -p /appservices
cp /data/registration.yaml "/appservices/$BRIDGE.yaml"
chmod 644 "/appservices/$BRIDGE.yaml"

echo "Waiting for Synapse…"
until wget -q -O /dev/null http://synapse:8008/health 2>/dev/null; do sleep 3; done

# Double puppeting with the token Synapse created.
if [ -f /appservices/doublepuppet.token ]; then
    export DP="as_token:$(cat /appservices/doublepuppet.token)"
    if [ "$BRIDGE" = whatsapp ]; then
        yq -i '.double_puppet.secrets = {} | .double_puppet.secrets[strenv(SERVER_NAME)] = strenv(DP) | .double_puppet.servers = {}' "$CFG"
    else
        yq -i '.bridge.login_shared_secret_map = {} | .bridge.login_shared_secret_map[strenv(SERVER_NAME)] = strenv(DP) | .bridge.double_puppet_server_map = {}' "$CFG"
    fi
fi

cd /data
chown -R "$UID:$GID" /data
exec su-exec "$UID:$GID" "$BIN"
