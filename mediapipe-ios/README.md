# MediaPipe

MediaPipe is a native SwiftUI iPhone app for submitting and monitoring self-hosted media downloads.

The initial release focuses on MeTube:

- Submit a URL for video or audio download
- Choose available format and quality
- Send downloads to configured MeTube folders
- View queued, active, completed, and failed jobs in real time
- Share a URL from Safari or another app directly into MeTube
- View queue diagnostics and recent Socket.IO events
- Store the MeTube server URL and API token securely in the iOS Keychain
- Build a signed IPA using GitHub Actions macOS runners

## Live queue

The app connects to MeTube using Socket.IO and listens for common queue events:

```text
added
updated
completed
deleted
queue
download-started
download-progress
download-finished
download-error
download-cancelled
```

It maps status, progress, downloaded/total bytes, speed, ETA, thumbnail, and error information where MeTube provides them.

The Diagnostics screen shows the connection state and the last 100 raw Socket.IO events, making it easy to identify the exact event names and payload structure used by your MeTube instance.

## Share Extension

The **Add to MediaPipe** Share Extension extracts an HTTP or HTTPS URL and submits it directly to MeTube.

Configure the shared extension settings in MediaPipe → Settings:

- MeTube server URL
- API token
- Default destination folder
- Default output type
- Default quality

These settings are stored in the shared App Group:

```text
group.uk.co.rossdymond.mediapipe
```

## Development

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open MediaPipe.xcodeproj
```

## GitHub Actions IPA build

Push a tag such as `v0.1.0` to run the macOS GitHub Actions workflow.

Configure these repository secrets before building:

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE_P12` | Base64-encoded Apple Distribution certificate and private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the exported `.p12` certificate |
| `MOBILEPROVISION_BASE64` | Base64-encoded Ad Hoc provisioning profile |
| `KEYCHAIN_PASSWORD` | Random password used only by the CI keychain |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID |

## Security

- Do not commit certificates, provisioning profiles, API tokens, or `.p12` files.
- Use HTTPS for the MeTube endpoint.
- Keep the MeTube instance behind authentication or a reverse proxy with access control.
