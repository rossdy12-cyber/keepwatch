# Nocturne Chat — Windows client

A tiny standalone client for the self-hosted Nocturne chat relay (jarvis-core). No install, no dependencies —
double-click `nocturne-chat.exe` and it opens a gothic chat window in your browser.

## Use it
1. Double-click **`nocturne-chat.exe`**. A small console window stays open (keep it open while chatting) and
   your browser opens the chat.
2. First run shows a settings form. Enter:
   - **Relay URL** — the jarvis-core address (e.g. `jarvis.nas-server.co.uk`).
   - **Token** — only if the relay has `AUTH_TOKEN` set.
   - **Your name** / **Their name** — e.g. Lauren / Ross.
   - **Private room id** — the same room id the other person uses.
3. Chat. New messages pop up as desktop notifications when the window isn't focused (allow notifications when the
   browser asks). The 🎥 button starts a video call (opens the call page in the browser).

Settings are saved to `%APPDATA%\nocturne-chat\config.json`. Change them any time with the ⚙ button.

## Build it (from any OS with Go)
```sh
cd nocturne-win
GOOS=windows GOARCH=amd64 go build -ldflags "-s -w" -o nocturne-chat.exe .   # Windows .exe
go build -o nocturne-chat .                                                   # native (Mac/Linux)
```
Pure Go, no CGO — cross-compiles from anywhere.

## Video calls across different networks — coturn (recommended)
Video uses WebRTC. On the same home network, public STUN is enough. For calls between your home and, say,
Lauren's network, add a TURN relay on your homelab and point jarvis-core at it (`TURN_URL`/`TURN_USER`/`TURN_PASS`).

A minimal `coturn` service (add to your compose stack; open UDP/TCP 3478, and a UDP relay range):
```yaml
  coturn:
    image: coturn/coturn:4.6.2
    restart: unless-stopped
    network_mode: host          # coturn needs the real ports for media relay
    command: >-
      -n --realm=nas-server.co.uk
      --listening-port=3478
      --min-port=49160 --max-port=49200
      --user=nocturne:CHANGE_ME_STRONG
      --lt-cred-mech --fingerprint --no-cli --no-tls --no-dtls
```
Then set on jarvis-core: `TURN_URL=turn:<your-host>:3478`, `TURN_USER=nocturne`, `TURN_PASS=CHANGE_ME_STRONG`
(matching the coturn `--user`). The call page fetches these automatically from `/call/config`.
