"""J.A.R.V.I.S. core: the brain behind the iPhone app and the Raspberry Pi voice hub.

A small FastAPI service you run on your TrueNAS. It keeps the same simple API the app and hub already use
(`POST /api/chat` with {"message": "...", "session_id": "..."} -> {"reply": "..."}, plus `GET /health`), so
nothing else has to change. What's new is inside:

  * A proper cloud LLM brain (OpenAI, Anthropic/Claude or OpenRouter - anything with an OpenAI-compatible
    /chat/completions endpoint). Set LLM_BASE_URL, LLM_API_KEY and LLM_MODEL.
  * Memory that persists in a SQLite file on the NAS:
      - Facts it always knows about you (seed your own, pin the important ones).
      - A knowledge base it searches to answer questions (your notes, manuals, imported exports).
      - Per-conversation history, so follow-ups make sense.
      - Auto-memory: it quietly notes durable new facts from your chats so it understands more over time.

Import tools (see import_memory.py and the endpoints under /api/memory and /api/knowledge) let you load an
export from another AI, a list of personal facts, or documents.
"""

import json
import math
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from typing import List, Optional

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------------------------- config

DATA = os.environ.get("DATA_DIR", "/data")
PORT = int(os.environ.get("PORT", "8998"))

LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.openai.com/v1").rstrip("/")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-4o-mini")
# Empty = let the model use its default. Current Claude models (Haiku 5.5 etc.) return a 400 if you send a
# non-default temperature, so leave this empty for them; set it (e.g. "0.7") only for providers like OpenAI.
LLM_TEMPERATURE = os.environ.get("LLM_TEMPERATURE", "").strip()
LLM_MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "800"))

# Embeddings are optional. With an OpenAI-compatible embeddings model the knowledge search is semantic;
# without one it falls back to a good keyword (TF-IDF) search that needs nothing extra.
EMBED_BASE_URL = os.environ.get("EMBED_BASE_URL", LLM_BASE_URL).rstrip("/")
EMBED_API_KEY = os.environ.get("EMBED_API_KEY", LLM_API_KEY)
EMBED_MODEL = os.environ.get("EMBED_MODEL", "").strip()  # e.g. text-embedding-3-small; "" = keyword search

MAX_HISTORY = int(os.environ.get("MAX_HISTORY", "20"))          # chat turns kept in context
FACT_LIMIT = int(os.environ.get("FACT_LIMIT", "40"))            # retrieved facts injected per reply
KB_LIMIT = int(os.environ.get("KB_LIMIT", "6"))                 # knowledge chunks injected per reply
AUTO_MEMORY = os.environ.get("AUTO_MEMORY", "true").lower() in ("1", "true", "yes")
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "").strip()           # optional: require Authorization: Bearer <token>

# Homelab skills: Jarvis answers "is the NAS okay?" / "any camera events?" from live data when these are set.
TRUENAS_URL = os.environ.get("TRUENAS_URL", "").rstrip("/")
TRUENAS_API_KEY = os.environ.get("TRUENAS_API_KEY", "").strip()
FRIGATE_URL = os.environ.get("FRIGATE_URL", "").rstrip("/")
FRIGATE_USER = os.environ.get("FRIGATE_USER", "").strip()
FRIGATE_PASS = os.environ.get("FRIGATE_PASS", "")

# Chat relay notifications: when set, a new Nocturne message also fires an ntfy push (tapping it deep-links
# into the app). Empty NTFY_SERVER = disabled (unchanged behaviour).
NTFY_SERVER = os.environ.get("NTFY_SERVER", "").rstrip("/")        # e.g. https://ntfy.nas-server.co.uk
NTFY_TOPIC_PREFIX = os.environ.get("NTFY_TOPIC_PREFIX", "nocturne").strip() or "nocturne"
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "").strip()

# Video-call ICE servers for the /call page. STUN is free/public; add your homelab coturn for reliability.
TURN_URL = os.environ.get("TURN_URL", "").strip()                 # e.g. turn:turn.nas-server.co.uk:3478
TURN_USER = os.environ.get("TURN_USER", "").strip()
TURN_PASS = os.environ.get("TURN_PASS", "").strip()

# Native Apple push (APNs) for Nocturne. Needs an EXPLICIT App ID (com.ross.nocturne) with Push enabled,
# a .p8 auth key from the Apple Developer portal, and the signer resigning with that push profile.
APNS_KEY_P8 = os.environ.get("APNS_KEY_P8", "")                   # the .p8 file contents (PEM); or set APNS_KEY_FILE
APNS_KEY_FILE = os.environ.get("APNS_KEY_FILE", "").strip()
APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "").strip()          # the Key ID of the .p8 (Apple Developer -> Keys)
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "G42YL9QS8W").strip()
APNS_BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "com.ross.nocturne").strip()
APNS_ENV = os.environ.get("APNS_ENV", "auto").strip().lower()    # auto | production | sandbox

USER_AGENT = "JarvisCore/1.0"

DEFAULT_PERSONA = (
    "You are J.A.R.V.I.S., a personal AI assistant for your user (think Tony Stark's assistant): calm, quick, "
    "and quietly witty, with a dry British politeness. You are helpful first and never pompous. "
    "You run in your user's own home, often answered out loud through a speaker, so keep replies short and "
    "natural - usually one to three sentences - and skip markdown, lists and headings unless asked. "
    "Use what you remember about the user and their home to be genuinely useful, and if you don't know "
    "something, say so plainly rather than inventing it."
)
PERSONA = os.environ.get("PERSONA", DEFAULT_PERSONA)


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


# ---------------------------------------------------------------------------------------------- storage

os.makedirs(DATA, exist_ok=True)
DB_PATH = os.path.join(DATA, "jarvis.db")
db_lock = threading.Lock()
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.row_factory = sqlite3.Row


