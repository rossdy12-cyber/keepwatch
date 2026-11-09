# NAS Files

NAS Files is a native SwiftUI iPhone app for browsing, previewing, uploading, and managing files on a self-hosted TrueNAS WebDAV server.

## Core features

- Browse WebDAV folders and files
- Preview supported files with Quick Look
- Upload files from the iOS Files picker
- Refresh the current folder
- Configure the WebDAV server, credentials, and root folder

## Offline files

Files can be downloaded for offline use from the file context menu or file preview.

- Downloads show progress and retry state
- Downloaded files are listed in the Downloads tab
- Offline storage usage is shown in Downloads and Settings
- Download failures retry with exponential backoff
- Download notifications can be enabled in Settings
- Downloaded files can be shared or exported from the preview screen

## File management

Files and folders support:

- Pinning
- Renaming
- Moving to another WebDAV folder
- Deleting
- Sharing and exporting

## Browser layout

The Files tab supports:

- List and grid layouts
- Sorting by name, modified date, size, and type
- Pinned-item indicators
- Available-offline indicators

## Development

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open NASFiles.xcodeproj
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

- Do not commit certificates, provisioning profiles, passwords, or `.p12` files.
- Use HTTPS for the WebDAV endpoint.
- Keep the WebDAV server behind authentication or a reverse proxy with access control.
