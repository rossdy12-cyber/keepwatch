#!/bin/bash
# Before Jarvis starts: fetches the newest speaker program from the NAS (keeps the built-in one if that fails).
. /etc/jarvis-voice.env 2>/dev/null || exit 0
[ -n "${HUB_HOST:-}" ] && [ -n "${HUB_TOKEN:-}" ] || exit 0
TMP=$(mktemp)
if curl -fsS --max-time 10 "http://$HUB_HOST:${HUB_HTTP_PORT:-10701}/pi/client.py?token=$HUB_TOKEN" -o "$TMP" \
   && python3 -m py_compile "$TMP" 2>/dev/null; then
  install -m 755 "$TMP" /opt/jarvis-voice/jarvis-pi.py
fi
rm -f "$TMP"
exit 0