def init_db():
    with db_lock:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                norm TEXT NOT NULL,
                source TEXT DEFAULT 'manual',
                pinned INTEGER DEFAULT 0,
                created REAL,
                embedding BLOB,
                scope TEXT DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS kb_docs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT,
                source TEXT DEFAULT 'manual',
                created REAL,
                scope TEXT DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS kb_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_id INTEGER,
                text TEXT NOT NULL,
                created REAL,
                embedding BLOB
            );
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session TEXT,
                role TEXT,
                content TEXT,
                ts REAL
            );
            CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session, id);
            CREATE TABLE IF NOT EXISTS relay_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                room TEXT NOT NULL,
                sender TEXT NOT NULL,
                text TEXT NOT NULL,
                ts REAL
            );
            CREATE INDEX IF NOT EXISTS idx_relay_room ON relay_messages(room, id);
            CREATE TABLE IF NOT EXISTS push_tokens (
                token TEXT PRIMARY KEY,
                room TEXT,
                name TEXT,
                ts REAL
            );
            CREATE INDEX IF NOT EXISTS idx_push_room ON push_tokens(room);
            """
        )
        # Migrate older databases to add the memory-scope column (one per character).
        for statement in ("ALTER TABLE facts ADD COLUMN scope TEXT DEFAULT ''",
                          "ALTER TABLE kb_docs ADD COLUMN scope TEXT DEFAULT ''"):
            try:
                db.execute(statement)
            except sqlite3.OperationalError:
                pass   # column already exists
        # Fact uniqueness is per (norm, scope) so each character can keep its own copy of a fact.
        db.execute("DROP INDEX IF EXISTS idx_facts_norm")
        db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_facts_norm_scope ON facts(norm, scope)")
        db.commit()


init_db()


def normalise(text):
    return re.sub(r"\s+", " ", re.sub(r"[^\w ]", "", (text or "").lower())).strip()


def pack_vec(vec):
    return json.dumps([round(float(x), 6) for x in vec]).encode() if vec else None

def unpack_vec(blob):
    try:
        return json.loads(blob) if blob else None
    except Exception:
        return None


# ---------------------------------------------------------------------------------------------- the LLM

def _post_json(url, payload, api_key, timeout=120):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")[:600]
        raise RuntimeError("HTTP %s from the LLM provider: %s" % (error.code, body))


def llm_chat(messages, max_tokens=None, timeout=120):
    """One call to the chat model. OpenAI-compatible, so OpenAI, Anthropic and OpenRouter all work."""
    if not LLM_API_KEY:
        raise RuntimeError("no LLM_API_KEY set")
    payload = {
        "model": LLM_MODEL,
        "messages": messages,
        "max_tokens": LLM_MAX_TOKENS if max_tokens is None else max_tokens,
    }
    # Only send temperature when explicitly configured - current Claude models 400 on a non-default value.
    if LLM_TEMPERATURE:
        try:
            payload["temperature"] = float(LLM_TEMPERATURE)
        except ValueError:
            pass
    reply = _post_json(LLM_BASE_URL + "/chat/completions", payload, LLM_API_KEY, timeout)
    choices = reply.get("choices") or [{}]
    return (choices[0].get("message") or {}).get("content", "").strip()


def embed(texts):
    """Vectors for the given texts, or None for each if embeddings aren't configured/available."""
    if not EMBED_MODEL or not texts:
        return [None] * len(texts)
    try:
        reply = _post_json(EMBED_BASE_URL + "/embeddings", {"model": EMBED_MODEL, "input": texts}, EMBED_API_KEY, 60)
        return [item.get("embedding") for item in reply.get("data", [])] or [None] * len(texts)
    except Exception as error:
        log("Embeddings unavailable, using keyword search: %s" % error)
        return [None] * len(texts)


# ---------------------------------------------------------------------------------------------- retrieval

TOKEN = re.compile(r"[a-z0-9']+")

def _toks(text):
    return TOKEN.findall((text or "").lower())


def _cosine(a, b):
    if not a or not b:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def rank(query, rows, top_k):
    """Ranks rows (each a dict with 'text' and maybe 'embedding') against the query. Semantic if embeddings
    are present, otherwise a TF-IDF keyword score. Returns the best `top_k` rows."""
    rows = list(rows)
    if not rows:
        return []
    query_vec = embed([query])[0] if EMBED_MODEL else None
    if query_vec is not None and all(r.get("embedding") for r in rows):
        scored = [(_cosine(query_vec, r["embedding"]), r) for r in rows]
    else:
        terms = _toks(query)
        if not terms:
            return rows[:top_k]
        docs = [_toks(r["text"]) for r in rows]
        n = len(docs)
        df = {}
        for doc in docs:
            for word in set(doc):
                df[word] = df.get(word, 0) + 1
        idf = {w: math.log(1 + n / (1 + df.get(w, 0))) for w in set(terms)}
        scored = []
        for row, doc in zip(rows, docs):
            if not doc:
                continue
            counts = {}
            for word in doc:
                counts[word] = counts.get(word, 0) + 1
            score = sum((counts.get(w, 0) / len(doc)) * idf.get(w, 0) for w in set(terms))
            scored.append((score, row))
    scored = [pair for pair in scored if pair[0] > 0]
    scored.sort(key=lambda pair: pair[0], reverse=True)
    return [row for _, row in scored[:top_k]]


# ---------------------------------------------------------------------------------------------- memory store

def add_fact(text, source="manual", pinned=False, scope=""):
    text = (text or "").strip()
    if not text:
        return None
    norm = normalise(text)
    vec = embed([text])[0] if EMBED_MODEL else None
    with db_lock:
        try:
            cur = db.execute(
                "INSERT INTO facts (text, norm, source, pinned, created, embedding, scope) VALUES (?,?,?,?,?,?,?)",
                (text, norm, source, 1 if pinned else 0, time.time(), pack_vec(vec), scope),
            )
            db.commit()
            return cur.lastrowid
        except sqlite3.IntegrityError:
            if pinned:   # a fact we already knew is now worth pinning
                db.execute("UPDATE facts SET pinned=1 WHERE norm=? AND scope=?", (norm, scope))
                db.commit()
            return None


