# Matrix server with WhatsApp and Discord bridges

The TrueNAS half of **Séance** (WhatsApp) and **Conclave** (Discord). One paste installs four containers that set themselves up on the first start:

- **PostgreSQL 16**, the database Synapse stores everything in. It's much faster than the SQLite Synapse uses by default once the bridges have created hundreds of rooms.
- **Synapse 1.165**, a private Matrix server: no federation, no public sign-up, and your account is created for you.
- **mautrix-whatsapp v26.10**, which links to your WhatsApp like WhatsApp Web does.
- **mautrix-discord v0.7.7**, which logs in to your Discord account.

Double-puppeting is switched on, so messages you send from your phone's WhatsApp or Discord show up as you in the apps. Encryption is switched off in the bridges, so messages are stored **unencrypted on the NAS**: keep port 8790 on Tailscale only, and never forward it on your router.

## Upgrading from the SQLite version: a fresh start

This version stores Synapse's data in PostgreSQL and uses **new volume names**, so it starts completely fresh. Nothing is migrated from an earlier install, which means:

- Your Matrix account is created again from `MATRIX_USER` and `MATRIX_PASSWORD`, and the old rooms and message history are not carried over.
- **Re-link WhatsApp** (the `login` command to the WhatsApp bot, or the Séance link screen) and **re-link Discord** (Conclave), then pick your Discord servers again.
- Sign in again in Séance and Conclave. The server address and port (8790) are the same.

The old `synapse-data`, `whatsapp-data`, `discord-data` and `appservices` volumes are no longer used. Once you're happy with the new server you can **delete them**; until then they are a harmless backup. Delete the old `matrix` app before installing this one (or install it under a different app name), because both bind port 8790.

## Risks

These bridges are unofficial. WhatsApp sees a linked device like WhatsApp Web, and bans for that are rare. **Discord's terms forbid automating user accounts**, and the Discord bridge does exactly that. Bans are uncommon but possible, so think about using a spare account, or bridging only a few servers.

## Install on TrueNAS

1. **Apps → Discover Apps → ⋮ → Install via YAML**, name it `matrix`, and paste [`compose.yaml`](compose.yaml).
2. Change the lines marked `CHANGE`:
   - `MATRIX_USER` and `MATRIX_PASSWORD`: the login you'll use in Séance and Conclave.
   - `SERVER_NAME` (optional): it becomes part of your address (`@you:keepwatch.home`) and can **never be changed later**. It doesn't need to be a real domain.
3. **Save.** The first start takes a minute or two. In **Apps → matrix → Logs**: the bridges print `Bridge started`, and Synapse prints `Created the account @you:keepwatch.home`.

Then open Séance or Conclave and enter `http://<your NAS's Tailscale IP>:8790` with your username and password.

## Linking accounts

The apps walk you through it:

- **WhatsApp:** Séance asks for your phone number and shows an 8-character code. On your phone, open WhatsApp → **Settings → Linked Devices → Link a Device → Link with phone number instead**, and type the code.
- **Discord:** Conclave takes your Discord token (its README shows how to copy it from the Discord website), or shows a QR code you can scan with the Discord app on another device. Afterwards, pick which Discord servers to bring across.

## Notes

- The data lives in the `postgres-data`, `synapse-pg-data`, `whatsapp-pg-data`, `discord-pg-data` and `appservices-pg` volumes. Deleting the app keeps them unless you delete those volumes too.
- To start over completely, delete the app *and* those five volumes.
- If you change `POSTGRES_PASSWORD`, do it before the first start: the database keeps the password it was created with.
- `compose.yaml` is generated from `synapse.sh`, `patch_synapse.py` and `bridge.sh`. Edit those, then run `python3 build_compose.py`.
- Synapse is allowed to reach private and Tailscale addresses so it can send pushes to the crypt-relay (it blocks them by default). Federation stays off.
- Tested end to end with Docker Compose: the server starts on PostgreSQL, the account is created, a login works through the client API, and both bridge bots answer `help`. (Authenticated media upload and download and relay push were tested on the earlier SQLite version, not re-tested after the PostgreSQL switch.) Synapse may log "Metric ... already registered" errors for the bridge registrations; they are harmless.
