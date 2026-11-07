"""Lumen AI upscaler: Real-ESRGAN on your TrueNAS, for the Lumen camera app.

Lumen sends a photo; this enlarges it 2x or 4x with Real-ESRGAN (an open-source AI model that rebuilds fine detail),
then Lumen downloads the result. Nothing goes anywhere else.

A PC with an NVIDIA graphics card can join as a GPU worker: it collects jobs from here (it only connects out, so no
ports are opened on the PC), runs them on its GPU and sends the results back. While a worker is online it gets the
jobs, with bigger size limits; otherwise the NAS's own processor does them. The set-up command is in the logs.

    POST /upscale?token=KEY&scale=2|4   body: JPEG/PNG bytes        -> {"job": "<id>"}
    GET  /jobs/<id>?token=KEY                                        -> {"status", "progress", "error", "width", "height"}
    GET  /jobs/<id>/result?token=KEY                                 -> JPEG
    POST /backup?token=KEY&name=FILE    body: an original photo/video -> saved in BACKUP_DIR/<yyyy-mm>/FILE
"""

import io
import json
import math
import os
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
# Lumen's "Back up originals to my NAS" files land here, in a folder per month.
BACKUP_DIR = os.environ.get("BACKUP_DIR", os.path.join(DATA, "backup"))
MAX_BACKUP_BYTES = int(float(os.environ.get("MAX_BACKUP_GB", "8")) * 1_000_000_000)
TILE = int(os.environ.get("TILE", "256"))
# Bigger photos are scaled down to this many megapixels first, so a job finishes in a few minutes on a CPU.
# Both give about a 16-megapixel result.
MAX_INPUT_MP = {2: float(os.environ.get("MAX_INPUT_MEGAPIXELS_2X", "4")), 4: float(os.environ.get("MAX_INPUT_MEGAPIXELS_4X", "1"))}
# A GPU worker can take much bigger photos.
GPU_MAX_INPUT_MP = {2: float(os.environ.get("GPU_MAX_INPUT_MEGAPIXELS_2X", "12")),
                    4: float(os.environ.get("GPU_MAX_INPUT_MEGAPIXELS_4X", "4"))}
# A worker counts as online if it asked for work this recently (seconds).
WORKER_TIMEOUT = 45
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


def get_model(scale, device="cpu"):
    with _model_lock:
        if (scale, device) in _models:
            return _models[(scale, device)]
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
        model.to(device)
        _models[(scale, device)] = model
        return model


def upscale(image, scale, progress, device="cpu", tile=None):
    """Real-ESRGAN in overlapping tiles (keeps memory low). progress(fraction) is called as tiles finish.
    device: "cpu" or "cuda". tile: tile size in pixels (smaller uses less graphics memory)."""
    model = get_model(scale, device)
    tile_size = tile or TILE
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
    tiles_x, tiles_y = math.ceil(width_p / tile_size), math.ceil(height_p / tile_size)
    total, done = tiles_x * tiles_y, 0
    with torch.inference_mode():
        for ty in range(tiles_y):
            for tx in range(tiles_x):
                x0, y0 = tx * tile_size, ty * tile_size
                x1, y1 = min(x0 + tile_size, width_p), min(y0 + tile_size, height_p)
                px0, py0 = max(x0 - overlap, 0), max(y0 - overlap, 0)
                px1, py1 = min(x1 + overlap, width_p), min(y1 + overlap, height_p)
                # Even offsets and sizes for the 2x model.
                px0, py0 = px0 - px0 % 2, py0 - py0 % 2
                px1 = min(px1 + (px1 - px0) % 2, width_p)
                py1 = min(py1 + (py1 - py0) % 2, height_p)
                result = model(tensor[:, :, py0:py1, px0:px1].to(device)).cpu()
                ox0, oy0 = (x0 - px0) * scale, (y0 - py0) * scale
                ox1, oy1 = ox0 + (x1 - x0) * scale, oy0 + (y1 - y0) * scale
                output[:, :, y0 * scale:y1 * scale, x0 * scale:x1 * scale] = result[:, :, oy0:oy1, ox0:ox1]
                done += 1
                progress(done / total)
    output = output[:, :, :height * scale, :width * scale].clamp(0, 1)
    pixels = (output.squeeze(0).permute(1, 2, 0).numpy() * 255.0).round().astype(np.uint8)
    return Image.fromarray(pixels)