def all_facts(scope=""):
    with db_lock:
        rows = db.execute("SELECT id, text, source, pinned, embedding FROM facts WHERE scope=? "
                          "ORDER BY pinned DESC, id DESC", (scope,)).fetchall()
    out = []
    for r in rows:
        out.append({"id": r["id"], "text": r["text"], "source": r["source"],
                    "pinned": bool(r["pinned"]), "embedding": unpack_vec(r["embedding"])})
    return out


def delete_fact(fact_id):
    with db_lock:
        db.execute("DELETE FROM facts WHERE id=?", (fact_id,))
        db.commit()


def chunk_text(text, size=900, overlap=150):
    """Splits a document into overlapping chunks on paragraph/sentence boundaries."""
    text = re.sub(r"\n{3,}", "\n\n", (text or "").strip())
    if not text:
        return []
    paras = re.split(r"\n\s*\n", text)
    chunks, current = [], ""
    for para in paras:
        para = para.strip()
        if not para:
            continue
        if len(current) + len(para) + 2 <= size:
            current = (current + "\n\n" + para).strip()
        else:
            if current:
                chunks.append(current)
            if len(para) <= size:
                current = para
            else:
                # Very long paragraph: split by sentences.
                current = ""
                for sentence in re.split(r"(?<=[.!?])\s+", para):
                    if len(current) + len(sentence) + 1 <= size:
                        current = (current + " " + sentence).strip()
                    else:
                        if current:
                            chunks.append(current)
                        current = sentence
    if current:
        chunks.append(current)
    # Add a little overlap so facts split across a boundary are still findable.
    if overlap > 0 and len(chunks) > 1:
        overlapped = [chunks[0]]
        for i in range(1, len(chunks)):
            tail = chunks[i - 1][-overlap:]
            overlapped.append((tail + " " + chunks[i]).strip())
        chunks = overlapped
    return chunks


def add_document(title, text, source="manual", scope=""):
    chunks = chunk_text(text)
    if not chunks:
        return 0, 0
    vectors = embed(chunks) if EMBED_MODEL else [None] * len(chunks)
    with db_lock:
        cur = db.execute("INSERT INTO kb_docs (title, source, created, scope) VALUES (?,?,?,?)",
                         (title or "Untitled", source, time.time(), scope))
        doc_id = cur.lastrowid
        for chunk, vec in zip(chunks, vectors):
            db.execute("INSERT INTO kb_chunks (doc_id, text, created, embedding) VALUES (?,?,?,?)",
                       (doc_id, chunk, time.time(), pack_vec(vec)))
        db.commit()
    return doc_id, len(chunks)


def all_chunks(scope=""):
    with db_lock:
        rows = db.execute("SELECT c.id, c.text, c.embedding, d.title FROM kb_chunks c "
                          "JOIN kb_docs d ON d.id = c.doc_id WHERE d.scope=?", (scope,)).fetchall()
    return [{"id": r["id"], "text": r["text"], "title": r["title"], "embedding": unpack_vec(r["embedding"])} for r in rows]


def save_message(session, role, content):
    with db_lock:
        db.execute("INSERT INTO messages (session, role, content, ts) VALUES (?,?,?,?)",
                   (session, role, content, time.time()))
        db.commit()


def recent_history(session, limit):
    with db_lock:
        rows = db.execute("SELECT role, content FROM messages WHERE session=? ORDER BY id DESC LIMIT ?",
                          (session, limit)).fetchall()
    return [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]


# ---------------------------------------------------------------------------------------------- building a reply

# ---------------------------------------------------------------------------------------------- homelab skills
# When the user asks about the NAS or the cameras, fetch live status and hand it to the model so it answers
# naturally and accurately. Both the iPhone app and the Raspberry Pi get this, since both talk to this core.

TRUENAS_WORDS = re.compile(
    r"\b(nas|truenas|server|pool|pools|disk|disks|storage|apps?|docker|jellyfin|navidrome|immich|plex|"
    r"container|containers|uptime|degraded|healthy|everything (ok|okay|alright|running|fine))\b", re.I)
CAMERA_WORDS = re.compile(
    r"\b(camera|cameras|cctv|frigate|events?|motion|detections?|driveway|front ?door|"
    r"who.?s (at|there|about)|anyone (there|about|around)|intruder|doorbell)\b", re.I)


def _uptime(seconds):
    try:
        total = int(seconds or 0)
    except Exception:
        return "a while"
    days, total = divmod(total, 86400)
    hours, total = divmod(total, 3600)
    minutes = total // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, minutes)
    return "%dm" % minutes


