# Crypt push relay

Sends a push notification to Crypt on your iPhone within seconds of a new letter landing in any of your inboxes:

> **Vlad Dracul**
> Dinner ✠ at midnight

Crypt registers your iPhone and your accounts with this relay. The relay keeps a live connection to each inbox (IMAP IDLE) and sends the alert through Apple's push service with your APNs key. Tapping the notification opens that letter in Crypt. The app icon badge shows how many letters are unread across all your inboxes.

You need a **paid Apple Developer account**, and you must install Crypt with Sideloadly **using that account's Apple ID**. A free Apple ID can't receive push.

## 1. Make an APNs key

1. Go to [developer.apple.com/account](https://developer.apple.com/account) → **Certificates, IDs & Profiles → Keys → +**.
2. Name it `Crypt`, tick **Apple Push Notifications service (APNs)**, choose **Sandbox & Production**, then **Continue → Register**.
3. **Download** the `.p8` file (you can only do this once) and note the **Key ID**.
4. Note your **Team ID** (top right of the developer site, or under **Membership details**).

## 2. Install the relay on TrueNAS

1. **Apps → Discover Apps →** the three dots (⋮) **→ Install via YAML**.
2. Name: `crypt-relay`. Paste the whole of [`compose.yaml`](compose.yaml).
3. Change the lines marked `CHANGE`:
   - `RELAY_SECRET`: a long random password.
   - `APNS_KEY`: open the `.p8` file in Notepad and replace the three placeholder lines with the whole file, starting with `-----BEGIN PRIVATE KEY-----` and ending with `-----END PRIVATE KEY-----`. Keep every line indented the same as the placeholder.
   - `APNS_KEY_ID` and `APNS_TEAM_ID`.
4. **Save.** In **Apps → crypt-relay → Logs** you should see `APNs key … loaded` and `Crypt relay listening on port 8787`.

## 3. Turn on notifications in Crypt

1. Reinstall Crypt from the latest build (it carries the push permission) with Sideloadly, signed in with your **paid** developer Apple ID.
2. In Crypt, open the sidebar (☰) → **Notifications**.
3. **Relay address:** `http://<your NAS's Tailscale IP>:8787`. **Relay secret:** your `RELAY_SECRET`.
4. Tap **Turn on notifications** and allow them. The status should say *The relay is watching N accounts*.
5. Tap **Send a test notification**.

Crypt sends the relay your accounts again whenever you add or remove one.

## Séance and Conclave

The same relay pushes new WhatsApp and Discord messages for **Séance** and **Conclave**. It acts as the Matrix "push gateway" that Synapse sends notifications to. In either app, open **Sanctum → Notifications**, enter the relay's address and `RELAY_SECRET`, and tap **Turn on notifications**. Install those apps with your paid developer Apple ID too. If Sideloadly doesn't switch on push for them, tick **Push Notifications** on their app IDs at developer.apple.com.

## Notes

- **Your mail passwords are stored on the NAS** (in the `crypt-relay-data` volume, readable only by the container) so the relay can watch your inboxes. Keep port 8787 reachable over Tailscale only: don't forward it on your router.
- Letters that are already marked read (for example, ones you sent yourself) don't notify you. If more than five arrive at once you get five alerts, and the last one says "and N more".
- `SHOW_PREVIEW: "false"` hides subjects: alerts say just *New letter*.
- If a mail password is refused, the relay logs it and tries again every 15 minutes. Remove the account in Crypt and add it again with the new app password.
- `compose.yaml` is generated: edit `relay.py`, then run `python3 build_compose.py`.

## Troubleshooting

| Crypt or the log says | Fix |
|---|---|
| *This copy of Crypt isn't allowed to receive push* | Reinstall Crypt with Sideloadly using your **paid** developer Apple ID. If you already did, open developer.apple.com → **Identifiers**, open the app ID Sideloadly made for Crypt, tick **Push Notifications**, save, and reinstall. |
| *Couldn't reach the relay* | Turn Tailscale on, check the address and port, and check the relay is running. |
| *The relay rejected the secret* | Type the exact `RELAY_SECRET` into Crypt. |
| *Apple rejected the key* | Check `APNS_KEY` (the whole file), `APNS_KEY_ID` and `APNS_TEAM_ID`. |
| *the key's team doesn't match…* | The key must come from the same developer team as the Apple ID that signed Crypt. |
| *push isn't enabled for this app ID* | In the developer site, under **Identifiers**, open Crypt's app ID and tick **Push Notifications**. Then reinstall. |
