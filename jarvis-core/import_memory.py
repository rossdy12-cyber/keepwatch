#!/usr/bin/env python3
"""Import a memory into your Jarvis core.

Feeds facts, documents, or an export from another AI assistant into Jarvis so it understands more. Run it from
any computer that can reach the core (it only uses the Python standard library).

Examples:
    # A list of personal facts (one per line) that Jarvis should always know:
    python3 import_memory.py --url https://jarvis.nas-server.co.uk facts about_me.txt

    # A document / manual / notes for Jarvis to search when answering:
    python3 import_memory.py --url https://jarvis.nas-server.co.uk knowledge boiler-manual.txt --title "Boiler"

    # A ChatGPT export (the conversations.json, or the whole .zip) - added as searchable knowledge, and you can
    # add --distill to also pull out durable facts with the LLM:
    python3 import_memory.py --url https://jarvis.nas-server.co.uk chatgpt export.zip

    # A Claude export (conversations.json / data.json):
    python3 import_memory.py --url https://jarvis.nas-server.co.uk claude conversations.json

If your core has an AUTH_TOKEN set, pass it with --token.
"""

import argparse
import json
import os
import sys
import urllib.request
import zipfile


def post(url, path, payload, token):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url.rstrip("/") + path, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read() or b"{}")


# ------------------------------------------------------------------ reading the various file shapes

def read_text_file(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def load_json_any(path):
    """Returns parsed JSON from a .json file or from conversations.json inside a .zip."""
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            name = next((n for n in archive.namelist() if n.endswith("conversations.json")), None)
            if not name:
                name = next((n for n in archive.namelist() if n.endswith(".json")), None)
            if not name:
                raise SystemExit("No conversations.json found inside the zip.")
            with archive.open(name) as handle:
                return json.loads(handle.read().decode("utf-8", "replace"))
    return json.loads(read_text_file(path))


def chatgpt_conversations(data):
    """Turns a ChatGPT export into (title, text) documents - one per conversation."""
    docs = []
    for convo in data if isinstance(data, list) else []:
        title = convo.get("title") or "ChatGPT conversation"
        lines = []
        mapping = convo.get("mapping") or {}
        # Walk messages in creation order.
        nodes = sorted(mapping.values(), key=lambda n: ((n.get("message") or {}).get("create_time") or 0))
        for node in nodes:
            msg = node.get("message") or {}
            role = (msg.get("author") or {}).get("role")
            content = msg.get("content") or {}
            parts = content.get("parts") if isinstance(content, dict) else None
            if not parts:
                continue
            text = "\n".join(p for p in parts if isinstance(p, str)).strip()
            if text and role in ("user", "assistant"):
                lines.append(("You" if role == "user" else "Assistant") + ": " + text)
        if lines:
            docs.append((title, "\n".join(lines)))
    return docs


def claude_conversations(data):
    """Turns a Claude export (list of conversations with chat_messages) into (title, text) documents."""
    docs = []
    for convo in data if isinstance(data, list) else []:
        title = convo.get("name") or convo.get("title") or "Claude conversation"
        lines = []
        for msg in convo.get("chat_messages") or convo.get("messages") or []:
            sender = msg.get("sender") or msg.get("role") or ""
            text = msg.get("text") or msg.get("content") or ""
            if isinstance(text, list):
                text = "\n".join(p.get("text", "") for p in text if isinstance(p, dict))
            text = (text or "").strip()
            if text:
                who = "You" if sender in ("human", "user") else "Assistant"
                lines.append(who + ": " + text)
        if lines:
            docs.append((title, "\n".join(lines)))
    return docs


# ------------------------------------------------------------------ main

def main():
    parser = argparse.ArgumentParser(description="Import memory into the Jarvis core.")
    parser.add_argument("mode", choices=["facts", "knowledge", "chatgpt", "claude", "auto"],
                        help="facts/knowledge for a plain text file; chatgpt/claude for an export; auto to guess.")
    parser.add_argument("file", help="The file to import (.txt, .md, .json or .zip).")
    parser.add_argument("--url", required=True, help="Jarvis core base URL, e.g. https://jarvis.nas-server.co.uk")
    parser.add_argument("--token", default="", help="AUTH_TOKEN, if your core requires one.")
    parser.add_argument("--title", default=None, help="Title for a knowledge document.")
    parser.add_argument("--distill", action="store_true",
                        help="Also ask Jarvis to pull durable facts out of an imported export.")
    args = parser.parse_args()

    if not os.path.exists(args.file):
        raise SystemExit("No such file: " + args.file)

    mode = args.mode
    if mode == "auto":
        lower = args.file.lower()
        if lower.endswith(".zip"):
            mode = "chatgpt"
        elif lower.endswith(".json"):
            mode = "chatgpt"   # try ChatGPT shape first; falls back to Claude below
        else:
            mode = "facts"

    if mode in ("facts", "knowledge"):
        text = read_text_file(args.file)
        result = post(args.url, "/api/memory/import", {
            "title": args.title or os.path.basename(args.file),
            "text": text,
            "kind": mode,
        }, args.token)
        print("Imported:", result)
        return

    # An export from another assistant.
    data = load_json_any(args.file)
    docs = chatgpt_conversations(data)
    if not docs:
        docs = claude_conversations(data)
    if not docs:
        raise SystemExit("Couldn't find any conversations in that file. Try: facts/knowledge <file>.")

    total_chunks = 0
    for title, text in docs:
        result = post(args.url, "/api/knowledge", {"title": title, "text": text}, args.token)
        total_chunks += int(result.get("chunks", 0))
    print("Imported %d conversation(s) as knowledge (%d chunks)." % (len(docs), total_chunks))

    if args.distill:
        combined = "\n\n".join(t for _, t in docs)
        result = post(args.url, "/api/memory/distill", {"text": combined, "max_windows": 40}, args.token)
        print("Distilled durable facts from the export:", result)


if __name__ == "__main__":
    main()
