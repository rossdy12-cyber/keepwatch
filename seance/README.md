# Séance

A gothic black-and-crimson messenger for your WhatsApp chats, through the Matrix server on your NAS (`matrix-server/`).

- **Whispers:** every WhatsApp chat, newest first, with unread counts, typing indicators and search. Swipe to mark read or leave.
- **Chats:** crimson bubbles, read ticks, replies (swipe right on a message), reactions, edits and delete for everyone (long-press). Photos, videos, files and voice notes (hold the microphone, slide left to cancel). WhatsApp voice notes play in the app.
- **New chat:** start a WhatsApp chat with any number.
- **Sanctum:** link WhatsApp with a pairing code, check the link, and a bridge console for anything else.

## Set up

1. Install the Matrix server: see [`../matrix-server`](../matrix-server/README.md).
2. Build with **Actions → Build Seance IPA** and install it with Sideloadly.
3. Sign in with `http://<NAS Tailscale IP>:8790` and your `MATRIX_USER` / `MATRIX_PASSWORD`.
4. **Link WhatsApp:** enter your number. On your phone, open WhatsApp → Settings → Linked Devices → Link a Device → **Link with phone number instead**, and type the code Séance shows.

Recent history (the last 50 messages per chat) is brought across when you link. New messages arrive live while the app is open. There are no push notifications yet.
