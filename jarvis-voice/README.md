# Jarvis voice: "Hey Jarvis" on a Raspberry Pi

Turns a Raspberry Pi (even a Pi 1 B+) with a USB speakerphone into a "Hey Jarvis" speaker. The Pi only streams
its microphone to your NAS and plays what comes back. The NAS does everything else:

- **Wake word:** openWakeWord, with its "Hey Jarvis" model.
- **Speech to text:** Whisper.
- **Answers:** your Jarvis core.
- **The voice:** the core's own recording when it sends one, otherwise Piper's British "Alan" voice.

Say **"Hey Jarvis"** and wait for the beep. Ask your question, and Jarvis answers through the speaker. A low double
beep means it didn't catch anything. There's no time limit on answers, unlike Alexa.

Tested here end to end with recorded speech: the wake word was detected, "What time is it?" was transcribed, the
Jarvis core answered, and the spoken reply played on a simulated Pi. Not yet tried on real hardware.

## What you need

- A Raspberry Pi (a Pi 1 B+ is fine), its microSD card and a good 2.5 A power supply.
- A USB Wi-Fi dongle (or Ethernet).
- A **USB speakerphone** such as a Jabra Speak 410/510: microphone and speaker in one, with echo cancelling.
  Or a ReSpeaker USB Mic Array v2.0 with a small powered speaker plugged into *its* 3.5 mm socket.

## 1. Install the hub on TrueNAS

1. **Apps → Discover Apps → ⋮ → Install via YAML**. Name it `jarvis-voice` and paste [`compose.yaml`](compose.yaml). Save.
2. The first start takes a few minutes: it installs the speech tools and downloads the models (about 400 MB, kept
   for next time).
3. Open **Apps → jarvis-voice → Logs**. When it says *"Jarvis voice hub ready"*, it shows the command for the Pi:
   `curl -sSL 'http://<NAS-IP>:10701/pi/setup.sh?token=…' | sudo bash`

`JARVIS_URL` points at the Jarvis core on your network (`http://100.85.127.42:8998`). If the logs show
*"Jarvis core error"*, change it to your NAS's local IP with port 8998, or to `https://jarvis.nas-server.co.uk`.

## 2. Prepare the Pi

1. On your PC, install **Raspberry Pi Imager** (<https://www.raspberrypi.com/software/>).
   - Device: **Raspberry Pi 1**. OS: **Raspberry Pi OS (other) → Raspberry Pi OS Lite (32-bit)**.
   - When it asks about **OS customisation**, choose **Edit settings**:
     - **General tab:** hostname `jarvis-pi`, a username and password, your **Wi-Fi name and password**, and
       Wi-Fi country **GB**.
     - **Services tab:** tick **Enable SSH**.
   - Write the card.
2. Put the card in the Pi. Plug in the Wi-Fi dongle and the speakerphone, then power it on. Give it a few minutes
   the first time.
3. From your PC, connect: `ssh <username>@jarvis-pi.local` (in Windows Terminal or PowerShell).
4. Paste the command from the hub's logs, **replacing `<NAS-IP>` with your NAS's local IP address**. That's the
   `192.168.x.x` address on the TrueNAS dashboard's Network card; the Pi doesn't use Tailscale.
5. You'll hear **"Jarvis is listening."** Say **"Hey Jarvis"**.

The Pi starts listening by itself every time it's powered on.

## Fine-tuning (Apps → jarvis-voice → Edit)

| Setting | What it does |
|---|---|
| `WAKE_THRESHOLD` | Lower (e.g. `0.35`) if it doesn't hear "Hey Jarvis" from across the room; higher (`0.7`) if it wakes by itself. |
| `FOLLOW_UP_SECONDS` | e.g. `5`: after an answer, keep listening for 5 s so you can ask a follow-up without "Hey Jarvis". |
| `WHISPER_MODEL` | `small.en` understands more (accents, background noise) but is slower. |
| `USE_CORE_VOICE` | `false` to always use the Piper voice. |
| `GREETING` | What it says when the Pi connects. Empty for silence. |

## Troubleshooting

- **On the Pi:** `journalctl -u jarvis-voice -f` shows the connection. `arecord -l` and `aplay -l` list the sound
  devices. To test the microphone, run `arecord -d 3 test.wav && aplay test.wav`.
- **In the hub's logs:** each "Wake word heard", what it understood ("Heard: …") and Jarvis's answer.
- **"Refused a connection (wrong key)":** run the setup command from the current logs again.
- **Quiet or loud:** on the Pi, run `alsamixer`, press F6 and pick the USB device.

`compose.yaml` is generated: edit `hub.py`, then run `python3 build_compose.py`.