# ------------------------------------------------------------------------------------------- jobs

jobs = {}  # id -> job; insertion order is queue order
jobs_lock = threading.Lock()
workers = {}  # name -> {"last_seen", "device"}


def gpu_worker_online():
    now = time.time()
    with jobs_lock:
        return any(now - w["last_seen"] < WORKER_TIMEOUT for w in workers.values())


def limits():
    return GPU_MAX_INPUT_MP if gpu_worker_online() else MAX_INPUT_MP


def shrink(image, limit):
    megapixels = image.width * image.height / 1e6
    if megapixels > limit:
        factor = math.sqrt(limit / megapixels)
        image = image.resize((int(image.width * factor), int(image.height * factor)), Image.LANCZOS)
    return image

# ---------------------------------------------------------------------------------------------- inpainting

# How big a photo object-removal works on (bigger ones are shrunk first).
INPAINT_MAX_MP = {"cpu": float(os.environ.get("INPAINT_MAX_MEGAPIXELS", "6")),
                  "gpu": float(os.environ.get("GPU_INPAINT_MAX_MEGAPIXELS", "16"))}
_LAMA = None
_LAMA_FAILED = False


def get_lama(device):
    """Loads the LaMa inpainting model once; returns None if it isn't installed (then OpenCV is used)."""
    global _LAMA, _LAMA_FAILED
    if _LAMA is not None or _LAMA_FAILED:
        return _LAMA
    try:
        from simple_lama_inpainting import SimpleLama
        _LAMA = SimpleLama(device=torch.device(device))
        log("LaMa inpainting ready on %s" % device)
    except Exception as error:
        _LAMA_FAILED = True
        log("LaMa not available (%s); using OpenCV inpainting instead" % error)
    return _LAMA


def _split_inpaint(blob):
    if len(blob) < 4:
        raise ValueError("inpaint request too short")
    length = int.from_bytes(blob[:4], "big")
    if length <= 0 or 4 + length > len(blob):
        raise ValueError("bad inpaint framing")
    return blob[4:4 + length], blob[4 + length:]


def run_inpaint(blob, device="cpu", progress=None):
    """blob = 4-byte image length, image JPEG, mask PNG (white = remove). Returns a JPEG of the cleaned photo."""
    image_bytes, mask_bytes = _split_inpaint(blob)
    image = ImageOps.exif_transpose(Image.open(io.BytesIO(image_bytes))).convert("RGB")
    image = shrink(image, INPAINT_MAX_MP["gpu" if device != "cpu" else "cpu"])
    mask = Image.open(io.BytesIO(mask_bytes)).convert("L")
    if mask.size != image.size:
        mask = mask.resize(image.size, Image.NEAREST)
    if progress:
        progress(0.1)
    lama = get_lama(device)
    if lama is not None:
        result = lama(image, mask)
        if not isinstance(result, Image.Image):
            import numpy as np
            result = Image.fromarray(np.asarray(result))
        result = result.convert("RGB")
    else:
        import numpy as np
        import cv2
        bgr = np.array(image)[:, :, ::-1].copy()
        binary = (np.array(mask) > 127).astype(np.uint8) * 255
        binary = cv2.dilate(binary, np.ones((5, 5), np.uint8), iterations=2)
        filled = cv2.inpaint(bgr, binary, 6, cv2.INPAINT_TELEA)
        result = Image.fromarray(filled[:, :, ::-1])
    if progress:
        progress(0.95)
    buffer = io.BytesIO()
    result.save(buffer, "JPEG", quality=95, subsampling=0)
    return buffer.getvalue()


# ---------------------------------------------------------------------------------------------- panorama

def _split_pano(blob):
    """blob = 4-byte frame count, then for each frame a 4-byte length followed by its JPEG."""
    if len(blob) < 4:
        raise ValueError("panorama request too short")
    count = int.from_bytes(blob[:4], "big")
    offset = 4
    frames = []
    for _ in range(count):
        if offset + 4 > len(blob):
            raise ValueError("bad panorama framing")
        length = int.from_bytes(blob[offset:offset + 4], "big")
        offset += 4
        if length <= 0 or offset + length > len(blob):
            raise ValueError("bad panorama framing")
        frames.append(blob[offset:offset + length])
        offset += length
    if len(frames) < 2:
        raise ValueError("need at least two frames to stitch a panorama")
    return frames


