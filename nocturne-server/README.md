# Nocturne Server

One small self-contained server for the Nocturne chat apps (iPhone, Android, Windows) — **no jarvis-core, no ntfy,
no Python**. A single Go binary that does:

- the **chat relay** (`/api/relay/*`) with a **private conversation per pair of people** and a login per person,
- the **video-call signalling + call page** (`/call`, SSE based),
- **Apple push** (APNs) for iPhones and **Firebase push** (FCM) for Android phones,
- **join links**: a page per person with the Android download and a one-tap "Open Nocturne and sign in".

## People and conversations
Each person gets their own token and only sees their own conversations ("rooms"). Manage them from the NAS:
```sh
docker exec nocturne-server nocturne-server adduser Ross home,mum --admin
docker exec nocturne-server nocturne-server adduser Lauren home
docker exec nocturne-server nocturne-server adduser Mum mum
docker exec nocturne-server nocturne-server users          # list
docker exec nocturne-server nocturne-server link Mum       # print Mum's join link again
docker exec nocturne-server nocturne-server adduser Mum mum --new-token   # revoke + issue a new link
```
Each command prints that person's **join link** (set `PUBLIC_URL`). Send it to them; opening it on their phone
offers the app and signs them in. Room `home` is the original Ross & Lauren conversation, so its history carries
over. Changes apply immediately, without a restart.

## Android push (Firebase)
Firebase console → Project settings → Service accounts → **Generate new private key**. Save that JSON on the NAS
(not in git), mount it into the container and point `FCM_SERVICE_ACCOUNT` at it (see `compose.yaml`).

Your iPhone (Nocturne) and the Windows client just point their **Relay URL** at this server.

## Run it on TrueNAS
Deploy this folder as a **custom app** (it builds itself from the `Dockerfile` via `compose.yaml`). Or run the
binary directly on any machine:
```sh
go build -o nocturne-server .        # or use the prebuilt binary
PORT=8990 ./nocturne-server
```
Expose it however your other homelab services are reached (reverse proxy / Tailscale), e.g.
`https://nocturne.nas-server.co.uk`.

## Point the apps at it
In Nocturne (iPhone) and the Windows client's settings, set **Relay URL** to this server's address and the same
**room id** + (optional) **token** on both, with different names. Nothing else changes.

## Native Apple push (optional but recommended)
Real push to a closed iPhone must go through Apple's APNs — that's an Apple rule, not a server choice. It needs a
one-time setup (see the chat for the walkthrough):

1. An **explicit App ID** `com.ross.nocturne` with **Push Notifications** enabled (not a `*` wildcard).
2. An **APNs Auth Key** (`.p8`) + its **Key ID**.
3. Your signer resigning Nocturne with a **profile for that explicit App ID**.

Then set `APNS_KEY_ID`, `APNS_TEAM_ID` (G42YL9QS8W) and paste the `.p8` into `APNS_KEY_P8` in `compose.yaml`.
`APNS_ENV=auto` figures out production vs sandbox for you. Leave `APNS_KEY_P8` empty to run without push.

Without push, messages still arrive live while the app is open; you just won't get a banner when it's closed.

## Video across different networks
Same-network calls work on public STUN automatically. For calls between different networks, run a `coturn` TURN
relay and set `TURN_URL`/`TURN_USER`/`TURN_PASS` (coturn snippet in `../nocturne-win/README.md`).

## Endpoints
`GET /health` · `POST /api/relay/send` · `GET /api/relay/messages?room=&since=` · `POST /api/relay/seen` ·
`GET /api/relay/presence?room=` · `POST /api/push/register` (`platform`: `ios`/`android`) · `POST /api/call/ring` ·
`GET /api/me` (who am I + my conversations) · `GET /join?t=` · `GET /app/nocturne.apk` ·
`GET /api/call/stream?room=&id=` (SSE) · `POST /api/call/signal?room=&id=` · `GET /call` · `GET /call/config`
