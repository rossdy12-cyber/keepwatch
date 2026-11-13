# Reliquary server

The TrueNAS half of **Reliquary**, the gothic gallery for your IDrive-Sync folder. It reads the folder **read-only** and gives the iPhone app:

- folder listings,
- a timeline of every photo and video, sorted by the date taken (from EXIF, or the video's recording date),
- thumbnails, including iPhone HEIC photos and video posters,
- originals, with streaming for videos,
- search by file and folder name, and favourites ("Relics").

Thumbnails, the date index and favourites live in their own `reliquary-cache` volume. Nothing in IDrive-Sync is ever changed.

## Install on TrueNAS

1. Find where IDrive-Sync really lives. In **Datasets**, select it and note the path, which looks like `/mnt/<pool>/…/IDrive-Sync`. Or open your Stash app's **Edit** page: the host path mounted at `/data/IDrive-Sync` is the one you want.
2. **Apps → Discover Apps →** the three dots (⋮) **→ Install via YAML**.
3. Name: `reliquary`. Paste the whole of [`compose.yaml`](compose.yaml).
4. Change the lines marked `CHANGE`:
   - the volume line: put your IDrive-Sync path on the left of `:/gallery:ro`.
   - `GALLERY_TOKEN`: a long random password.
5. **Save.** **Apps → reliquary → Logs** should show `Reliquary listening on port 8788`, then `Scan finished … N items` when the catalogue is built. The first scan of a big library can take a while: it reads each photo's date. The app works during the scan, and items appear as they're catalogued.

## Connect the iPhone app

Open Reliquary and enter:

- **Server:** `http://<your NAS's Tailscale IP>:8788`
- **Token:** your `GALLERY_TOKEN`

## Settings (in the app's YAML)

| Setting | Default | What it does |
|---|---|---|
| `RESCAN_MINUTES` | `30` | How often to look for new or removed files. **Sanctum → Look for new photos now** does it straight away. |
| `SHOW_HIDDEN` | `false` | `true` also shows files and folders whose names start with a dot. |

## Notes

- Keep port 8788 on Tailscale only; don't forward it on your router.
- Formats: JPEG, HEIC, PNG, GIF, WebP, TIFF and BMP photos; MP4, MOV, M4V, 3GP, AVI, MKV, WebM, MTS, WMV and MPEG videos. The iPhone plays MP4/MOV/M4V/3GP directly. For other video formats, Reliquary shows the thumbnail, and you can share the file to another app.
- `compose.yaml` is generated: edit `server.py`, then run `python3 build_compose.py`.
