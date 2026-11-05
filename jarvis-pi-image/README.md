# Jarvis Pi image

A ready-to-flash Raspberry Pi OS Lite (32-bit, Bookworm) card image with the "Hey Jarvis" speaker built in.
It works on every Raspberry Pi, including the Pi 1 B+. No SSH or setup commands are needed.

## Use it

1. Download **jarvis-pi-image** from the latest *Build Jarvis Pi image* run (GitHub → Actions) and unzip it to get
   `jarvis-pi.img.xz`.
2. In **Raspberry Pi Imager**: Device *Raspberry Pi 1* (or yours) → Operating System → **Use custom** →
   `jarvis-pi.img.xz` → your card. When it asks about OS customisation, choose **No** (`jarvis.txt` does that).
3. When it's done, take the card out and put it back in. A drive called **bootfs** appears. Open **jarvis.txt** in
   Notepad, fill in:
   - `WIFI_NAME` and `WIFI_PASSWORD`. Leave both empty if the Pi is on an Ethernet cable.
   - `HUB_ADDRESS`: your NAS's address — its 192.168.x.x address at home, or its Tailscale 100.x.x.x
     address if you're using Tailscale.
   - `HUB_KEY`: from TrueNAS → Apps → **jarvis-voice** → Logs, the part after `token=`.
   - `TAILSCALE_AUTHKEY` (optional): to put the Pi on your Tailscale network, paste an auth key from
     <https://login.tailscale.com/admin/settings/keys>. The Pi joins on first boot (as its `HOSTNAME`) and
     the key is then blanked. Leave empty to skip. Works on Pi 2/3/4/5 and Zero 2 W; the old Pi 1 / Zero
     can't run Tailscale, so use the local 192.168 address there.
   - `PASSWORD` (optional), if you want SSH logins as `jarvis@jarvis-pi.local`.

   Save it and eject the card.
4. Put the card in the Pi, plug in the Wi-Fi dongle (if you use one) and the USB speakerphone, and power it on.
   The first start takes a few minutes, because it expands to fill the card and restarts once. Then Jarvis says
   it's listening.

The Pi reads `jarvis.txt` every time it starts. To change the Wi-Fi or the NAS, edit the file and restart the Pi.
After a password or key has been used, it's replaced with `(saved)`, so it isn't left on the card.

## What's inside

- `files/jarvis-firstboot.sh`: runs early at every boot and applies `jarvis.txt`. It sets the Wi-Fi (through
  NetworkManager), the Wi-Fi country, the name, the hub address and key (`/etc/jarvis-voice.env`), and the login.
- `files/jarvis-audio.sh`: runs before Jarvis starts. It finds the USB speakerphone and makes it the default
  microphone and speaker.
- `files/jarvis-tailscale.sh`: runs after the network is up and before Jarvis. If `jarvis.txt` has a
  `TAILSCALE_AUTHKEY`, it joins your Tailscale network (as the Pi's `HOSTNAME`) and then blanks the key.
  Tailscale is pre-installed in the image, so no download is needed at first boot.
- `files/jarvis-update-client.sh`: runs before Jarvis starts. It fetches the newest speaker program from the NAS
  and keeps the built-in copy if the NAS can't be reached.
- `jarvis-voice.service`: the speaker itself. It is the same program the hub's set-up command installs, taken
  from `jarvis-voice/hub.py` at build time.
- `build.sh`: downloads the official image, checks its checksum, installs the sound tools in an emulated Pi,
  adds the above and compresses the result. GitHub Actions runs it, and it can also be run by hand on any
  Linux PC with root access.

No Wi-Fi password, hub key, Tailscale auth key or login is in the image itself — each is blanked on the card
once it has been used.
