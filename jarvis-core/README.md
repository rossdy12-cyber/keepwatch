# Jarvis core: the brain with memory

The service the Jarvis iPhone app and the Raspberry Pi voice hub talk to. It keeps the **same API** they already
use (`POST /api/chat` → `{"reply": "…"}`, and `GET /health`), so nothing else needs changing — but inside it now
has a real cloud LLM brain **and a memory that persists on your NAS**:

- **Personal facts** it always knows about you and your home (seed your own; pin the important ones).
- **A knowledge base** it searches to answer questions (your notes, manuals, imported exports).
- **Conversation history** per chat, so follow-ups make sense.
- **Auto-memory** — it quietly notes durable new facts from your chats, so it understands more over time.

It replaces the old Ollama core. Your app and Pi keep pointing at the same address.

## 1. Install on TrueNAS

1. **Apps → Discover Apps → ⋮ → Install via YAML.** Name it `jarvis-core` and paste [`compose.yaml`](compose.yaml). Save.
2. **Set your brain.** Apps → jarvis-core → **Edit**, and fill in:
   - `LLM_API_KEY` — your provider's API key.
   - `LLM_BASE_URL` and `LLM_MODEL` — pick a provider:

   | Provider | `LLM_BASE_URL` | `LLM_MODEL` (examples) |
   |---|---|---|
   | OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini`, `gpt-4o` |
   | Anthropic (Claude) | `https://api.anthropic.com/v1` | `claude-haiku-5-5` (cheapest), `claude-sonnet-5-5` |
   | OpenRouter | `https://openrouter.ai/api/v1` | `anthropic/claude-3.5-sonnet`, `meta-llama/llama-3.1-70b-instruct` |

3. First start installs FastAPI (a minute); then it's quick. Check **Logs** for *"J.A.R.V.I.S. core starting"*.
4. It already lives at the address your app/hub use. If you moved servers, make sure Nginx Proxy Manager still
   points `jarvis.nas-server.co.uk` at this app's port **8998** (see the iPhone app's README).

> **Replacing the old core:** point the old Ollama app's proxy host at `8998` instead (or just stop it and give
> this one the same port). The app and hub need no changes.

## 2. Give it a memory

Three kinds of memory, all stored in `/data` on the NAS (so they survive restarts). Use the
[`import_memory.py`](import_memory.py) helper from any computer that can reach the core, or the HTTP API directly.

**Personal facts** — things Jarvis should always know. Put one per line in a text file:

```
Ross's dog is called Nimbus.
The boiler is a Worcester Bosch in the airing cupboard.
Bins go out on Tuesday night.
```
```bash
python3 import_memory.py --url https://jarvis.nas-server.co.uk facts about_me.txt
```

**Documents / knowledge** — manuals, notes, anything Jarvis should be able to look things up in:

```bash
python3 import_memory.py --url https://jarvis.nas-server.co.uk knowledge boiler-manual.txt --title "Boiler"
```

**An export from another AI** — bring over what ChatGPT or Claude already knew about you. Export your data from
that assistant, then:

```bash
# ChatGPT: the conversations.json, or the whole export .zip
python3 import_memory.py --url https://jarvis.nas-server.co.uk chatgpt export.zip --distill

# Claude: conversations.json / data.json
python3 import_memory.py --url https://jarvis.nas-server.co.uk claude conversations.json --distill
```

`--distill` also reads through the export with the LLM and saves the durable facts it finds (names, preferences,
relationships). Without it, the conversations are just added as searchable knowledge.

**Auto-memory** does the rest over time: as you chat, Jarvis notes lasting new facts by itself (turn it off with
`AUTO_MEMORY=false`).

### Managing memory by hand (HTTP)

```bash
curl -s https://jarvis.nas-server.co.uk/api/memory/facts                                   # list facts
curl -s -XPOST https://jarvis.nas-server.co.uk/api/memory/facts -H 'content-type: application/json' \
     -d '{"text":"My car is a blue BMW 1 Series","pinned":true}'                           # add a pinned fact
curl -s -XDELETE https://jarvis.nas-server.co.uk/api/memory/facts/12                        # forget fact 12
curl -s https://jarvis.nas-server.co.uk/api/knowledge                                       # list documents
```

If you set `AUTH_TOKEN`, add `-H "Authorization: Bearer <token>"` to each call (and set the same token in the
app/hub).

## Settings (Apps → jarvis-core → Edit)

| Setting | What it does |
|---|---|
| `LLM_API_KEY` | Your provider's API key. **Required.** |
| `LLM_BASE_URL` / `LLM_MODEL` | Which provider and model (see table above). |
| `LLM_TEMPERATURE` | Leave **empty** for Claude models (they reject a non-default temperature). Set e.g. `0.7` only for OpenAI. |
| `AUTO_MEMORY` | `true` (default): learn durable facts from chats automatically. `false` to stop. |
| `EMBED_MODEL` | Optional embeddings model (e.g. `text-embedding-3-small`) for *semantic* knowledge search. Empty = keyword search, no extra cost. |
| `PERSONA` | Override Jarvis's personality. Empty = the built-in dry-witted butler. |
| `AUTH_TOKEN` | Optional bearer token required on every request. Empty = open on your LAN. |
| `MAX_HISTORY` | How many past turns to keep in context (default 20). |

## How it answers

Each message: Jarvis gathers the facts it has pinned, the facts and knowledge most relevant to what you asked, and
the recent conversation, then asks the model for a short, natural reply. Replies are kept brief because they're
often spoken aloud through the Pi. `compose.yaml` is generated — edit `core.py`, then run `python3 build_compose.py`.
