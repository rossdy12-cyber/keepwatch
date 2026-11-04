"""Lumen AI upscaler: Real-ESRGAN on your TrueNAS, for the Lumen camera app.

Lumen sends a photo; this enlarges it 2x or 4x with Real-ESRGAN (an open-source AI model that rebuilds fine detail)
on the NAS's own processor, then Lumen downloads the result. Nothing goes anywhere else.

    POST /upscale?token=KEY&scale=2|4   body: JPEG/PNG bytes        -> {"job": "<id>"}
    GET  /jobs/<id>?token=KEY                                        -> {"status", "progress", "error", "width", "height"}
    GET  /jobs/<id>/result?token=KEY                                 -> JPEG
"""

import io
import json
import math
import os
import queue
import secrets
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageOps

DATA = os.environ.get("DATA_DIR", "/data")
PORT = int(os.environ.get("PORT", "10702"))
TILE = int(os.environ.get("TILE", "256"))
# Bigger photos are scaled down to this many megapixels first, so a job finishes in a few minutes on a CPU.
# Both give about a 16-megapixel result.
MAX_INPUT_MP = {2: float(os.environ.get("MAX_INPUT_MEGAPIXELS_2X", "4")), 4: float(os.environ.get("MAX_INPUT_MEGAPIXELS_4X", "1"))}
THREADS = int(os.environ.get("THREADS", "0")) or os.cpu_count() or 4
KEEP_RESULTS_MINUTES = 60

MODELS = {
    2: ("RealESRGAN_x2plus.pth", "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"),
    4: ("RealESRGAN_x4plus.pth", "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"),
}

torch.set_num_threads(THREADS)


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def load_token():
    token = os.environ.get("TOKEN", "").strip()
    if token:
        return token
    path = os.path.join(DATA, "token")
    if os.path.exists(path):
        return open(path).read().strip()
    os.makedirs(DATA, exist_ok=True)
    token = secrets.token_urlsafe(18)
    with open(path, "w") as handle:
        handle.write(token)
    return token


TOKEN = load_token()


# ------------------------------------------------------------------------------------------- Real-ESRGAN network
# The RRDBNet architecture from Real-ESRGAN / BasicSR (BSD-3-Clause), so only PyTorch is needed.

class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, scale, num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch *= 4
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        feat = F.pixel_unshuffle(x, 2) if self.scale == 2 else x
        feat = self.conv_first(feat)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


_models = {}
_model_lock = threading.Lock()


def get_model(scale):
    with _model_lock:
        if scale in _models:
            return _models[scale]
        name, url = MODELS[scale]
        folder = os.path.join(DATA, "models")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            log("Downloading the %dx model (first use only)" % scale)
            urllib.request.urlretrieve(url, path + ".part")
            os.replace(path + ".part", path)
        model = RRDBNet(scale)
        state = torch.load(path, map_location="cpu", weights_only=True)
        model.load_state_dict(state.get("params_ema", state.get("params", state)), strict=True)
        model.eval()
        _models[scale] = model
        return model


def upscale(image, scale, progress):
    """Real-ESRGAN in overlapping tiles (keeps memory low). progress(fraction) is called as tiles finish."""
    model = get_model(scale)
    array = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    tensor = torch.from_numpy(array).permute(2, 0, 1).unsqueeze(0)
    _, _, height, width = tensor.shape
    # The 2x model works on 2x2 blocks: pad to an even size.
    pad_h, pad_w = height % 2, width % 2
    if pad_h or pad_w:
        tensor = F.pad(tensor, (0, pad_w, 0, pad_h), mode="reflect")
    _, _, height_p, width_p = tensor.shape
    output = torch.zeros((1, 3, height_p * scale, width_p * scale))
    overlap = 12
    tiles_x, tiles_y = math.ceil(width_p / TILE), math.ceil(height_p / TILE)
    total, done = tiles_x * tiles_y, 0
    with torch.inference_mode():
        for ty in range(tiles_y):
            for tx in range(tiles_x):
                x0, y0 = tx * TILE, ty * TILE
                x1, y1 = min(x0 + TILE, width_p), min(y0 + TILE, height_p)
                px0, py0 = max(x0 - overlap, 0), max(y0 - overlap, 0)
                px1, py1 = min(x1 + overlap, width_p), min(y1 + overlap, height_p)
                # Even offsets and sizes for the 2x model.
                px0, py0 = px0 - px0 % 2, py0 - py0 % 2
                px1 = min(px1 + (px1 - px0) % 2, width_p)
                py1 = min(py1 + (py1 - py0) % 2, height_p)
                result = model(tensor[:, :, py0:py1, px0:px1])
                ox0, oy0 = (x0 - px0) * scale, (y0 - py0) * scale
                ox1, oy1 = ox0 + (x1 - x0) * scale, oy0 + (y1 - y0) * scale
                output[:, :, y0 * scale:y1 * scale, x0 * scale:x1 * scale] = result[:, :, oy0:oy1, ox0:ox1]
                done += 1
                progress(done / total)
    output = output[:, :, :height * scale, :width * scale].clamp(0, 1)
    pixels = (output.squeeze(0).permute(1, 2, 0).numpy() * 255.0).round().astype(np.uint8)
    return Image.fromarray(pixels)


