# Lumen AI upscaler

Real-ESRGAN on your TrueNAS for the Lumen camera app. In Lumen's editor (AI tab → **Upscale 2×/4×**), the photo goes
to this app, gets enlarged with AI-rebuilt detail on the NAS's own processor, and comes back. Nothing goes to the internet.

In a test here, a photo shrunk to a quarter of its size and upscaled back came out much closer to the original than
plain resizing (29.7 dB vs 25.9 dB PSNR).

## Install
1. **TrueNAS → Apps → Discover Apps → ⋮ → Install via YAML.** Name it `lumen-ai` and paste [`compose.yaml`](compose.yaml).
2. The first start installs PyTorch (about 200 MB). The first job of each size downloads its model (about 65 MB).
3. **Logs** show the address and key. In Lumen's editor, go to **AI → Set up the upscaler** and enter them. Use
   `http://100.85.127.42:10702` over Tailscale, or the NAS's local IP at home.

## Add your PC's graphics card (GPU worker)

A PC with an NVIDIA card makes upscaling 10–20× faster and allows bigger photos (12 MP for 2×, 4 MP for 4×).
The PC only connects out to the NAS to collect jobs, so no ports are opened on it. When it's off or asleep, the NAS
carries on by itself, and Lumen shows which one is doing the work.

**Windows:** open **PowerShell** (no need for administrator) and paste the command from the lumen-ai **Logs**:

    irm "http://<NAS-IP>:10702/worker/setup.ps1?token=<key>" | iex

It installs Python 3.11 if needed, plus PyTorch for the graphics card (about 2.5 GB, once) and the worker. It then
starts the worker, hidden, now and every time you sign in. The log is in `%LOCALAPPDATA%\LumenWorker\worker.log`.
To remove it, run `Unregister-ScheduledTask 'Lumen GPU worker'` and delete that folder.

**Linux** (e.g. Bazzite): `curl -sSL 'http://<NAS-IP>:10702/worker/setup.sh?token=<key>' | bash`. It runs as a
user service; the log is in `~/.local/share/lumen-worker/worker.log`.

Older cards are fine. It uses PyTorch 2.5.1 with CUDA 12.1, which still supports the GTX 900 series. On cards with
little memory it automatically uses smaller tiles. The NVIDIA driver needs to be reasonably recent.

If the worker stops responding in the middle of a job, the NAS takes the job back after 90 seconds and finishes it.

## Speed
Without a GPU worker it runs on the NAS's processor, so expect a few minutes per photo. Bigger photos are shrunk first:
up to 4 MP for 2× and 1 MP for 4×, both giving about a 16 MP result. If your NAS is quick, raise
`MAX_INPUT_MEGAPIXELS_2X` / `MAX_INPUT_MEGAPIXELS_4X` in the YAML. Jobs run one at a time and results are kept for an hour.

`compose.yaml` is generated: edit `upscaler.py`, then run `python3 build_compose.py`.
