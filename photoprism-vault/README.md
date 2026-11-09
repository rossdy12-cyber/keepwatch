# PhotoVault

PhotoVault is a SwiftUI iPhone client for a self-hosted PhotoPrism server. It is designed for private photo browsing and uploading from an iPhone.

## Features

- PhotoPrism server login using an app password
- Face ID unlock before opening the library
- Photo grid using PhotoPrism server-generated thumbnails
- Full-screen photo viewer with swipe navigation
- Photo search
- Photo and video upload queue
- Upload progress and retry
- Server settings stored in the iOS Keychain

## Build an unsigned IPA

This repository uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project and GitHub Actions to build an unsigned IPA.

1. Push a commit to `main`.
2. Open the repository's **Actions** tab.
3. Select **Build unsigned IPA**.
4. Download the `PhotoVault-unsigned-ipa` artifact.
5. Import the IPA into SideStore and sign it with your Apple ID.

The workflow produces an unsigned IPA because SideStore performs the signing on your device.

## PhotoPrism setup

Create an app password in PhotoPrism:

1. Open PhotoPrism in a browser.
2. Go to **Settings → Advanced → Apps**.
3. Create an app password.
4. In PhotoVault, enter your PhotoPrism server URL, PhotoPrism username, and the app password.

Do not put your PhotoPrism password or app password into this repository.

## Security

- Use HTTPS for remote access.
- Prefer VPN access such as Tailscale or WireGuard rather than exposing PhotoPrism directly to the internet.
- The server URL and app password are stored in the iOS Keychain.
- Face ID is used as an app-level lock; it is not a substitute for securing the PhotoPrism server itself.
