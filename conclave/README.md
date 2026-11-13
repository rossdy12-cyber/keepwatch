# Conclave

A gothic black-and-crimson Discord-style app for your Discord servers and DMs, through the Matrix server on your NAS (`matrix-server/`).

- **Server rail:** Missives (your DMs) at the top, then one icon per Discord server, with unread markers and mention counts.
- **Channels:** each server's text channels; tap one to open it.
- **Chat:** Discord-style messages grouped by sender, with replies, reactions, edits, deletes, images, videos, files and voice messages.
- **Sanctum (⚙ or +):** link Discord, choose which servers to bring across, and a bridge console.

## Set up

1. Install the Matrix server: see [`../matrix-server`](../matrix-server/README.md).
2. Build with **Actions → Build Conclave IPA** and install it with Sideloadly.
3. Sign in with `http://<NAS Tailscale IP>:8790` and your `MATRIX_USER` / `MATRIX_PASSWORD`.
4. **Link Discord** (⚙ → Link Discord) with your token. The steps are in the app: copy the `authorization` header from the Network tab of the browser's developer tools on discord.com. Or use the QR code with the Discord app on another device.
5. **Choose servers** (⚙ → Choose servers) and tap **Bring across** for each one you want.

**Risk:** Discord's terms forbid automating user accounts, and this bridge does exactly that. Bans are rare but possible, so think about using a spare account.

**Notifications:** set up the crypt-relay (`crypt-relay/README.md`), then open **⚙ → Notifications** and enter its address and secret. Install with your paid developer Apple ID for push to work.
