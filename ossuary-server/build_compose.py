"""Regenerates compose.yaml with server.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "server.py").read_text()
assert "$" not in script, "Docker Compose would treat $ as a variable; avoid it in server.py"
embedded = "".join("      " + line if line.strip() else "\n" for line in script.splitlines(keepends=True))

compose = """# Ossuary game library server for TrueNAS: shows the games on your NAS in the Ossuary iPhone app.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it ossuary -> paste this file.
# Edit the lines marked CHANGE before saving. Generated from server.py by build_compose.py.
services:
  ossuary:
    image: python:3.12-alpine
    container_name: ossuary
    restart: unless-stopped
    network_mode: host
    command: python -u /server.py
    configs:
      - source: server
        target: /server.py
    volumes:
      # CHANGE: the real path of your games folder on the NAS (the left side). It must start with /mnt/
      # (keep the leading slash). Inside it, one folder per system: snes, gba, psx, n64, nds, megadrive, PC ...
      # ":ro" = read-only: Ossuary can never change or delete anything in it.
      - /mnt/CHANGE-ME-pool/Games:/games:ro
      # Downloaded box art.
      - ossuary-cache:/cache
    environment:
      # CHANGE: a long random password. Type the same thing into Ossuary's "Token" field.
      OSSUARY_TOKEN: CHANGE-ME-to-a-long-random-password
      # The port Ossuary connects to: http://<your NAS's Tailscale IP>:8789
      PORT: "8789"
      # false = never fetch box art from the libretro thumbnail archive (only use art files on the NAS).
      ONLINE_ART: "true"
      GAMES_ROOT: /games
      CACHE_DIR: /cache
      TZ: Europe/London

volumes:
  ossuary-cache:

configs:
  server:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