def run_pano(blob, progress=None):
    """Stitches the captured frames into one wide photo with OpenCV. Returns a JPEG."""
    import numpy as np
    import cv2
    frames = _split_pano(blob)
    images = []
    for frame_bytes in frames:
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(frame_bytes))).convert("RGB")
        images.append(np.array(image)[:, :, ::-1].copy())  # RGB -> BGR for OpenCV
    if progress:
        progress(0.2)
    stitcher = cv2.Stitcher_create(cv2.Stitcher_PANORAMA)
    status, pano = stitcher.stitch(images)
    if status != cv2.Stitcher_OK:
        raise ValueError("Couldn't stitch these frames (code %d). Try panning more slowly with more overlap." % status)
    if progress:
        progress(0.9)
    result = Image.fromarray(pano[:, :, ::-1])  # BGR -> RGB
    buffer = io.BytesIO()
    result.save(buffer, "JPEG", quality=92, subsampling=0)
    return buffer.getvalue()


def requeue_stale():
    """A GPU worker that went quiet mid-job: hand its job back (to the NAS processor)."""
    now = time.time()
    with jobs_lock:
        for job in jobs.values():
            if job["status"] == "working" and job.get("lease_until") and now > job["lease_until"]:
                log("A worker stopped responding; the NAS will finish job %s itself" % job["id"])
                job.update(status="queued", processor=None, lease_until=None, cpu_only=True, progress=0.0)


def take_job(for_gpu, worker_name=""):
    """The oldest waiting job, marked as taken."""
    with jobs_lock:
        for job in jobs.values():
            if job["status"] != "queued":
                continue
            if for_gpu and job.get("cpu_only"):
                continue
            job["status"] = "working"
            job["processor"] = ("GPU (%s)" % worker_name) if for_gpu else "NAS processor"
            job["lease_until"] = time.time() + 90 if for_gpu else None
            return job
    return None


def finish(job, jpeg):
    width, height = Image.open(io.BytesIO(jpeg)).size
    job.update(status="done", progress=1.0, result=jpeg, width=width, height=height, finished=time.time(), lease_until=None)
    job.pop("input", None)
    log("Job %s done on %s: %dx%d in %.0f s" % (job["id"], job["processor"], width, height, time.time() - job["created"]))


