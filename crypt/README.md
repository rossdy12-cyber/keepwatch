# Crypt

Crypt is a gothic email app for iPhone: black and crimson, blackletter titles, wax-seal monograms, and a blood-drop for each unread letter. It signs in to a real mailbox over IMAP and sends over SMTP, so it works with iCloud, Gmail, Outlook, Yahoo, Fastmail and most other providers.

- **Inbox and every folder:** newest first, with previews; pull down to refresh; scroll to load older mail.
- **Swipe:** right to mark read/unread; left to flag or delete (deleting moves to Trash; in Trash it deletes for good).
- **Reading:** HTML emails are recoloured to match the dark theme (tap the sun to see the original colours). JavaScript is off, and links open in Safari. Attachments can be opened or saved with the share sheet.
- **Writing:** new letters, Reply, Reply All and Forward. A copy goes to Sent when your provider doesn't do that itself.
- **Search** the current folder on the server.
- **Move** a letter to Archive, Junk or any folder.

Your password is kept in the iPhone Keychain, and Crypt talks only to your mail provider.

## Build and install

It's built the same way as the other apps in this repo:

1. On GitHub, open **Actions → Build Crypt IPA → Run workflow** (it also runs when anything in `crypt/` changes).
2. When it finishes, download **Crypt-ipa** from the run's page and unzip it to get `Crypt.ipa`.
3. Install `Crypt.ipa` with **Sideloadly** and your Apple ID, as in the main Keepwatch README. Re-sign every 7 days.

## Signing in

Most providers won't accept your normal password from a third-party app. Make an **app password** first:

| Provider | Where to make an app password | Servers Crypt fills in |
|---|---|---|
| iCloud | account.apple.com → Sign-In and Security → App-Specific Passwords | imap.mail.me.com:993, smtp.mail.me.com:587 (STARTTLS) |
| Gmail | myaccount.google.com/apppasswords (needs 2-Step Verification) | imap.gmail.com:993, smtp.gmail.com:465 (SSL/TLS) |
| Yahoo | Account Security → Generate app password | imap.mail.yahoo.com:993, smtp.mail.yahoo.com:465 |
| Fastmail | Settings → Privacy & Security → App passwords | imap.fastmail.com:993, smtp.fastmail.com:465 |
| Outlook | Often not possible: Microsoft has turned off password sign-in for most personal accounts. | outlook.office365.com:993, smtp-mail.outlook.com:587 |

Type your email and Crypt picks the provider. For anything else, choose **Other** and enter the IMAP and SMTP servers. Crypt checks both before it saves the account.

## Limits

- One account at a time.
- No push: mail is fetched when you open the app or pull to refresh.
- Letters are sent as plain text; you can't attach files yet.
- IMAP must use SSL/TLS (usually port 993).

## How it's built

SwiftUI, iOS 17, no third-party code. `Mail/IMAPClient.swift` and `Mail/SMTPClient.swift` speak the protocols directly over `URLSessionStreamTask` (which handles TLS and STARTTLS), and `Mail/MIME.swift` decodes multipart messages, quoted-printable, base64, encoded headers and character sets. The fonts are UnifrakturMaguntia and Cinzel, both under the SIL Open Font License (see `Crypt/Resources/Fonts`).
