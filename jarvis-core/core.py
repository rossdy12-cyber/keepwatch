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
import urllib.request

from typing import List, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------------------------- config

DATA = os.environ.get("DATA_DIR", "/data")
PORT = int(os.environ.get("PORT", "8998"))

LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.openai.com/v1").rstrip("/")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-4o-mini")
LLM_TEMPERATURE = float(os.environ.get("LLM_TEMPERATURE", "0.6"))
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
                embedding BLOB
            );
            CREATE TABLE IF NOT EXISTS kb_docs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT,
                source TEXT DEFAULT 'manual',
                created REAL
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
            CREATE UNIQUE INDEX IF NOT EXISTS idx_facts_norm ON facts(norm);
            """
        )
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
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read() or b"{}")


def llm_chat(messages, temperature=None, max_tokens=None, timeout=120):
    """One call to the chat model. OpenAI-compatible, so OpenAI, Anthropic and OpenRouter all work."""
    if not LLM_API_KEY:
        raise RuntimeError("no LLM_API_KEY set")
    payload = {
        "model": LLM_MODEL,
        "messages": messages,
        "temperature": LLM_TEMPERATURE if temperature is None else temperature,
        "max_tokens": LLM_MAX_TOKENS if max_tokens is None else max_tokens,
    }
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

def add_fact(text, source="manual", pinned=False):
    text = (text or "").strip()
    if not text:
        return None
    norm = normalise(text)
    vec = embed([text])[0] if EMBED_MODEL else None
    with db_lock:
        try:
            cur = db.execute(
                "INSERT INTO facts (text, norm, source, pinned, created, embedding) VALUES (?,?,?,?,?,?)",
                (text, norm, source, 1 if pinned else 0, time.time(), pack_vec(vec)),
            )
            db.commit()
            return cur.lastrowid
        except sqlite3.IntegrityError:
            if pinned:   # a fact we already knew is now worth pinning
                db.execute("UPDATE facts SET pinned=1 WHERE norm=?", (norm,))
                db.commit()
            return None


def all_facts():
    with db_lock:
        rows = db.execute("SELECT id, text, source, pinned, embedding FROM facts ORDER BY pinned DESC, id DESC").fetchall()
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


def add_document(title, text, source="manual"):
    chunks = chunk_text(text)
    if not chunks:
        return 0, 0
    vectors = embed(chunks) if EMBED_MODEL else [None] * len(chunks)
    with db_lock:
        cur = db.execute("INSERT INTO kb_docs (title, source, created) VALUES (?,?,?)",
                         (title or "Untitled", source, time.time()))
        doc_id = cur.lastrowid
        for chunk, vec in zip(chunks, vectors):
            db.execute("INSERT INTO kb_chunks (doc_id, text, created, embedding) VALUES (?,?,?,?)",
                       (doc_id, chunk, time.time(), pack_vec(vec)))
        db.commit()
    return doc_id, len(chunks)


def all_chunks():
    with db_lock:
        rows = db.execute("SELECT c.id, c.text, c.embedding, d.title FROM kb_chunks c "
                          "LEFT JOIN kb_docs d ON d.id = c.doc_id").fetchall()
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

def build_system_prompt(message):
    parts = [PERSONA]
    facts = all_facts()
    pinned = [f for f in facts if f["pinned"]]
    others = [f for f in facts if not f["pinned"]]
    chosen = pinned + rank(message, others, max(0, FACT_LIMIT - len(pinned)))
    if chosen:
        parts.append("What you know about your user and their home:\n"
                     + "\n".join("- " + f["text"] for f in chosen))
    chunks = rank(message, all_chunks(), KB_LIMIT)
    if chunks:
        notes = "\n\n".join(("[%s]\n%s" % (c["title"], c["text"])) if c["title"] else c["text"] for c in chunks)
        parts.append("Relevant notes from your knowledge base (use if helpful, otherwise ignore):\n" + notes)
    return "\n\n".join(parts)


def generate_reply(message, session):
    system = build_system_prompt(message)
    history = recent_history(session, MAX_HISTORY)
    messages = [{"role": "system", "content": system}] + history + [{"role": "user", "content": message}]
    reply = llm_chat(messages)
    save_message(session, "user", message)
    save_message(session, "assistant", reply)
    if AUTO_MEMORY:
        threading.Thread(target=learn_from_exchange, args=(message, reply), daemon=True).start()
    return reply


MEMORY_PROMPT = (
    "From the exchange below, extract any NEW, durable facts about the user or their home worth remembering "
    "long term (names, preferences, relationships, devices, routines, important dates). One short fact per line, "
    "no bullets or numbering. Ignore anything temporary, trivial or already obvious. If there is nothing worth "
    "saving, reply with exactly: NONE"
)

def learn_from_exchange(user_message, assistant_reply):
    try:
        prompt = "%s\n\nUser: %s\nAssistant: %s" % (MEMORY_PROMPT, user_message, assistant_reply)
        result = llm_chat([{"role": "user", "content": prompt}], temperature=0.0, max_tokens=200, timeout=60)
        if not result or result.strip().upper().startswith("NONE"):
            return
        for line in result.splitlines():
            fact = re.sub(r"^[-*\d.)\s]+", "", line).strip()
            if len(fact) > 3:
                if add_fact(fact, source="auto"):
                    log("Remembered: %s" % fact)
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
        reply = generate_reply(message, session)
    except Exception as error:
        log("Chat error: %s" % error)
        if not LLM_API_KEY:
            return ChatOut(reply="My brain isn't connected yet - set LLM_API_KEY and LLM_MODEL on the Jarvis core.")
        return ChatOut(reply="I'm having trouble thinking at the moment. Please try again in a moment.")
    return ChatOut(reply=reply)


@app.get("/api/memory/facts")
def list_facts(request: Request):
    check_auth(request)
    return [{"id": f["id"], "text": f["text"], "source": f["source"], "pinned": f["pinned"]} for f in all_facts()]

@app.post("/api/memory/facts")
def create_fact(body: FactIn, request: Request):
    check_auth(request)
    fact_id = add_fact(body.text, source="manual", pinned=bool(body.pinned))
    return {"id": fact_id, "saved": fact_id is not None}

@app.delete("/api/memory/facts/{fact_id}")
def remove_fact(fact_id: int, request: Request):
    check_auth(request)
    delete_fact(fact_id)
    return {"deleted": True}


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
                              temperature=0.0, max_tokens=300, timeout=60)
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