def cpu_worker():
    """The NAS's own processor: takes jobs when no GPU worker is online (or one gave up on a job)."""
    while True:
        time.sleep(0.5)
        requeue_stale()
        with jobs_lock:
            waiting = [j for j in jobs.values() if j["status"] == "queued"]
            # Old results are forgotten after an hour.
            for old_id in [i for i, j in jobs.items() if j.get("finished") and time.time() - j["finished"] > KEEP_RESULTS_MINUTES * 60]:
                jobs.pop(old_id, None)
        if not waiting:
            continue
        # Leave jobs to an online GPU worker, unless one has waited a while (the worker may be busy or stuck).
        if gpu_worker_online() and not any(j.get("cpu_only") or time.time() - j["created"] > 120 for j in waiting):
            continue
        job = take_job(for_gpu=False)
        if not job:
            continue
        try:
            if job.get("kind") == "inpaint":
                log("Job %s: removing objects on the NAS processor" % job["id"])
                result = run_inpaint(job["input"], "cpu", lambda fraction: job.__setitem__("progress", fraction))
                finish(job, result)
                continue
            if job.get("kind") == "pano":
                log("Job %s: stitching a panorama on the NAS processor" % job["id"])
                result = run_pano(job["input"], lambda fraction: job.__setitem__("progress", fraction))
                finish(job, result)
                continue
            image = shrink(ImageOps.exif_transpose(Image.open(io.BytesIO(job["input"]))), MAX_INPUT_MP[job["scale"]])
            log("Job %s: %dx%d at %dx on the NAS processor" % (job["id"], image.width, image.height, job["scale"]))
            result = upscale(image, job["scale"], lambda fraction: job.__setitem__("progress", fraction))
            buffer = io.BytesIO()
            result.save(buffer, "JPEG", quality=94, subsampling=0)
            finish(job, buffer.getvalue())
        except Exception as error:
            job.update(status="error", error=str(error), finished=time.time())
            log("Job %s failed: %s" % (job["id"], error))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, status, body=b"", content_type="application/json", headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self, query):
        token = (query.get("token") or [""])[0]
        return bool(token) and secrets.compare_digest(token, TOKEN)

    def body(self, limit=200_000_000):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > limit:
            return None
        return self.rfile.read(length)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = [p for p in parsed.path.split("/") if p]
        if not self.authorised(query):
            return self.reply(403, {"error": "Wrong key"})
        if parts == ["backup"]:
            return self.backup(query)
        if parts == ["upscale"]:
            scale = int((query.get("scale") or ["2"])[0])
            if scale not in MODELS:
                return self.reply(400, {"error": "Scale must be 2 or 4"})
            data = self.body(80_000_000)
            if not data:
                return self.reply(413, {"error": "Send a photo under 80 MB"})
            job_id = secrets.token_hex(8)
            with jobs_lock:
                jobs[job_id] = {"id": job_id, "status": "queued", "progress": 0.0, "scale": scale, "input": data,
                                "created": time.time()}
            return self.reply(200, {"job": job_id})
        if parts == ["inpaint"]:
            data = self.body(120_000_000)
            if not data:
                return self.reply(413, {"error": "Send the photo and mask (under 120 MB)"})
            job_id = secrets.token_hex(8)
            with jobs_lock:
                jobs[job_id] = {"id": job_id, "status": "queued", "progress": 0.0, "kind": "inpaint",
                                "input": data, "created": time.time()}
            return self.reply(200, {"job": job_id})
        if parts == ["pano"]:
            data = self.body(200_000_000)
            if not data:
                return self.reply(413, {"error": "Send the panorama frames (under 200 MB)"})
            job_id = secrets.token_hex(8)
            with jobs_lock:
                # Stitching runs on the NAS itself (no GPU benefit), so mark it cpu_only.
                jobs[job_id] = {"id": job_id, "status": "queued", "progress": 0.0, "kind": "pano",
                                "cpu_only": True, "input": data, "created": time.time()}
            return self.reply(200, {"job": job_id})
        # The GPU worker reporting back: /worker/progress/<id>, /worker/result/<id>, /worker/fail/<id>
        if len(parts) == 3 and parts[0] == "worker":
            data = self.body() or b""
            with jobs_lock:
                job = jobs.get(parts[2])
            if not job or job["status"] != "working":
                return self.reply(410, {"error": "That job is no longer yours"})
            if parts[1] == "progress":
                job["progress"] = float((query.get("progress") or ["0"])[0])
                job["lease_until"] = time.time() + 90
                return self.reply(200, {"ok": True})
            if parts[1] == "result":
                try:
                    finish(job, data)
                except Exception as error:
                    return self.reply(400, {"error": "Not a valid photo: %s" % error})
                return self.reply(200, {"ok": True})
            if parts[1] == "fail":
                log("The GPU worker couldn't do job %s (%s); the NAS will do it" % (job["id"], data.decode("utf-8", "replace")[:200]))
                job.update(status="queued", processor=None, lease_until=None, cpu_only=True, progress=0.0)
                return self.reply(200, {"ok": True})
        self.reply(404, {"error": "Not found"})

    def backup(self, query):
        """Streams one file from Lumen to the backup folder (written as .part, then renamed, so a cut-off upload never
        looks finished). Sending the same file again is fine: it's replaced."""
        name = os.path.basename((query.get("name") or [""])[0]).strip()
        length = int(self.headers.get("Content-Length") or 0)
        if not name or name.startswith(".") or length <= 0:
            return self.reply(400, {"error": "Send a file with ?name="})
        if length > MAX_BACKUP_BYTES:
            return self.reply(413, {"error": "That file is bigger than MAX_BACKUP_GB"})
        month = name[:7] if len(name) >= 7 and name[4] == "-" else "other"
        folder = os.path.join(BACKUP_DIR, month)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        part = path + ".part"
        remaining = length
        try:
            with open(part, "wb") as handle:
                while remaining > 0:
                    chunk = self.rfile.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    handle.write(chunk)
                    remaining -= len(chunk)
        except OSError as error:
            return self.reply(500, {"error": "Couldn't write the file: %s" % error})
        if remaining:
            try:
                os.remove(part)
            except OSError:
                pass
            return self.reply(400, {"error": "The upload was cut off"})
        os.replace(part, path)
        log("Backed up %s (%.1f MB)" % (name, length / 1e6))
        return self.reply(200, {"ok": True, "saved": os.path.join(month, name)})

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = [p for p in parsed.path.split("/") if p]
        if parsed.path == "/health":
            return self.reply(200, {"status": "ok"})
        if parsed.path == "/limits":
            current = limits()
            return self.reply(200, {"maxInputMegapixels": {str(k): v for k, v in current.items()},
                                    "gpuWorker": gpu_worker_online()})
        if not self.authorised(query):
            return self.reply(403, {"error": "Wrong key"})
        if parts and parts[0] == "worker":
            return self.worker_get(parts, query)
        if len(parts) < 2 or parts[0] != "jobs":
            return self.reply(404, {"error": "Not found"})
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
                         "queuePosition": position, "processor": job.get("processor")})

    def worker_get(self, parts, query):
        """The GPU worker: collecting work, and its own set-up files."""
        hub = "http://%s" % (self.headers.get("Host") or "localhost:%d" % PORT)
        if parts == ["worker", "claim"]:
            name = ((query.get("name") or ["PC"])[0])[:40]
            device = ((query.get("device") or ["GPU"])[0])[:60]
            # Wait up to 20 s for a job, so the worker isn't constantly asking.
            deadline = time.time() + 20
            while True:
                with jobs_lock:
                    if name not in workers or time.time() - workers[name]["last_seen"] > WORKER_TIMEOUT:
                        log("GPU worker online: %s (%s)" % (name, device))
                    workers[name] = {"last_seen": time.time(), "device": device}
                job = take_job(for_gpu=True, worker_name=name)
                if job:
                    log("Job %s: sent to %s" % (job["id"], name))
                    headers = {"X-Job": job["id"], "X-Kind": job.get("kind", "upscale")}
                    if job.get("kind", "upscale") == "upscale":
                        headers["X-Scale"] = job["scale"]
                        headers["X-Max-Megapixels"] = GPU_MAX_INPUT_MP[job["scale"]]
                    return self.reply(200, job["input"], "application/octet-stream", headers)
                if time.time() > deadline:
                    return self.reply(204)
                time.sleep(0.5)
        files = {"upscaler.py": (open(os.path.abspath(__file__), "rb").read(), "text/x-python"),
                 "worker.py": (WORKER_SCRIPT.encode(), "text/x-python"),
                 "setup.ps1": (SETUP_PS1.replace("__HUB__", hub).replace("__TOKEN__", TOKEN).encode(), "text/plain"),
                 "setup.sh": (SETUP_SH.replace("__HUB__", hub).replace("__TOKEN__", TOKEN).encode(), "text/x-shellscript")}
        if len(parts) == 2 and parts[1] in files:
            data, kind = files[parts[1]]
            return self.reply(200, data, kind)
        self.reply(404, {"error": "Not found"})


