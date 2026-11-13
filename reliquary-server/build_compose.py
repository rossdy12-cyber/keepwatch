"""Regenerates compose.yaml with server.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "server.py").read_text()
assert "$" not in script, "Docker Compose would treat $ as a variable; avoid it in server.py"
embedded = "".join("      " + line if line.strip() else "\n" for line in script.splitlines(keepends=True))

compose = """# Reliquary gallery server for TrueNAS: shows your IDrive-Sync photos and videos in the Reliquary iPhone app.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it reliquary -> paste this file.
# Edit the lines marked CHANGE before saving. Generated from server.py by build_compose.py.
services:
  reliquary:
    image: python:3.12-alpine
    container_name: reliquary
    restart: unless-stopped
    network_mode: host
    command: sh -c "apk add --no-cache --quiet ffmpeg && pip install --quiet --disable-pip-version-check --root-user-action=ignore Pillow==11.0.0 pillow-heif==0.21.0 && exec python -u /server.py"
    configs:
      - source: server
        target: /server.py
    volumes:
      # CHANGE: the real path of your IDrive-Sync folder on the NAS (the left side). ":ro" = read-only:
      # Reliquary can never change or delete anything in it.
      - /mnt/CHANGE-ME-pool/IDrive-Sync:/gallery:ro
      # Thumbnails, the date index and favourites.
      - reliquary-cache:/cache
    environment:
      # CHANGE: a long random password. Type the same thing into Reliquary's "Token" field.
      GALLERY_TOKEN: CHANGE-ME-to-a-long-random-password
      # The port Reliquary connects to: http://<your NAS's Tailscale IP>:8788
      PORT: "8788"
      # How often to look for new photos.
      RESCAN_MINUTES: "30"
      # true = also show files and folders whose names start with a dot.
      SHOW_HIDDEN: "false"
      GALLERY_ROOT: /gallery
      CACHE_DIR: /cache
      TZ: Europe/London

volumes:
  reliquary-cache:

configs:
  server:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
