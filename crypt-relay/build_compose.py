"""Regenerates compose.yaml with relay.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "relay.py").read_text()
assert "$" not in script, "Docker Compose would treat $ as a variable; avoid it in relay.py"
embedded = "".join("      " + line if line.strip() else "\n" for line in script.splitlines(keepends=True))

compose = """# Crypt push relay for TrueNAS: sends an Apple push to Crypt when new mail arrives.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it crypt-relay -> paste this file.
# Edit the lines marked CHANGE before saving. Generated from relay.py by build_compose.py.
services:
  crypt-relay:
    image: python:3.12-alpine
    container_name: crypt-relay
    restart: unless-stopped
    network_mode: host
    command: sh -c "pip install --quiet --disable-pip-version-check --root-user-action=ignore 'httpx[http2]==0.28.1' 'PyJWT[crypto]==2.10.1' && exec python -u /relay.py"
    configs:
      - source: relay
        target: /relay.py
    volumes:
      # Registered iPhones and the accounts they watch (including mail passwords). Readable only by the container.
      - crypt-relay-data:/data
    environment:
      # CHANGE: a long random password. Type the same thing into Crypt -> Notifications -> Relay secret.
      RELAY_SECRET: CHANGE-ME-to-a-long-random-password
      # CHANGE: your APNs key from developer.apple.com -> Certificates, IDs & Profiles -> Keys.
      # Open the .p8 file in Notepad and paste ALL of it below, keeping the 6-space indent on every line.
      APNS_KEY: |
        -----BEGIN PRIVATE KEY-----
        CHANGE-ME-paste-the-lines-of-your-p8-file-here
        -----END PRIVATE KEY-----
      # CHANGE: the 10-character Key ID shown next to the key, and your Team ID (top right of the developer site).
      APNS_KEY_ID: CHANGEME00
      APNS_TEAM_ID: CHANGEME00
      # auto tries the sandbox first (Sideloadly installs use a development profile), then production.
      APNS_ENVIRONMENT: auto
      # false = notifications say "New letter" instead of showing the subject.
      SHOW_PREVIEW: "true"
      # The port Crypt connects to: http://<your NAS's Tailscale IP>:8787
      PORT: "8787"
      DATA_DIR: /data
      TZ: Europe/London

volumes:
  crypt-relay-data:

configs:
  relay:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