# ------------------------------------------------------------------------------------------- jobs

jobs = {}
jobs_lock = threading.Lock()
work = queue.Queue()


def worker():
    while True:
        job_id = work.get()
        with jobs_lock:
            job = jobs.get(job_id)
        if not job:
            continue
        job["status"] = "working"
        started = time.time()
        try:
            image = ImageOps.exif_transpose(Image.open(io.BytesIO(job.pop("input"))))
            megapixels = image.width * image.height / 1e6
            limit = MAX_INPUT_MP[job["scale"]]
            if megapixels > limit:
                factor = math.sqrt(limit / megapixels)
                image = image.resize((int(image.width * factor), int(image.height * factor)), Image.LANCZOS)
            log("Job %s: %dx%d at %dx" % (job_id, image.width, image.height, job["scale"]))
            result = upscale(image, job["scale"], lambda fraction: job.__setitem__("progress", fraction))
            buffer = io.BytesIO()
            result.save(buffer, "JPEG", quality=94, subsampling=0)
            job.update(status="done", progress=1.0, result=buffer.getvalue(), width=result.width, height=result.height)
            log("Job %s done: %dx%d in %.0f s" % (job_id, result.width, result.height, time.time() - started))
        except Exception as error:
            job.update(status="error", error=str(error))
            log("Job %s failed: %s" % (job_id, error))
        job["finished"] = time.time()
        # Forget old results.
        with jobs_lock:
            for old_id in [i for i, j in jobs.items() if j.get("finished") and time.time() - j["finished"] > KEEP_RESULTS_MINUTES * 60]:
                jobs.pop(old_id, None)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self, query):
        token = (query.get("token") or [""])[0]
        return bool(token) and secrets.compare_digest(token, TOKEN)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path != "/upscale":
            return self.reply(404, {"error": "Not found"})
        if not self.authorised(query):
            return self.reply(403, {"error": "Wrong key"})
        scale = int((query.get("scale") or ["2"])[0])
        if scale not in MODELS:
            return self.reply(400, {"error": "Scale must be 2 or 4"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 80_000_000:
            return self.reply(413, {"error": "Send a photo under 80 MB"})
        data = self.rfile.read(length)
        job_id = secrets.token_hex(8)
        with jobs_lock:
            jobs[job_id] = {"status": "queued", "progress": 0.0, "scale": scale, "input": data}
        work.put(job_id)
        self.reply(200, {"job": job_id})

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/health":
            return self.reply(200, {"status": "ok"})
        if parsed.path == "/limits":
            return self.reply(200, {"maxInputMegapixels": {str(k): v for k, v in MAX_INPUT_MP.items()}})
        parts = [p for p in parsed.path.split("/") if p]
        if len(parts) < 2 or parts[0] != "jobs":
            return self.reply(404, {"error": "Not found"})
        if not self.authorised(query):
            return self.reply(403, {"error": "Wrong key"})
        with jobs_lock:
            job = jobs.get(parts[1])
        if not job:
            return self.reply(404, {"error": "No such job (results are kept for an hour)"})
        if len(parts) == 3 and parts[2] == "result":
            if job["status"] != "done":
                return self.reply(409, {"error": "Not finished yet"})
            return self.reply(200, job["result"], "image/jpeg")
        position = 0
        if job["status"] == "queued":
            with jobs_lock:
                waiting = [i for i, j in jobs.items() if j["status"] == "queued"]
            position = waiting.index(parts[1]) + 1 if parts[1] in waiting else 0
        self.reply(200, {"status": job["status"], "progress": round(job.get("progress", 0), 3),
                         "error": job.get("error"), "width": job.get("width"), "height": job.get("height"),
                         "queuePosition": position})


def main():
    threading.Thread(target=worker, daemon=True).start()
    log("Lumen AI upscaler ready on port %d (%d CPU threads)." % (PORT, THREADS))
    log("In Lumen: Settings > AI upscaling > address http://<NAS-IP>:%d, key %s" % (PORT, TOKEN))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