# ------------------------------------------------------------------------------------------- the PC worker

WORKER_SCRIPT = r'''"""Lumen GPU worker: collects upscaling jobs from the lumen-ai app on your NAS and runs them on this PC's graphics card."""
import io, json, os, socket, sys, time, traceback, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = json.load(open(os.path.join(HERE, "config.json"), encoding="utf-8-sig"))
HUB, KEY = CONFIG["hub"].rstrip("/"), CONFIG["token"]
NAME = CONFIG.get("name") or socket.gethostname()

# Running hidden in the background: what happens goes to worker.log.
if os.environ.get("LUMEN_WORKER_CONSOLE") != "1":
    log_file = open(os.path.join(HERE, "worker.log"), "a", buffering=1, encoding="utf-8")
    sys.stdout = sys.stderr = log_file


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


# The upscaling code is shared with the NAS (upscaler.py next to this file). Point its storage at this folder.
os.environ["DATA_DIR"] = HERE
os.environ["TOKEN"] = "worker"
sys.path.insert(0, HERE)
import torch
import upscaler as core
from PIL import Image, ImageOps

DEVICE = "cuda" if torch.cuda.is_available() and os.environ.get("LUMEN_DEVICE", "") != "cpu" else "cpu"
DEVICE_NAME = torch.cuda.get_device_name(0) if DEVICE == "cuda" else "CPU"
log("Lumen GPU worker starting on %s, NAS %s" % (DEVICE_NAME, HUB))


def url(path, **params):
    params["token"] = KEY
    return "%s%s?%s" % (HUB, path, urllib.parse.urlencode(params))


def post(path, data=b"", **params):
    request = urllib.request.Request(url(path, **params), data=data, method="POST",
                                     headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def run(job, scale, limit, data):
    image = core.shrink(ImageOps.exif_transpose(Image.open(io.BytesIO(data))), limit)
    log("Job %s: %dx%d at %dx" % (job, image.width, image.height, scale))
    started, last = time.time(), [0.0]

    def progress(fraction):
        if time.time() - last[0] > 1:
            last[0] = time.time()
            try:
                post("/worker/progress/" + job, progress="%.3f" % fraction)
            except Exception:
                pass

    tile = 256
    while True:
        try:
            result = core.upscale(image, scale, progress, device=DEVICE, tile=tile)
            break
        except torch.cuda.OutOfMemoryError:
            torch.cuda.empty_cache()
            tile //= 2
            if tile < 64:
                raise
            log("Not enough graphics memory: trying smaller tiles (%d px)" % tile)
    buffer = io.BytesIO()
    result.save(buffer, "JPEG", quality=94, subsampling=0)
    post("/worker/result/" + job, buffer.getvalue())
    log("Job %s done: %dx%d in %.0f s" % (job, result.width, result.height, time.time() - started))


def run_inpaint(job, data):
    log("Job %s: removing objects" % job)
    started, last = time.time(), [0.0]

    def progress(fraction):
        if time.time() - last[0] > 1:
            last[0] = time.time()
            try:
                post("/worker/progress/" + job, progress="%.3f" % fraction)
            except Exception:
                pass

    result = core.run_inpaint(data, DEVICE, progress)
    post("/worker/result/" + job, result)
    log("Job %s done in %.0f s" % (job, time.time() - started))


while True:
    try:
        with urllib.request.urlopen(url("/worker/claim", name=NAME, device=DEVICE_NAME), timeout=40) as response:
            if response.status == 204:
                continue
            job = response.headers["X-Job"]
            kind = response.headers.get("X-Kind", "upscale")
            scale = int(response.headers["X-Scale"]) if kind != "inpaint" else 0
            limit = float(response.headers.get("X-Max-Megapixels") or 12)
            data = response.read()
        try:
            if kind == "inpaint":
                run_inpaint(job, data)
            else:
                run(job, scale, limit, data)
        except Exception as error:
            log("Job %s failed: %s" % (job, error))
            traceback.print_exc()
            try:
                post("/worker/fail/" + job, str(error).encode("utf-8"))
            except Exception:
                pass
    except (urllib.error.URLError, OSError) as error:
        log("Can't reach the NAS (%s); trying again in 15 s" % error)
        time.sleep(15)
    except Exception:
        traceback.print_exc()
        time.sleep(5)
'''

