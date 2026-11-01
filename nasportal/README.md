# NAS Portal

An iPhone app that opens your TrueNAS web interface straight away, with no browser tabs to find and no
signing in every time, plus one-tap shortcuts to the web pages of the apps on your NAS.

- **TrueNAS tab:** the full TrueNAS web interface (`https://nas-server.co.uk` by default). It stays loaded while you
  use other tabs, and back/forward/reload sit in the top bar. Pull down to refresh. Swipe from the edge to go back.
- **Apps tab:** shortcuts to Jarvis, Frigate, Jellyfin, Navidrome, Sonarr, Radarr, Lidarr, Bazarr, NZBGet, Portainer
  and Nginx Proxy Manager. **Edit** or **+** to change them; long-press a tile to edit or remove it.
- **Sign in once:** every page shares one cookie store, so a single Authelia sign-in covers every app, and sign-ins
  are remembered between launches. Settings → *Sign out of everything* clears them.
- **2FA codes typed in for you:** Settings → *Two-factor codes* → *Add a 2FA code*. NAS Portal then makes the same
  6-digit codes as your authenticator app and fills them into the TrueNAS and Authelia sign-in pages, so you never
  leave the app (switching to the authenticator makes TrueNAS reset its login form). A key button with the current
  code also appears at the bottom of the page while a code is asked for: tap to fill, long-press to copy.
  - **Getting the secret:** your authenticator can't show it, so take it from the server:
    TrueNAS → your user menu (top right) → *Two-Factor Authentication* → *Renew 2FA secret*, screenshot the QR code,
    then in NAS Portal choose *Read the QR code from a screenshot*. Scan the same QR code into your authenticator app.
    For Authelia, register a new one-time password device in its settings and do the same.
  - Secrets are stored in this iPhone's Keychain only. It does mean one phone holds both your password and your codes.
- **Self-signed certificates** (TrueNAS on `https://100.x.x.x`) are accepted for home and Tailscale addresses only.

Build: GitHub **Actions → Build NAS Portal IPA → Run workflow**, download **NASPortal-ipa**, and install
`NASPortal.ipa` with Sideloadly or LiveContainer.
