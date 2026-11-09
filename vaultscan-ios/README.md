# VaultScan

VaultScan is a native SwiftUI iPhone app for scanning, extracting text from, organising, and uploading documents to a self-hosted WebDAV server.

## Core features

- Scan documents with the iPhone camera
- Run on-device OCR using Vision
- Extract useful fields such as supplier, date, amount, and notes
- Store documents locally as searchable PDFs
- Automatically queue new scans for WebDAV upload
- Upload PDFs with progress, retries, and exponential backoff
- Search documents by title, supplier, notes, OCR text, and tags
- Export documents to CSV

## Resilient uploads

VaultScan uses a shared upload queue backed by the local document store:

- New scans are automatically queued
- Pending, uploading, uploaded, and failed states are shown in Documents and Uploads
- Upload progress is displayed while a document is uploading
- Failed uploads retry automatically with exponential backoff
- A Wi-Fi-only setting prevents uploads over cellular data
- Local notifications report completed and failed uploads
- The Uploads screen provides manual queue processing and retry-failed actions

## Tags and export

Each scanned document can have comma-separated tags. Tags are included in document search and CSV export.

CSV export includes:

- Title
- Category
- Supplier
- Document date
- Amount
- Notes
- Tags
- OCR text
- Upload state
- Remote path

## Development

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open VaultScan.xcodeproj
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
