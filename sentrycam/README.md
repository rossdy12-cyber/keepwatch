# SentryCam

A native **Frigate NVR viewer** for your iPhone — live cameras, AI events, and in-app clip playback, working
directly with a standalone Frigate (no Home Assistant needed).

- **Live:** a grid of all your cameras, each refreshing live; tap one for full-screen.
- **Events:** Frigate's AI detections with thumbnails, object + confidence + camera + time; tap to **play the
  recorded clip right in the app**.
- **Tapo patrol (optional):** resume/pause/log your PTZ patrol container, if you run the NAS agent for it.
- **Home Screen widget:** the latest camera snapshot + newest event; tap it to open the app.
- **Tap a Frigate push → the clip:** set `SENTRYCAM_LINK: "true"` in your `frigate-ntfy` app, and tapping the
  notification opens that exact clip in SentryCam (via `sentrycam://event/<id>`).
- Pull to refresh.

## Setup

1. Open **Settings** in the app and enter your Frigate address — e.g. your Tailscale URL
   `https://100.85.127.42:8971` (the authenticated port) or `https://frigate.nas-server.co.uk`.
2. If you use the authenticated port (recommended), add a **Frigate login** (Frigate → Settings → Users; a
   *viewer* account is plenty). Leave the toggle **Accept self-signed certificate** on — Frigate's `:8971`
   ships a self-signed cert.
3. Tap **Test connection**. It should list your cameras.

The password is stored in the iPhone Keychain and only sent to Frigate. The login cookie and all images/clips go
through a session that trusts your NAS's self-signed certificate.

*(Optional)* To control a Tapo PTZ "patrol" container, set the **patrol agent** URL to your NAS agent that runs
`POST /api/antigravity/exec`. Leave it blank to hide those controls.

## Build and install

GitHub **Actions → Build SentryCam IPA → Run workflow**, download the **SentryCam-ipa** artifact, unzip and
install `SentryCam.ipa` with SideStore/Sideloadly.

## Notes

- Live view uses Frigate's `latest.jpg` snapshot refresh (~1 fps) — light and reliable on any network. Event
  clips play at full framerate (downloaded, then played locally).
- Pairs with your `frigate-ntfy` push notifications: get the alert, open SentryCam to watch the clip.
