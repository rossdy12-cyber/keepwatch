# Reliquary

A gothic black-and-crimson gallery for iPhone that shows the photos and videos in your **IDrive-Sync** folder on TrueNAS.

- **Chronicle:** everything, newest first, under blackletter month headings ("October · MMXIX"). Filter to photos or videos, search by file or folder name, and pinch the grid for bigger or smaller squares.
- **Catacombs:** browse the folders. Each one is a gothic arched window showing its newest picture.
- **Relics:** your favourites. Tap the heart in the viewer, or long-press a thumbnail.
- **The viewer:** swipe between items; pinch or double-tap to zoom (it loads the full original as you look); swipe down to close. Videos stream with the system player. There's a slideshow, details for each item (date taken, size, megapixels, length), and sharing, which downloads the original so you can save it to Photos or send it.
- **Sanctum:** library counts, a "look for new photos now" button, and the connection settings.

Reliquary only reads the folder: it can't change or delete anything on the NAS.

## Set up

1. Install the server on TrueNAS: see [`../reliquary-server`](../reliquary-server/README.md).
2. Build the app: **Actions → Build Reliquary IPA → Run workflow** (it also runs when `reliquary/` changes). Download **Reliquary-ipa** and install it with Sideloadly.
3. Open Reliquary and enter the server address (`http://<NAS Tailscale IP>:8788`) and your `GALLERY_TOKEN`.
