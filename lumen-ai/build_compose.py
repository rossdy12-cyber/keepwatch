"""Regenerates compose.yaml with upscaler.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "upscaler.py").read_text().replace("$", "$$")
embedded = "".join("      " + line if line.strip() else "\n" for line in script.splitlines(keepends=True))

compose = """# Lumen AI upscaler: Real-ESRGAN on TrueNAS for the Lumen camera app.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it lumen-ai -> paste this file.
# First start installs PyTorch (about 200 MB, once). The Logs then show the address and key for Lumen,
# and the one command that adds your PC's graphics card as a GPU worker.
# Generated from upscaler.py by build_compose.py.
services:
  lumen-ai:
    image: python:3.11-slim
    container_name: lumen-ai
    restart: unless-stopped
    ports:
      - "10702:10702"
    configs:
      - source: upscaler
        target: /app/upscaler.py
    volumes:
      - lumen-ai-data:/data
    environment:
      # Photos bigger than this are scaled down first so a job takes minutes, not hours, on a CPU.
      # Both give roughly a 16-megapixel result. Raise them if your NAS is quick.
      MAX_INPUT_MEGAPIXELS_2X: "4"
      MAX_INPUT_MEGAPIXELS_4X: "1"
      # Limits when your PC's GPU worker is online (it's much faster). A GTX 970 handles these comfortably.
      GPU_MAX_INPUT_MEGAPIXELS_2X: "12"
      GPU_MAX_INPUT_MEGAPIXELS_4X: "4"
      # Processor threads to use (0 = all of them).
      THREADS: "0"
      TZ: Europe/London
    command:
      - sh
      - -c
      - >-
        ([ -f /data/venv/.ready-1 ] || (python -m venv /data/venv
        && /data/venv/bin/pip install -q --no-cache-dir --index-url https://download.pytorch.org/whl/cpu "torch==2.5.1"
        && /data/venv/bin/pip install -q --no-cache-dir numpy pillow
        && touch /data/venv/.ready-1))
        && exec /data/venv/bin/python -u /app/upscaler.py

volumes:
  lumen-ai-data:

configs:
  upscaler:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
