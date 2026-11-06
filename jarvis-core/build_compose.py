"""Regenerates compose.yaml with core.py embedded, so TrueNAS needs just one paste.
Run: python3 build_compose.py"""
from pathlib import Path

here = Path(__file__).parent
script = (here / "core.py").read_text()
# Docker Compose treats "$" as the start of a variable; "$$" is a literal "$".
escaped = script.replace("$", "$$")
embedded = "".join("      " + line if line.strip() else "\n" for line in escaped.splitlines(keepends=True))

compose = """# J.A.R.V.I.S. core: the brain (with memory) behind the Jarvis iPhone app and the Raspberry Pi voice hub.
# TrueNAS: Apps -> Discover Apps -> (three dots) Install via YAML -> name it jarvis-core -> paste this file.
# Then set LLM_API_KEY (and LLM_MODEL) below to your cloud provider's key. First start installs FastAPI; after
# that it's quick. The app and hub already point at this core; nothing else changes. Generated from core.py.
services:
  jarvis-core:
    image: python:3.11-slim
    restart: unless-stopped
    ports:
      - "8998:8998"
    configs:
      - source: core
        target: /app/core.py
    volumes:
      # Jarvis's memory (facts, knowledge base, conversations) lives here, so it survives restarts.
      - jarvis-core-data:/data
    environment:
      # --- The brain: any OpenAI-compatible chat API ---
      # OpenAI:       LLM_BASE_URL=https://api.openai.com/v1          LLM_MODEL=gpt-4o-mini
      # Anthropic:    LLM_BASE_URL=https://api.anthropic.com/v1       LLM_MODEL=claude-haiku-5-5
      # OpenRouter:   LLM_BASE_URL=https://openrouter.ai/api/v1       LLM_MODEL=anthropic/claude-haiku-5.5
      LLM_BASE_URL: https://api.openai.com/v1
      LLM_API_KEY: ""            # <-- put your provider API key here
      LLM_MODEL: gpt-4o-mini
      # Leave empty for Claude models (they reject a non-default temperature). Set e.g. "0.7" for OpenAI.
      LLM_TEMPERATURE: ""
      # --- Memory ---
      # Jarvis notes durable facts from your chats automatically. "false" to turn that off.
      AUTO_MEMORY: "true"
      # Optional: an embeddings model makes the knowledge search semantic instead of keyword-based.
      # e.g. EMBED_MODEL=text-embedding-3-small (OpenAI). Leave empty to use keyword search (no extra cost).
      EMBED_MODEL: ""
      # Optional: require this bearer token on every request (also set it in the app/hub). Empty = open on your LAN.
      AUTH_TOKEN: ""
      # Optional: override Jarvis's personality. Leave empty for the built-in butler persona.
      PERSONA: ""
      TZ: Europe/London
    command:
      - sh
      - -c
      - >-
        ([ -f /data/venv/.ready-1 ] || (python -m venv /data/venv
        && /data/venv/bin/pip install -q --no-cache-dir "fastapi==0.115.6" "uvicorn==0.34.0"
        && touch /data/venv/.ready-1))
        && exec /data/venv/bin/python -u /app/core.py

volumes:
  jarvis-core-data:

configs:
  core:
    content: |
""" + embedded
(here / "compose.yaml").write_text(compose)
print("wrote compose.yaml")
