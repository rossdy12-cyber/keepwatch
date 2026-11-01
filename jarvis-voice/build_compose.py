"""Regenerates compose.yaml with hub.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "hub.py").read_text()
# Docker Compose treats "$" as the start of a variable; "$$" is a literal "$".
escaped = script.replace("$", "$$")
embedded = "".join("      " + line if line.strip() else "\n" for line in escaped.splitlines(keepends=True))

compose = """# Jarvis voice hub: "Hey Jarvis" for a Raspberry Pi speaker, with the listening and speech done on TrueNAS.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it jarvis-voice -> paste this file.
# First start takes a few minutes (installs the speech tools and downloads the models). Then open the app's Logs:
# they show the one command to run on the Pi. Generated from hub.py by build_compose.py.
services:
  jarvis-voice:
    image: python:3.11-slim
    container_name: jarvis-voice
    restart: unless-stopped
    ports:
      - "10700:10700"   # audio from the Pi
      - "10701:10701"   # the Pi's setup script
    configs:
      - source: hub
        target: /app/hub.py
    volumes:
      # The speech tools, models and the Pi's key live here, so restarts are quick.
      - jarvis-voice-data:/data
    environment:
      # Talk to the Jarvis core directly on your network (skips Cloudflare, and is faster).
      JARVIS_URL: http://100.85.127.42:8998
      SESSION_ID: bedroom-pi
      # "base.en" is quick; "small.en" understands more but is slower.
      WHISPER_MODEL: base.en
      # Jarvis's voice when the core doesn't send its own recording: a natural British male voice (Kokoro).
      # Try bm_george (deep, butler-like), bm_fable, bm_lewis or bm_daniel.
      TTS_VOICE: bm_george
      TTS_SPEED: "0.95"
      # "light" adds a subtle AI-assistant sheen; "none" for the plain voice.
      VOICE_EFFECT: light
      USE_CORE_VOICE: "true"
      # Lower = wakes more easily (and more false wakes). 0.5 is a good start.
      WAKE_THRESHOLD: "0.5"
      # Keep listening this many seconds after a reply, so you can carry on without "Hey Jarvis". 0 = off.
      FOLLOW_UP_SECONDS: "0"
      GREETING: Jarvis is listening.
      TZ: Europe/London
    command:
      - sh
      - -c
      - >-
        (command -v ffmpeg >/dev/null || (apt-get update -qq && apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null))
        && ([ -f /data/venv/.ready-2 ] || (python -m venv /data/venv
        && /data/venv/bin/pip install -q --no-cache-dir "openwakeword==0.6.0" "faster-whisper==1.1.1" "piper-tts==1.2.0" "onnxruntime>=1.17,<2" "kokoro-onnx==0.4.9" numpy
        && touch /data/venv/.ready-2))
        && exec /data/venv/bin/python -u /app/hub.py
    environment_file_note: ""

volumes:
  jarvis-voice-data:

configs:
  hub:
    content: |
""" + embedded
compose = compose.replace('    environment_file_note: ""\n', "")
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
