# Jarvis for iPhone

A chat-and-voice app for the **Jarvis core** running on your TrueNAS server, reached at
`https://jarvis.nas-server.co.uk` (or any address you type in).

- **Chat** with streaming replies, Markdown, copy, retry and stop.
- **Voice:** tap the microphone, speak, tap again to send. Replies can be read aloud (Settings → Speak replies).
- **Status dot** shows whether Jarvis is reachable; tap it to check again.
- The conversation is kept on the phone; ✎ starts a new one (with a new `session_id`).

## Which Jarvis APIs it understands

Settings → **Connection type** is **Detect automatically** by default. On first use (or **Test connection**) the app looks for:

| Type | Endpoint it uses |
|---|---|
| OpenAI-compatible | `GET /v1/models`, then `POST /v1/chat/completions` (streamed) |
| Ollama | `GET /api/tags`, then `POST /api/chat` (streamed) |
| Custom JSON | Reads `/openapi.json` (FastAPI etc.) to find a chat-like `POST` path and its message field |

For a custom endpoint the app sends `{"message": "…", "session_id": "…"}` (the path and field name are editable) and accepts a
reply as plain text, JSON (`reply`, `response`, `answer`, `text`, `content`, `message`, …), server-sent events or NDJSON.

Optional security: a bearer token (`Authorization: Bearer …`) and a **Cloudflare Access service token**
(`CF-Access-Client-Id` / `CF-Access-Client-Secret`). Both are stored in the iPhone Keychain.

## Build and install

Same as Keepwatch (see the main README): GitHub **Actions → Build Jarvis IPA → Run workflow**, download the
**Jarvis-ipa** artifact, unzip it and install `Jarvis.ipa` with Sideloadly. It counts towards the free Apple ID's 3-app limit.

## If it says "Cloudflare couldn't get through (error 525)"

`*.nas-server.co.uk` all goes through Cloudflare to **Nginx Proxy Manager** on the NAS. A 525 for `jarvis.` means
Nginx Proxy Manager has no proxy host for that name, so it has no SSL certificate to offer. (Over plain http the same
name shows Nginx Proxy Manager's "Congratulations… a host that isn't set up yet" page.) Fix it in Nginx Proxy Manager:

1. **Hosts → Proxy Hosts → Add Proxy Host.** Domain name: `jarvis.nas-server.co.uk`.
2. Scheme `http`, forward hostname/IP: the NAS's LAN IP, forward port: the Jarvis app's port (TrueNAS → Apps → Jarvis).
   Turn on **Websockets Support** and **Block Common Exploits**.
3. **SSL** tab: pick your existing `*.nas-server.co.uk` certificate (or request a new one), turn on **Force SSL**. Save.

Then open `https://jarvis.nas-server.co.uk` in Safari: you should get Jarvis, not an error page. You can also skip
Cloudflare entirely: put `http://<nas-tailscale-ip>:<jarvis-port>` as the address and turn on Tailscale.