def _truenas_get(path):
    request = urllib.request.Request(TRUENAS_URL + "/api/v2.0" + path,
                                     headers={"Authorization": "Bearer " + TRUENAS_API_KEY, "User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.loads(response.read() or b"null")


def truenas_summary():
    if not (TRUENAS_URL and TRUENAS_API_KEY):
        return None
    try:
        info = _truenas_get("/system/info") or {}
        pools = _truenas_get("/pool") or []
        apps = _truenas_get("/app") or []
        alerts = [a for a in (_truenas_get("/alert/list") or []) if not a.get("dismissed")]
    except Exception as error:
        return "the NAS didn't answer (%s)" % error
    bad_pools = [p.get("name") for p in pools
                 if (p.get("status") or "").upper() != "ONLINE" or p.get("healthy") is False]
    running = [a for a in apps if (a.get("state") or "").upper() == "RUNNING"]
    stopped = [a.get("name") for a in apps if (a.get("state") or "").upper() not in ("RUNNING", "DEPLOYING")]
    parts = ["host %s, up %s" % (info.get("hostname", "nas"), _uptime(info.get("uptime_seconds")))]
    parts.append("pools all healthy" if not bad_pools else "POOL PROBLEM: " + ", ".join(p for p in bad_pools if p))
    parts.append("%d of %d apps running%s" % (len(running), len(apps),
                 "" if not stopped else " (stopped: " + ", ".join(s for s in stopped[:8] if s) + ")"))
    if alerts:
        parts.append("%d active alert%s, e.g. %s" % (len(alerts), "" if len(alerts) == 1 else "s",
                     (alerts[0].get("formatted") or "")[:160]))
    else:
        parts.append("no active alerts")
    return "; ".join(parts) + "."


_frigate_cookie = {"value": None}


def _frigate_login():
    body = json.dumps({"user": FRIGATE_USER, "password": FRIGATE_PASS}).encode()
    request = urllib.request.Request(FRIGATE_URL + "/api/login", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=12) as response:
        for header, value in response.getheaders():
            if header.lower() == "set-cookie" and value.startswith("frigate_token="):
                _frigate_cookie["value"] = value.split(";", 1)[0]


def _frigate_get(path, retry=True):
    headers = {"User-Agent": USER_AGENT}
    if _frigate_cookie["value"]:
        headers["Cookie"] = _frigate_cookie["value"]
    try:
        with urllib.request.urlopen(urllib.request.Request(FRIGATE_URL + path, headers=headers), timeout=12) as response:
            return json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        if error.code in (401, 403) and retry and FRIGATE_USER:
            _frigate_login()
            return _frigate_get(path, retry=False)
        raise


def frigate_summary():
    if not FRIGATE_URL:
        return None
    try:
        events = _frigate_get("/api/events?limit=6&include_thumbnails=0") or []
    except Exception as error:
        return "the cameras didn't answer (%s)" % error
    if not events:
        return "no camera events recently."
    now = time.time()
    told = []
    for event in events[:6]:
        label = event.get("label", "something")
        camera = (event.get("camera") or "a camera").replace("_", " ")
        minutes = max(0, int((now - (event.get("start_time") or now)) / 60))
        when = "just now" if minutes == 0 else ("%d min ago" % minutes if minutes < 60 else "%dh ago" % (minutes // 60))
        told.append("%s on %s %s" % (label, camera, when))
    return "; ".join(told) + "."


def homelab_context(message):
    """When the message is about the NAS or cameras, fetch live status to hand to the model. Else None."""
    blocks = []
    if TRUENAS_URL and TRUENAS_API_KEY and TRUENAS_WORDS.search(message):
        summary = truenas_summary()
        if summary:
            blocks.append("NAS: " + summary)
    if FRIGATE_URL and CAMERA_WORDS.search(message):
        summary = frigate_summary()
        if summary:
            blocks.append("Cameras: " + summary)
    if not blocks:
        return None
    return "Live status of the user's home systems right now (use it to answer; it is current):\n" + "\n".join(blocks)


def build_system_prompt(message, persona="", scope=""):
    # A character (Kith companion) sends its own persona; otherwise use the default assistant persona.
    parts = [persona.strip() if persona and persona.strip() else PERSONA]
    facts = all_facts(scope)
    pinned = [f for f in facts if f["pinned"]]
    others = [f for f in facts if not f["pinned"]]
    chosen = pinned + rank(message, others, max(0, FACT_LIMIT - len(pinned)))
    if chosen:
        parts.append("What you know about the person you're talking to:\n"
                     + "\n".join("- " + f["text"] for f in chosen))
    chunks = rank(message, all_chunks(scope), KB_LIMIT)
    if chunks:
        notes = "\n\n".join(("[%s]\n%s" % (c["title"], c["text"])) if c["title"] else c["text"] for c in chunks)
        parts.append("Relevant notes from your knowledge base (use if helpful, otherwise ignore):\n" + notes)
    # Homelab answers are only for the default assistant, not for companion characters.
    if not persona:
        live = homelab_context(message)
        if live:
            parts.append(live)
    return "\n\n".join(parts)


def generate_reply(message, session, persona="", scope=""):
    system = build_system_prompt(message, persona=persona, scope=scope)
    history = recent_history(session, MAX_HISTORY)
    messages = [{"role": "system", "content": system}] + history + [{"role": "user", "content": message}]
    reply = llm_chat(messages)
    save_message(session, "user", message)
    save_message(session, "assistant", reply)
    if AUTO_MEMORY:
        threading.Thread(target=learn_from_exchange, args=(message, reply, scope), daemon=True).start()
    return reply


MEMORY_PROMPT = (
    "From the exchange below, extract any NEW, durable facts about the user or their home worth remembering "
    "long term (names, preferences, relationships, devices, routines, important dates). One short fact per line, "
    "no bullets or numbering. Ignore anything temporary, trivial or already obvious. If there is nothing worth "
    "saving, reply with exactly: NONE"
)

def learn_from_exchange(user_message, assistant_reply, scope=""):
    try:
        prompt = "%s\n\nUser: %s\nAssistant: %s" % (MEMORY_PROMPT, user_message, assistant_reply)
        result = llm_chat([{"role": "user", "content": prompt}], max_tokens=200, timeout=60)
        if not result or result.strip().upper().startswith("NONE"):
            return
        for line in result.splitlines():
            fact = re.sub(r"^[-*\d.)\s]+", "", line).strip()
            if len(fact) > 3:
                if add_fact(fact, source="auto", scope=scope):
                    log("Remembered%s: %s" % ((" [%s]" % scope) if scope else "", fact))
    except Exception as error:
        log("Auto-memory skipped: %s" % error)


# ---------------------------------------------------------------------------------------------- HTTP API

app = FastAPI(title="J.A.R.V.I.S. Core", version="1.0.0",
              description="Personal assistant core with memory. POST /api/chat to talk to Jarvis.")


def check_auth(request: Request):
    if not AUTH_TOKEN:
        return
    header = request.headers.get("authorization", "")
    if header != "Bearer " + AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")


class ChatIn(BaseModel):
    message: str
    session_id: Optional[str] = "default"
    # Companion characters (the Kith app) send their own persona + a memory scope; omit for the default assistant.
    persona: Optional[str] = ""
    scope: Optional[str] = ""

class ChatOut(BaseModel):
    reply: str
    audio_url: Optional[str] = None

class FactIn(BaseModel):
    text: str
    pinned: Optional[bool] = False

class KnowledgeIn(BaseModel):
    title: Optional[str] = "Untitled"
    text: str

class ImportIn(BaseModel):
    title: Optional[str] = "Imported"
    text: str
    kind: Optional[str] = "auto"   # "facts" | "knowledge" | "auto"

class DistillIn(BaseModel):
    text: str
    max_windows: Optional[int] = 20   # cap LLM calls (and cost) when distilling a big export


@app.get("/health")
def health():
    configured = bool(LLM_API_KEY)
    with db_lock:
        facts = db.execute("SELECT COUNT(*) AS n FROM facts").fetchone()["n"]
        chunks = db.execute("SELECT COUNT(*) AS n FROM kb_chunks").fetchone()["n"]
    return {"status": "ok", "model": LLM_MODEL, "configured": configured,
            "facts": facts, "knowledge_chunks": chunks, "embeddings": bool(EMBED_MODEL)}


@app.post("/api/chat", response_model=ChatOut)
def chat(body: ChatIn, request: Request):
    check_auth(request)
    message = (body.message or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="Empty message")
    session = body.session_id or "default"
    try:
        reply = generate_reply(message, session, persona=body.persona or "", scope=body.scope or "")
    except Exception as error:
        log("Chat error: %s" % error)
        if not LLM_API_KEY:
            return ChatOut(reply="My brain isn't connected yet - set LLM_API_KEY and LLM_MODEL on the Jarvis core.")
        return ChatOut(reply="I'm having trouble thinking at the moment. Please try again in a moment.")
    return ChatOut(reply=reply)


class RelayIn(BaseModel):
    room: Optional[str] = "home"
    sender: Optional[str] = "Someone"
    text: str


class SeenIn(BaseModel):
    room: Optional[str] = "home"
    who: Optional[str] = "Someone"


# Last-seen per (room, who) for a light presence indicator. In-memory; resets on restart.
PRESENCE = {}


def _ascii_header(value):
    """ntfy header values must be ASCII; keep it readable."""
    return (value or "").encode("ascii", "replace").decode("ascii")


def _ntfy_topic(room):
    safe = re.sub(r"[^A-Za-z0-9_-]", "", room or "")[:48] or "room"
    return "%s-%s" % (NTFY_TOPIC_PREFIX, safe)


def _ntfy_post(room, title, body, click, tags, priority=None):
    if not NTFY_SERVER:
        return
    try:
        headers = {
            "Title": _ascii_header(title)[:100] or "Nocturne",
            "Tags": tags,
            "Click": click,
            "User-Agent": USER_AGENT,
        }
        if priority:
            headers["Priority"] = priority
        if NTFY_TOKEN:
            headers["Authorization"] = "Bearer " + NTFY_TOKEN
        req = urllib.request.Request("%s/%s" % (NTFY_SERVER, _ntfy_topic(room)),
                                     data=(body or "")[:300].encode("utf-8"), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=8) as response:
            response.read()
    except Exception as error:
        log("ntfy post failed: %s" % error)


def notify_ntfy(room, sender, text):
    """Fire-and-forget ntfy push for a new chat message. No-op unless NTFY_SERVER is set."""
    _ntfy_post(room, sender, text, "nocturne://chat/%s" % urllib.parse.quote(room or "home"), "speech_balloon")


def notify_ntfy_call(room, caller):
    """Ring the other device: a high-priority ntfy whose tap opens the in-app call."""
    _ntfy_post(room, "%s is calling" % (caller or "Someone"), "Incoming video call",
               "nocturne://call/%s" % urllib.parse.quote(room or "home"), "telephone_receiver", priority="max")


# ---------------------------------------------------------------------------------- native push (APNs)

_apns_jwt = {"token": "", "iat": 0}


def _apns_key_pem():
    if APNS_KEY_P8.strip():
        return APNS_KEY_P8.replace("\\n", "\n")
    if APNS_KEY_FILE and os.path.exists(APNS_KEY_FILE):
        try:
            with open(APNS_KEY_FILE) as handle:
                return handle.read()
        except Exception as error:
            log("APNs key file unreadable: %s" % error)
    return ""


def apns_configured():
    return bool(_apns_key_pem() and APNS_KEY_ID)


def _apns_bearer():
    """A cached ES256 JWT for APNs token auth (valid ~1h; Apple wants it refreshed < 60 min)."""
    if not apns_configured():
        return ""
    now = int(time.time())
    if _apns_jwt["token"] and now - _apns_jwt["iat"] < 2400:
        return _apns_jwt["token"]
    try:
        import jwt  # PyJWT (with cryptography for ES256)
        token = jwt.encode({"iss": APNS_TEAM_ID, "iat": now}, _apns_key_pem(),
                           algorithm="ES256", headers={"kid": APNS_KEY_ID})
        if isinstance(token, bytes):
            token = token.decode("ascii")
        _apns_jwt.update(token=token, iat=now)
        return token
    except Exception as error:
        log("APNs JWT failed: %s" % error)
        return ""


def _apns_hosts():
    if APNS_ENV == "production":
        return ["https://api.push.apple.com"]
    if APNS_ENV == "sandbox":
        return ["https://api.sandbox.push.apple.com"]
    return ["https://api.push.apple.com", "https://api.sandbox.push.apple.com"]  # auto: try both


def apns_push(device_token, title, body, url=None):
    """Send one alert push. Deletes the token if Apple says it's gone (410). No-op unless configured."""
    bearer = _apns_bearer()
    if not bearer:
        return False
    try:
        import httpx
    except Exception as error:
        log("httpx missing for APNs: %s" % error)
        return False
    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}}
    if url:
        payload["url"] = url
    headers = {"authorization": "bearer " + bearer, "apns-topic": APNS_BUNDLE_ID,
               "apns-push-type": "alert", "apns-priority": "10"}
    hosts = _apns_hosts()
    for index, host in enumerate(hosts):
        try:
            with httpx.Client(http2=True, timeout=10) as client:
                response = client.post(host + "/3/device/" + device_token, headers=headers, json=payload)
            if response.status_code == 200:
                return True
            reason = ""
            try:
                reason = response.json().get("reason", "")
            except Exception:
                reason = response.text[:120]
            if response.status_code == 410 or reason == "Unregistered":
                _delete_push_token(device_token)
                return False
            if reason == "BadDeviceToken" and index < len(hosts) - 1:
                continue   # wrong environment — try the other APNs host
            log("APNs %s... -> %s %s" % (device_token[:8], response.status_code, reason))
            return False
        except Exception as error:
            log("APNs send error: %s" % error)
    return False


def _delete_push_token(token):
    with db_lock:
        db.execute("DELETE FROM push_tokens WHERE token = ?", (token,))
        db.commit()


def push_to_room(room, exclude_name, title, body, url=None):
    """Push to everyone registered in the room except the sender."""
    if not apns_configured():
        return
    with db_lock:
        rows = db.execute("SELECT token, name FROM push_tokens WHERE room = ?", (room,)).fetchall()
    for row in rows:
        if row["name"] != exclude_name:
            apns_push(row["token"], title, body, url)


@app.post("/api/relay/send")
def relay_send(body: RelayIn, request: Request):
    """Self-hosted chat relay for the Nocturne Messages app (not iMessage/SMS)."""
    check_auth(request)
    text = (body.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Empty message")
    room = (body.room or "home")[:64]
    sender = (body.sender or "Someone")[:64]
    now = time.time()
    with db_lock:
        cur = db.execute("INSERT INTO relay_messages (room, sender, text, ts) VALUES (?, ?, ?, ?)",
                         (room, sender, text[:4000], now))
        db.commit()
        mid = cur.lastrowid
    # Notify the other device without blocking the sender's request: native APNs push (+ ntfy if configured).
    deeplink = "nocturne://chat/%s" % urllib.parse.quote(room)
    threading.Thread(target=push_to_room, args=(room, sender, sender, text[:200], deeplink), daemon=True).start()
    threading.Thread(target=notify_ntfy, args=(room, sender, text), daemon=True).start()
    return {"id": mid, "ts": now}


@app.get("/api/relay/messages")
def relay_messages(request: Request):
    check_auth(request)
    room = request.query_params.get("room", "home")
    try:
        since_id = int(request.query_params.get("since", "0"))
    except ValueError:
        since_id = 0
    with db_lock:
        rows = db.execute(
            "SELECT id, sender, text, ts FROM relay_messages WHERE room = ? AND id > ? ORDER BY id ASC LIMIT 200",
            (room, since_id)).fetchall()
    return [{"id": r["id"], "sender": r["sender"], "text": r["text"], "ts": r["ts"]} for r in rows]


@app.post("/api/relay/seen")
def relay_seen(body: SeenIn, request: Request):
    check_auth(request)
    PRESENCE[((body.room or "home")[:64], (body.who or "Someone")[:64])] = time.time()
    return {"ok": True}


@app.get("/api/relay/presence")
def relay_presence(request: Request):
    check_auth(request)
    room = request.query_params.get("room", "home")
    now = time.time()
    return [{"who": who, "ts": ts, "ago": round(now - ts)}
            for (r, who), ts in PRESENCE.items() if r == room]


class PushReg(BaseModel):
    token: str
    room: Optional[str] = "home"
    name: Optional[str] = "Someone"


@app.post("/api/push/register")
def push_register(body: PushReg, request: Request):
    """Nocturne registers its APNs device token here so the other person's messages can push to it."""
    check_auth(request)
    token = (body.token or "").strip()
    if not token:
        raise HTTPException(status_code=400, detail="Missing token")
    with db_lock:
        db.execute("INSERT OR REPLACE INTO push_tokens (token, room, name, ts) VALUES (?, ?, ?, ?)",
                   (token, (body.room or "home")[:64], (body.name or "Someone")[:64], time.time()))
        db.commit()
    return {"ok": True, "push": apns_configured()}


# ------------------------------------------------------------------------------------ video call (WebRTC)

# Open signalling sockets per call room. Peers in a room relay offer/answer/ICE to each other.
CALL_ROOMS = {}


class RingIn(BaseModel):
    room: Optional[str] = "home"
    caller: Optional[str] = "Someone"


@app.post("/api/call/ring")
def call_ring(body: RingIn, request: Request):
    """Notifies the other person that a video call is starting (ntfy → nocturne://call/<room>)."""
    check_auth(request)
    room = (body.room or "home")[:64]
    caller = (body.caller or "Someone")[:64]
    deeplink = "nocturne://call/%s" % urllib.parse.quote(room)
    threading.Thread(target=push_to_room,
                     args=(room, caller, "%s is calling" % caller, "Incoming video call", deeplink), daemon=True).start()
    threading.Thread(target=notify_ntfy_call, args=(room, caller), daemon=True).start()
    return {"ok": True}


@app.get("/call/config")
def call_config():
    """ICE servers for the call page: public STUN plus the homelab TURN if configured."""
    ice = [{"urls": "stun:stun.l.google.com:19302"}]
    if TURN_URL:
        ice.append({"urls": TURN_URL, "username": TURN_USER, "credential": TURN_PASS})
    return {"iceServers": ice}


@app.websocket("/api/call/ws")
async def call_ws(ws: WebSocket):
    """Relays WebRTC signalling text frames to the other peer(s) in the same call room."""
    room = ws.query_params.get("room", "")
    token = ws.query_params.get("token", "")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        await ws.close(code=1008)
        return
    if not room:
        await ws.close(code=1008)
        return
    await ws.accept()
    peers = CALL_ROOMS.setdefault(room, set())
    peers.add(ws)
    try:
        while True:
            message = await ws.receive_text()
            for peer in list(peers):
                if peer is not ws:
                    try:
                        await peer.send_text(message)
                    except Exception:
                        pass
    except WebSocketDisconnect:
        pass
    except Exception as error:
        log("call ws error: %s" % error)
    finally:
        peers.discard(ws)
        if not peers:
            CALL_ROOMS.pop(room, None)


@app.get("/call")
def call_page():
    return HTMLResponse(CALL_HTML)


CALL_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Nocturne Call</title>
<style>
  :root { --bg:#0b0608; --panel:#1c1116; --accent:#b01030; --accent2:#e04050; --text:#ede3e6; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--text);
    font-family:-apple-system,Segoe UI,Roboto,serif; overflow:hidden; }
  #stage { position:fixed; inset:0; }
  video { position:absolute; object-fit:cover; background:#000; }
  #remote { inset:0; width:100%; height:100%; }
  #local { width:30vw; max-width:160px; aspect-ratio:3/4; right:14px; top:14px; border-radius:14px;
    border:1px solid rgba(224,64,80,.5); box-shadow:0 6px 20px rgba(0,0,0,.6); z-index:2; }
  #status { position:absolute; top:16px; left:16px; z-index:3; font-size:14px; letter-spacing:1px;
    background:rgba(0,0,0,.45); padding:6px 12px; border-radius:20px; }
  #bar { position:absolute; left:0; right:0; bottom:calc(24px + env(safe-area-inset-bottom)); z-index:3;
    display:flex; gap:18px; justify-content:center; }
  button { width:62px; height:62px; border-radius:50%; border:1px solid rgba(255,255,255,.15);
    background:var(--panel); color:var(--text); font-size:22px; cursor:pointer; }
  button.end { background:var(--accent); border-color:transparent; }
  button.off { background:#333; }
  #title { position:absolute; bottom:calc(104px + env(safe-area-inset-bottom)); left:0; right:0; z-index:3;
    text-align:center; font-family:Georgia,serif; font-size:20px; text-shadow:0 1px 6px #000; }
</style>
</head>
<body>
<div id="stage">
  <video id="remote" autoplay playsinline></video>
  <video id="local" autoplay playsinline muted></video>
  <div id="status">Starting…</div>
  <div id="title"></div>
  <div id="bar">
    <button id="mic" title="Mute">&#127908;</button>
    <button id="cam" title="Camera">&#128247;</button>
    <button id="end" class="end" title="Hang up">&#128222;</button>
  </div>
</div>
<script>
const p = new URLSearchParams(location.search);
const room = p.get('room') || 'room';
const myName = p.get('name') || 'Me';
const token = p.get('token') || '';
const myId = Math.random();
const S = document.getElementById('status');
document.getElementById('title').textContent = p.get('with') || '';
const localV = document.getElementById('local'), remoteV = document.getElementById('remote');
let pc, ws, localStream, polite=false, otherSeen=false, started=false, makingOffer=false, ignoreOffer=false;

function setStatus(t){ S.textContent = t; }
function sig(o){ if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); }

async function begin(){
  let cfg = {iceServers:[{urls:'stun:stun.l.google.com:19302'}]};
  try { cfg = await (await fetch('/call/config')).json(); } catch(e){}
  try {
    localStream = await navigator.mediaDevices.getUserMedia({ video:true, audio:true });
  } catch(e){ setStatus('Allow camera & microphone to call'); return; }
  localV.srcObject = localStream;
  pc = new RTCPeerConnection(cfg);
  pc.ontrack = (e)=>{ remoteV.srcObject = e.streams[0]; setStatus('Connected'); };
  pc.onicecandidate = ({candidate})=>{ if (candidate) sig({candidate}); };
  pc.onnegotiationneeded = async ()=>{
    try { makingOffer=true; await pc.setLocalDescription(); sig({desc: pc.localDescription}); }
    catch(e){ console.error(e); } finally { makingOffer=false; }
  };
  pc.onconnectionstatechange = ()=>{
    if (pc.connectionState==='connected') setStatus('Connected');
    else if (pc.connectionState==='failed') setStatus('Connection failed');
  };
  connect();
}

function connect(){
  const scheme = location.protocol==='https:' ? 'wss' : 'ws';
  ws = new WebSocket(scheme+'://'+location.host+'/api/call/ws?room='+encodeURIComponent(room)+'&token='+encodeURIComponent(token));
  ws.onopen = ()=>{ setStatus('Waiting for the other person…'); sig({hello: myId}); };
  ws.onclose = ()=> setStatus('Call ended');
  ws.onmessage = async (ev)=>{
    const d = JSON.parse(ev.data);
    if (d.hello !== undefined){
      if (!otherSeen){ otherSeen = true; polite = myId < d.hello; sig({hello: myId}); addTracks(); }
      return;
    }
    if (d.bye){ setStatus('They hung up'); return; }
    try {
      if (d.desc){
        const collision = d.desc.type==='offer' && (makingOffer || pc.signalingState!=='stable');
        ignoreOffer = !polite && collision;
        if (ignoreOffer) return;
        await pc.setRemoteDescription(d.desc);
        if (d.desc.type==='offer'){ await pc.setLocalDescription(); sig({desc: pc.localDescription}); }
      } else if (d.candidate){
        try { await pc.addIceCandidate(d.candidate); } catch(e){ if (!ignoreOffer) throw e; }
      }
    } catch(e){ console.error(e); }
  };
}

function addTracks(){
  if (started) return; started = true;
  setStatus('Ringing…');
  localStream.getTracks().forEach(t=> pc.addTrack(t, localStream));
}

document.getElementById('mic').onclick = (e)=>{
  const tr = localStream && localStream.getAudioTracks()[0]; if (!tr) return;
  tr.enabled = !tr.enabled; e.currentTarget.classList.toggle('off', !tr.enabled);
};
document.getElementById('cam').onclick = (e)=>{
  const tr = localStream && localStream.getVideoTracks()[0]; if (!tr) return;
  tr.enabled = !tr.enabled; e.currentTarget.classList.toggle('off', !tr.enabled);
};
document.getElementById('end').onclick = ()=>{
  sig({bye:true});
  if (pc) pc.close();
  if (localStream) localStream.getTracks().forEach(t=> t.stop());
  setStatus('Call ended');
  setTimeout(()=>{ try{ window.close(); }catch(e){} location.href='about:blank'; }, 300);
};

begin();
</script>
</body>
</html>
"""


@app.get("/api/memory/facts")
def list_facts(request: Request):
    check_auth(request)
    scope = request.query_params.get("scope", "")
    return [{"id": f["id"], "text": f["text"], "source": f["source"], "pinned": f["pinned"]} for f in all_facts(scope)]

@app.post("/api/memory/facts")
def create_fact(body: FactIn, request: Request):
    check_auth(request)
    scope = request.query_params.get("scope", "")
    fact_id = add_fact(body.text, source="manual", pinned=bool(body.pinned), scope=scope)
    return {"id": fact_id, "saved": fact_id is not None}

@app.delete("/api/memory/facts/{fact_id}")
def remove_fact(fact_id: int, request: Request):
    check_auth(request)
    delete_fact(fact_id)
    return {"deleted": True}

class PinIn(BaseModel):
    pinned: bool = True

@app.post("/api/memory/facts/{fact_id}/pin")
def set_fact_pin(fact_id: int, body: PinIn, request: Request):
    check_auth(request)
    with db_lock:
        db.execute("UPDATE facts SET pinned=? WHERE id=?", (1 if body.pinned else 0, fact_id))
        db.commit()
    return {"id": fact_id, "pinned": body.pinned}


@app.get("/api/knowledge")
def list_knowledge(request: Request):
    check_auth(request)
    with db_lock:
        rows = db.execute("SELECT d.id, d.title, d.source, d.created, COUNT(c.id) AS chunks "
                          "FROM kb_docs d LEFT JOIN kb_chunks c ON c.doc_id=d.id GROUP BY d.id ORDER BY d.id DESC").fetchall()
    return [{"id": r["id"], "title": r["title"], "source": r["source"], "chunks": r["chunks"]} for r in rows]

@app.post("/api/knowledge")
def create_knowledge(body: KnowledgeIn, request: Request):
    check_auth(request)
    doc_id, n = add_document(body.title, body.text, source="manual")
    return {"id": doc_id, "chunks": n}

@app.delete("/api/knowledge/{doc_id}")
def remove_knowledge(doc_id: int, request: Request):
    check_auth(request)
    with db_lock:
        db.execute("DELETE FROM kb_chunks WHERE doc_id=?", (doc_id,))
        db.execute("DELETE FROM kb_docs WHERE id=?", (doc_id,))
        db.commit()
    return {"deleted": True}


@app.post("/api/memory/import")
def import_memory(body: ImportIn, request: Request):
    """Bulk import. kind='facts' stores each line as a fact; kind='knowledge' adds a searchable document;
    kind='auto' guesses from the shape of the text."""
    check_auth(request)
    text = body.text or ""
    kind = (body.kind or "auto").lower()
    if kind == "auto":
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        bullets = [l for l in lines if re.match(r"^[-*•]", l)]
        kind = "facts" if lines and (len(bullets) >= len(lines) * 0.5 or len(text) < 1500) else "knowledge"
    if kind == "facts":
        saved = 0
        for line in text.splitlines():
            fact = re.sub(r"^[-*•\d.)\s]+", "", line).strip()
            if len(fact) > 3 and add_fact(fact, source="import"):
                saved += 1
        return {"kind": "facts", "saved": saved}
    doc_id, n = add_document(body.title, text, source="import")
    return {"kind": "knowledge", "doc_id": doc_id, "chunks": n}


@app.post("/api/memory/distill")
def distill(body: DistillIn, request: Request):
    """Reads through imported text with the LLM and saves the durable facts it finds (names, preferences, etc.)."""
    check_auth(request)
    if not LLM_API_KEY:
        raise HTTPException(status_code=400, detail="No LLM configured")
    text = body.text or ""
    window = 4000
    count = min((len(text) + window - 1) // window, max(1, body.max_windows or 20))
    saved = 0
    for i in range(count):
        chunk = text[i * window:(i + 1) * window]
        if not chunk.strip():
            continue
        try:
            result = llm_chat([{"role": "user", "content": MEMORY_PROMPT + "\n\n" + chunk}],
                              max_tokens=300, timeout=60)
        except Exception as error:
            log("Distill window %d failed: %s" % (i, error))
            continue
        if not result or result.strip().upper().startswith("NONE"):
            continue
        for line in result.splitlines():
            fact = re.sub(r"^[-*•\d.)\s]+", "", line).strip()
            if len(fact) > 3 and add_fact(fact, source="distill"):
                saved += 1
    return {"facts_saved": saved, "windows": count}


@app.exception_handler(Exception)
def on_error(request, exc):
    log("Unhandled error: %s" % exc)
    return JSONResponse(status_code=500, content={"reply": "Something went wrong on the Jarvis core."})


if __name__ == "__main__":
    import uvicorn
    log("J.A.R.V.I.S. core starting on port %d (model %s via %s)" % (PORT, LLM_MODEL, LLM_BASE_URL))
    if not LLM_API_KEY:
        log("WARNING: no LLM_API_KEY set - set it (and LLM_MODEL) so Jarvis can think.")
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
