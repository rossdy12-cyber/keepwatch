"""Regenerates compose.yaml with notifier.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "notifier.py").read_text()
assert "$" not in script, "Docker Compose would treat $ as a variable; avoid it in notifier.py"
embedded = "".join("      " + line if line.strip() else "\n" for line in script.splitlines(keepends=True))

compose = """# Frigate -> ntfy notifier for TrueNAS.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it frigate-ntfy -> paste this file.
# Edit the lines marked CHANGE before saving. Generated from notifier.py by build_compose.py.
services:
  frigate-ntfy:
    image: python:3.12-alpine
    container_name: frigate-ntfy
    restart: unless-stopped
    network_mode: host
    command: sh -c "pip install --quiet --disable-pip-version-check --root-user-action=ignore paho-mqtt==2.1.0 && exec python -u /notifier.py"
    configs:
      - source: notifier
        target: /notifier.py
    environment:
      # CHANGE: your own secret topic. Anyone who knows it can see your snapshots, so make it long and random.
      NTFY_TOPIC: CHANGE-ME-to-something-like-cams-k7f2q9x4m1
      NTFY_SERVER: https://ntfy.sh
      NTFY_PRIORITY: high
      # The MQTT broker Frigate uses (the "mqtt: host/port" in Frigate's config).
      MQTT_HOST: 100.85.127.42
      MQTT_PORT: "1883"
      MQTT_USER: ""
      MQTT_PASSWORD: ""
      # Frigate's web address. A Frigate login lets the notifier attach the exact event snapshot;
      # without one it uses the latest snapshot Frigate posted over MQTT.
      FRIGATE_URL: https://100.85.127.42:8971
      FRIGATE_USER: ""
      FRIGATE_PASSWORD: ""
      # Which cameras / objects notify you. Empty = all. Use Frigate's camera names, comma-separated,
      # e.g. CAMERAS: tapo_c200,ezviz  LABELS: person,car
      CAMERAS: ""
      LABELS: ""
      ZONES: ""
      MIN_SCORE: "0"
      # At most one notification per camera and object type in this many seconds.
      COOLDOWN_SECONDS: "60"
      # Sends a "notifier is running" message when it starts.
      SEND_TEST: "true"
      TZ: Europe/London

configs:
  notifier:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
