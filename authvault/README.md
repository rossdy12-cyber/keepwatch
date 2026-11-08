# AuthVault

A private **two-factor (TOTP) authenticator** for your iPhone — like Google Authenticator or Aegis, but your
codes stay on your device and back up **encrypted to your own NAS**, not someone else's cloud.

- **6/8-digit TOTP codes** with a live countdown ring; tap a code to copy it.
- **Add accounts** by scanning the QR code, entering the key by hand, or pasting an `otpauth://` link.
- **Face ID / passcode lock** on open.
- **Encrypted backup** (AES-GCM, your passphrase): save to a file (Files/AirDrop) or push to your NAS over
  **WebDAV**, and restore the same way.
- Search, reorder, delete. Everything is generated on-device and offline — the only network use is the optional
  backup.

## Add an account
Tap **⋯ → Add account**, then **Scan** the site's QR code (most common), or switch to **Manual**/**Paste**.

## Back up to your NAS
Tap **⋯ → Backup & settings**:
1. Set an **encryption passphrase** (you'll need it to restore — keep it safe, it can't be recovered).
2. Under **NAS backup**, put a **WebDAV file URL** on your NAS (TrueNAS → Apps → WebDAV, or Nextcloud), plus the
   username/password. Leave **Accept self-signed certificate** on for a LAN cert.
3. **Back up to NAS** uploads the whole encrypted vault; **Restore from NAS** pulls it back on a new device.

Prefer files? Use **Export encrypted file** to save/AirDrop an `.authvault` file, and **Import** to restore it.

## Build and install
GitHub **Actions → Build AuthVault IPA → Run workflow**, download the **AuthVault-ipa** artifact, unzip and
install `AuthVault.ipa` with SideStore/Sideloadly.

## Notes
- Codes follow RFC 6238 (TOTP) using the device's CryptoKit; SHA-1/256/512, 30s default period, 6 or 8 digits.
- The accounts (with their secrets) are stored in the iOS Keychain; backups are encrypted with a key derived
  from your passphrase (HKDF-SHA256) and AES-GCM, so the file on your NAS is useless without the passphrase.
