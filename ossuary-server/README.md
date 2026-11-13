# Ossuary server

The TrueNAS half of **Ossuary**, the gothic game launcher. It reads your games folder **read-only** and gives the iPhone app each system, its games, box art and downloads.

## Folder layout

Put one folder per system inside your games folder. Recognised names (case doesn't matter) include `nes`, `snes`, `gb`, `gbc`, `gba`, `n64`, `nds`, `megadrive`/`genesis`, `psx`, `mastersystem`, `gamegear`, `saturn`, `dreamcast`, `ps2`, `psp`, `gamecube`, `wii`, `3ds`, `arcade`/`mame`, `dos`, `scummvm`, `pc` and `indie`. Any other folder is shown under its own name.

```
Games/
  snes/   Super Metroid.sfc   Chrono Trigger (USA).sfc
  gba/    Metroid Fusion (USA).gba
  psx/    Final Fantasy VII (Disc 1).bin   Final Fantasy VII (Disc 1).cue
  PC/     Hollow Knight.zip   Some Game/  (folder with cover.jpg)
```

- **Box art:** an image next to the game with the same name (`Super Metroid.png`), an `art/` or `covers/` folder, or `cover.jpg` inside a game folder. Otherwise it's looked up in the free libretro thumbnail archive by name, which works best with No-Intro-style names like `Chrono Trigger (USA).sfc`.
- A `.cue` sheet that sits next to its `.bin` is hidden, and the `.bin` is listed.
- Text, save and BIOS files (and `bios`, `saves`, `states` folders) are skipped.
- Games that are folders are listed, but you can't download them until you zip them.

## Install on TrueNAS

1. **Apps → Discover Apps → ⋮ → Install via YAML**, name it `ossuary`, and paste [`compose.yaml`](compose.yaml).
2. Change the lines marked `CHANGE`: the games folder path (keep the leading `/`, and keep `:/games:ro`) and `OSSUARY_TOKEN`.
3. **Save.** The logs should say `Ossuary listening on port 8789`.

In the app: **Server** `http://<NAS Tailscale IP>:8789`, **Token** your `OSSUARY_TOKEN`.

`ONLINE_ART: "false"` stops the server fetching art from the internet. `compose.yaml` is generated: edit `server.py`, then run `python3 build_compose.py`.