SETUP_PS1 = r'''# Lumen GPU worker for Windows. In PowerShell:  irm "<link from the lumen-ai logs>" | iex
$ErrorActionPreference = "Stop"
$Hub = "__HUB__"
$Key = "__TOKEN__"
$Dir = Join-Path $env:LOCALAPPDATA "LumenWorker"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

Write-Host "== Finding Python 3.11"
$Python = Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"
if (-not (Test-Path $Python)) {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try { $found = & py -3.11 -c "import sys; print(sys.executable)" 2>$null; if ($found) { $Python = $found.Trim() } } catch {}
    }
}
if (-not (Test-Path $Python)) {
    Write-Host "   Installing Python 3.11 with winget"
    winget install -e --id Python.Python.3.11 --scope user --accept-source-agreements --accept-package-agreements | Out-Null
    $Python = Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"
}
if (-not (Test-Path $Python)) { throw "Python 3.11 wasn't found. Install it from python.org, then run this again." }

Write-Host "== Setting up PyTorch for the graphics card (about 2.5 GB, first time only)"
if (-not (Test-Path "$Dir\venv\Scripts\python.exe")) { & $Python -m venv "$Dir\venv" }
$VenvPython = "$Dir\venv\Scripts\python.exe"
& $VenvPython -m pip install --quiet --upgrade pip
# PyTorch 2.5.1 with CUDA 12.1 still supports older cards such as the GTX 900 series.
& $VenvPython -m pip install --quiet "torch==2.5.1" --index-url https://download.pytorch.org/whl/cu121
& $VenvPython -m pip install --quiet numpy pillow
& $VenvPython -m pip install --quiet opencv-python-headless simple-lama-inpainting   # object removal (optional)

Write-Host "== Downloading the worker from the NAS"
Invoke-WebRequest "$Hub/worker/upscaler.py?token=$Key" -OutFile "$Dir\upscaler.py" -UseBasicParsing
Invoke-WebRequest "$Hub/worker/worker.py?token=$Key" -OutFile "$Dir\worker.py" -UseBasicParsing
@{ hub = $Hub; token = $Key; name = $env:COMPUTERNAME } | ConvertTo-Json | Set-Content -Encoding UTF8 "$Dir\config.json"

& $VenvPython -c "import torch; print('   Graphics card:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NOT FOUND - update the NVIDIA driver; until then jobs use the CPU')"

Write-Host "== Starting it now and whenever you sign in"
$Action = New-ScheduledTaskAction -Execute "$Dir\venv\Scripts\pythonw.exe" -Argument ('"' + "$Dir\worker.py" + '"') -WorkingDirectory $Dir
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "Lumen GPU worker" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
Stop-ScheduledTask -TaskName "Lumen GPU worker" -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName "Lumen GPU worker"
Write-Host ""
Write-Host "Done. The worker runs in the background. Its log: $Dir\worker.log"
Write-Host "To remove it: Unregister-ScheduledTask 'Lumen GPU worker' -Confirm:`$false; then delete $Dir"
'''

