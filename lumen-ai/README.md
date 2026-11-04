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

## Speed
It runs on the processor, not a graphics card, so expect a few minutes per photo. Bigger photos are shrunk first:
up to 4 MP for 2× and 1 MP for 4×, both giving about a 16 MP result. If your NAS is quick, raise
`MAX_INPUT_MEGAPIXELS_2X` / `MAX_INPUT_MEGAPIXELS_4X` in the YAML. Jobs run one at a time and results are kept for an hour.

`compose.yaml` is generated: edit `upscaler.py`, then run `python3 build_compose.py`.
