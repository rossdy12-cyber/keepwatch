# NAS Portal

An iPhone app that opens your TrueNAS web interface straight away, with no browser tabs to find and no
signing in every time, plus one-tap shortcuts to the web pages of the apps on your NAS.

- **TrueNAS tab:** the full TrueNAS web interface (`https://nas-server.co.uk` by default). It stays loaded while you
  use other tabs, and back/forward/reload sit in the top bar. Pull down to refresh. Swipe from the edge to go back.
- **Apps tab:** shortcuts to Jarvis, Frigate, Jellyfin, Navidrome, Sonarr, Radarr, Lidarr, Bazarr, NZBGet, Portainer
  and Nginx Proxy Manager. **Edit** or **+** to change them; long-press a tile to edit or remove it.
- **Sign in once:** every page shares one cookie store, so a single Authelia sign-in covers every app, and sign-ins
  are remembered between launches. Settings → *Sign out of everything* clears them.
- **Self-signed certificates** (TrueNAS on `https://100.x.x.x`) are accepted for home and Tailscale addresses only.

Build: GitHub **Actions → Build NAS Portal IPA → Run workflow**, download **NASPortal-ipa**, and install
`NASPortal.ipa` with Sideloadly or LiveContainer.
