#!/bin/sh
# Starts Synapse, creating and adjusting its config on the first run.
set -e
: "${SERVER_NAME:?SERVER_NAME must be set}"

if [ ! -f /data/homeserver.yaml ]; then
    echo "First start: generating the Synapse config for $SERVER_NAME"
    SYNAPSE_SERVER_NAME="$SERVER_NAME" SYNAPSE_REPORT_STATS=no /start.py generate
fi

# A registration that lets the bridges act as you ("double puppeting"),
# so messages you send from your phone show up as you, not as a bridge user.
if [ ! -f /appservices/doublepuppet.yaml ]; then
    python3 /setup/patch_synapse.py doublepuppet
fi

# Wait (up to 3 minutes) for both bridges to write their registrations.
i=0
while [ $i -lt 90 ] && { [ ! -f /appservices/whatsapp.yaml ] || [ ! -f /appservices/discord.yaml ]; }; do
    [ $i -eq 0 ] && echo "Waiting for the bridges to register…"
    sleep 2
    i=$((i + 1))
done

python3 /setup/patch_synapse.py config

# Create your account once Synapse is answering.
(
    until curl -fsS http://localhost:8008/health >/dev/null 2>&1; do sleep 2; done
    if [ -n "$MATRIX_USER" ] && [ -n "$MATRIX_PASSWORD" ]; then
        if register_new_matrix_user -c /data/homeserver.yaml -u "$MATRIX_USER" -p "$MATRIX_PASSWORD" -a http://localhost:8008 >/tmp/register.log 2>&1; then
            echo "Created the account @$MATRIX_USER:$SERVER_NAME"
        elif grep -qi "taken\|in use" /tmp/register.log; then
            echo "The account @$MATRIX_USER:$SERVER_NAME already exists"
        else
            echo "Couldn't create @$MATRIX_USER:$SERVER_NAME:" && cat /tmp/register.log
        fi
    fi
) &

exec /start.py