SETUP_SH = r'''#!/bin/bash
# Lumen GPU worker for Linux (e.g. Bazzite). Run:  curl -sSL '<link from the lumen-ai logs>' | bash
set -e
HUB="__HUB__"
KEY="__TOKEN__"
DIR="$HOME/.local/share/lumen-worker"
mkdir -p "$DIR"
PY=$(command -v python3.11 || command -v python3)
echo "== Setting up PyTorch for the graphics card (about 2.5 GB, first time only)"
[ -x "$DIR/venv/bin/python" ] || "$PY" -m venv "$DIR/venv"
"$DIR/venv/bin/pip" install --quiet --upgrade pip
"$DIR/venv/bin/pip" install --quiet "torch==2.5.1" --index-url https://download.pytorch.org/whl/cu121
"$DIR/venv/bin/pip" install --quiet numpy pillow
"$DIR/venv/bin/pip" install --quiet opencv-python-headless simple-lama-inpainting || true   # object removal (optional)
curl -sSL "$HUB/worker/upscaler.py?token=$KEY" -o "$DIR/upscaler.py"
curl -sSL "$HUB/worker/worker.py?token=$KEY" -o "$DIR/worker.py"
printf '{"hub": "%s", "token": "%s", "name": "%s"}\n' "$HUB" "$KEY" "$(hostname)" > "$DIR/config.json"
mkdir -p "$HOME/.config/systemd/user"
printf '[Unit]\nDescription=Lumen GPU worker\nAfter=network-online.target\n\n[Service]\nExecStart=%s/venv/bin/python %s/worker.py\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n' "$DIR" "$DIR" > "$HOME/.config/systemd/user/lumen-worker.service"
systemctl --user daemon-reload
systemctl --user enable --now lumen-worker.service
echo "Done. Log: $DIR/worker.log"
'''


def main():
    threading.Thread(target=cpu_worker, daemon=True).start()
    log("Lumen AI upscaler ready on port %d (%d CPU threads)." % (PORT, THREADS))
    log("In Lumen: AI tab > Set up the upscaler > address http://<NAS-IP>:%d, key %s" % (PORT, TOKEN))
    log("GPU worker on a Windows PC, in PowerShell:  irm \"http://<NAS-IP>:%d/worker/setup.ps1?token=%s\" | iex" % (PORT, TOKEN))
    log("GPU worker on Linux:  curl -sSL 'http://<NAS-IP>:%d/worker/setup.sh?token=%s' | bash" % (PORT, TOKEN))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
