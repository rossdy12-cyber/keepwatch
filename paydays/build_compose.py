"""Regenerates compose.yaml with server.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "server.py").read_text()
assert "$" not in script, "Docker Compose would treat $ as a variable; avoid it in server.py"
embedded = "".join("      " + line if line.strip() else "\n" for line in script.splitlines(keepends=True))

compose = """# Paydays: monthly bills against weekly pay, and how much is safe to spend each week.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it paydays -> paste this file.
# Then open http://<nas-ip>:8450 (or add a proxy host for it). Generated from server.py by build_compose.py.
services:
  paydays:
    image: python:3.12-alpine
    container_name: paydays
    restart: unless-stopped
    command: python -u /app/server.py
    ports:
      - "8450:8450"
    configs:
      - source: server
        target: /app/server.py
    volumes:
      # Your bills and pay are kept here. To keep them in a dataset you back up, replace this with a path,
      # e.g. /mnt/<pool>/apps/paydays:/data
      - paydays-data:/data
    environment:
      TZ: Europe/London
      # Optional: a password for the page (username can be anything). Leave empty if it sits behind Authelia.
      APP_PASSWORD: ""
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8450/health')"]
      interval: 60s
      timeout: 5s

volumes:
  paydays-data:

configs:
  server:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
