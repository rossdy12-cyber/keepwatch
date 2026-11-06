# NAS Command

A native **TrueNAS SCALE command center** for your iPhone. A quick dashboard of your server's health with one-tap
control of its apps — no more digging through the web UI on a phone screen.

- **System:** hostname, version, uptime, CPU cores + load, memory, model.
- **Pools:** each pool with its health (green = online, red = degraded).
- **Apps:** every app with its state, and a tap to **Start / Stop / Restart (Redeploy)**.
- **Alerts:** active TrueNAS alerts, newest first.
- **Home Screen widget:** overall health, apps running, pools and alerts at a glance.
- **Background alerts:** a local notification when a pool goes degraded or an app stops (best-effort, when iOS
  grants a background refresh; allow notifications when asked).
- Pull to refresh. Everything is read live from the TrueNAS REST API.

## Setup

1. In TrueNAS, make an API key: your **username (top-right) → API Keys → Add**, name it "NAS Command", copy it.
2. In the app's **Settings**, enter your TrueNAS address (your domain, or the Tailscale/LAN address like
   `http://192.168.1.2`) and paste the API key. Tap **Test connection**.
3. The key is stored in the iPhone Keychain and only ever sent to your NAS.

If your NAS uses a self-signed certificate (plain LAN https), turn on **Accept self-signed certificate**.

## Build and install

GitHub **Actions → Build NAS Command IPA → Run workflow**, download the **NASCommand-ipa** artifact, unzip it and
install `NASCommand.ipa` with SideStore/Sideloadly.

## Notes

- Built against the TrueNAS SCALE v2.0 REST API (`/api/v2.0/`). App start/stop/redeploy uses the Docker-app
  endpoints in Electric Eel (24.10) and later. If an action doesn't take on your version, the app shows the
  server's error — tell me what it says and I'll adjust the endpoint.
- Read-only by design apart from app lifecycle actions; it never changes storage or settings.
