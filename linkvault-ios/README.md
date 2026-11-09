# LinkVault

LinkVault is a private SwiftUI iPhone app for saving, organising, searching, and revisiting links.

It is designed for technical documentation, server guides, product pages, design inspiration, articles, and research references.

## Features

- Save links with title, notes, tags, and read state
- Automatically fetch page title and description where available
- Search across titles, URLs, notes, tags, and saved descriptions
- Filter by unread, read, favourites, and tags
- Open links in Safari or the default browser
- Store the library locally on the iPhone
- Build a signed IPA using GitHub Actions on a macOS runner

## Planned features

- Offline article snapshots
- Full-text search of saved page content
- Browser Share Sheet extension
- iCloud or self-hosted synchronisation
- Reading-list queues and scheduled reminders

## Development

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open LinkVault.xcodeproj
```

## GitHub Actions IPA build

Push a tag such as `v0.1.0` to run the macOS GitHub Actions workflow.

Configure these repository secrets:

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE_P12` | Base64-encoded Apple Distribution certificate and private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the exported `.p12` certificate |
| `MOBILEPROVISION_BASE64` | Base64-encoded Ad Hoc provisioning profile |
| `KEYCHAIN_PASSWORD` | Random password used only by the CI keychain |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID |

## Security

- Do not commit certificates, provisioning profiles, passwords, or API tokens.
- The initial version keeps all links and metadata on-device.
