"""Ossuary game library server.

Serves the games in one folder on the NAS (mounted read-only at /games) to the Ossuary iPhone app.
Each top-level folder is a system ("snes", "gba", "psx", "PC", ...); the files and folders inside
are its games. Box art comes from an image next to the game (same name, .png/.jpg), from a
folder's cover.jpg, or from the libretro thumbnail archive, matched by name.

Nothing in the games folder is ever changed. Art and the libretro name lists are cached in /cache.
Configured with environment variables (see compose.yaml). Uses only the Python standard library.
"""

import hashlib
import json
import logging
import mimetypes
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from difflib import SequenceMatcher
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("ossuary")


def env(name, default=""):
    return os.environ.get(name, default).strip()


ROOT = os.path.realpath(env("GAMES_ROOT", "/games"))
CACHE = env("CACHE_DIR", "/cache")
TOKEN = env("OSSUARY_TOKEN")
PORT = int(env("PORT", "8789") or "8789")
ONLINE_ART = env("ONLINE_ART", "true").lower() != "false"

ART_EXT = (".png", ".jpg", ".jpeg", ".webp")
SKIP_EXT = {".txt", ".nfo", ".sfv", ".md5", ".db", ".ini", ".dat", ".xml", ".srm", ".sav", ".state", ".cfg", ".url", ".log"}
SKIP_NAMES = {"#recycle", "lost+found", "@eaDir", "Thumbs.db", ".DS_Store", "bios", "BIOS", "saves", "states", "art", "covers"}

# Folder name (lower case) -> (display name, libretro thumbnail system, RetroDeck can play it)
SYSTEMS = {
    "nes": ("Nintendo Entertainment System", "Nintendo - Nintendo Entertainment System", True),
    "famicom": ("Famicom", "Nintendo - Nintendo Entertainment System", True),
    "fds": ("Famicom Disk System", "Nintendo - Family Computer Disk System", True),
    "snes": ("Super Nintendo", "Nintendo - Super Nintendo Entertainment System", True),
    "sfc": ("Super Famicom", "Nintendo - Super Nintendo Entertainment System", True),
    "gb": ("Game Boy", "Nintendo - Game Boy", True),
    "gbc": ("Game Boy Color", "Nintendo - Game Boy Color", True),
    "gba": ("Game Boy Advance", "Nintendo - Game Boy Advance", True),
    "n64": ("Nintendo 64", "Nintendo - Nintendo 64", True),
    "nds": ("Nintendo DS", "Nintendo - Nintendo DS", True),
    "ds": ("Nintendo DS", "Nintendo - Nintendo DS", True),
    "megadrive": ("Mega Drive", "Sega - Mega Drive - Genesis", True),
    "genesis": ("Genesis", "Sega - Mega Drive - Genesis", True),
    "md": ("Mega Drive", "Sega - Mega Drive - Genesis", True),
    "psx": ("PlayStation", "Sony - PlayStation", True),
    "ps1": ("PlayStation", "Sony - PlayStation", True),
    "playstation": ("PlayStation", "Sony - PlayStation", True),
    "mastersystem": ("Master System", "Sega - Master System - Mark III", False),
    "sms": ("Master System", "Sega - Master System - Mark III", False),
    "gamegear": ("Game Gear", "Sega - Game Gear", False),
    "gg": ("Game Gear", "Sega - Game Gear", False),
    "saturn": ("Saturn", "Sega - Saturn", False),
    "dreamcast": ("Dreamcast", "Sega - Dreamcast", False),
    "ps2": ("PlayStation 2", "Sony - PlayStation 2", False),
    "psp": ("PSP", "Sony - PlayStation Portable", False),
    "gamecube": ("GameCube", "Nintendo - GameCube", False),
    "gc": ("GameCube", "Nintendo - GameCube", False),
    "wii": ("Wii", "Nintendo - Wii", False),
    "3ds": ("Nintendo 3DS", "Nintendo - Nintendo 3DS", False),
    "atari2600": ("Atari 2600", "Atari - 2600", False),
    "pcengine": ("PC Engine", "NEC - PC Engine - TurboGrafx 16", False),
    "tg16": ("TurboGrafx-16", "NEC - PC Engine - TurboGrafx 16", False),
    "neogeo": ("Neo Geo", "SNK - Neo Geo", False),
    "arcade": ("Arcade", "MAME", False),
    "mame": ("Arcade", "MAME", False),
    "dos": ("DOS", "DOS", False),
    "scummvm": ("ScummVM", "ScummVM", False),
    "pc": ("PC", None, False),
    "windows": ("PC", None, False),
    "linux": ("Linux", None, False),
    "indie": ("Indie", None, False),
}

os.makedirs(os.path.join(CACHE, "art"), exist_ok=True)
os.makedirs(os.path.join(CACHE, "lists"), exist_ok=True)


def visible(name):
    return not name.startswith(".") and name not in SKIP_NAMES


def resolve(relative):
    relative = (relative or "").strip("/")
    full = os.path.realpath(os.path.join(ROOT, relative))
    if full != ROOT and not full.startswith(ROOT + os.sep):
        raise PermissionError("outside the games folder")
    return full


def rel(full):
    return os.path.relpath(full, ROOT).replace(os.sep, "/") if full != ROOT else ""


def system_info(folder):
    key = re.sub(r"[^a-z0-9]", "", folder.lower())
    if key in SYSTEMS:
        return SYSTEMS[key]
    return (folder, None, False)


def clean_title(name):
    """'Super Metroid (Japan, USA) (En,Ja) [!].sfc' -> 'Super Metroid'"""
    base, ext = os.path.splitext(name)
    if not ext or len(ext) > 6 or not ext[1:].isalnum() or ext[1:].isdigit():
        base = name
    base = re.sub(r"\s*[\(\[].*?[\)\]]", "", base)
    base = base.replace("_", " ").strip(" .-")
    return re.sub(r"\s+", " ", base) or name


def match_key(text):
    text = re.sub(r"\s*[\(\[].*?[\)\]]", "", text.lower())
    text = text.replace("&", "and")
    text = re.sub(r"^(the|a|an) ", "", text)
    text = re.sub(r", (the|a|an)\Z", "", text)
    return re.sub(r"[^a-z0-9]", "", text)


def dir_size(path):
    total = 0
    for directory, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(directory, f))
            except OSError:
                pass
    return total


# ---------------------------------------------------------------------------
# Library scan (cheap: a listdir per system, cached briefly)
# ---------------------------------------------------------------------------

_library = {"time": 0, "systems": []}
_library_lock = threading.Lock()


def scan():
    with _library_lock:
        if time.time() - _library["time"] < 60:
            return _library["systems"]
        systems = []
        try:
            entries = sorted(os.scandir(ROOT), key=lambda e: e.name.lower())
        except FileNotFoundError:
            entries = []
        for entry in entries:
            if not entry.is_dir() or not visible(entry.name):
                continue
            display, thumbs, retrodeck = system_info(entry.name)
            games = []
            try:
                children = sorted(os.scandir(entry.path), key=lambda e: e.name.lower())
            except OSError:
                continue
            names = {c.name for c in children}
            for child in children:
                if not visible(child.name):
                    continue
                ext = os.path.splitext(child.name)[1].lower()
                if child.is_file() and (ext in SKIP_EXT or ext in ART_EXT):
                    continue
                try:
                    stat = child.stat()
                except OSError:
                    continue
                # A .cue sheet next to its .bin: list the .bin (it's what gets played) and hide the .cue.
                stem = os.path.splitext(child.name)[0]
                if ext == ".cue" and any(n != child.name and os.path.splitext(n)[0] == stem and n.lower().endswith(".bin") for n in names):
                    continue
                games.append({
                    "path": rel(child.path),
                    "file": child.name,
                    "title": clean_title(child.name),
                    "system": entry.name,
                    "folder": child.is_dir(),
                    "size": dir_size(child.path) if child.is_dir() else stat.st_size,
                    "added": stat.st_mtime,
                    "retrodeck": retrodeck and not child.is_dir(),
                })
            systems.append({
                "id": entry.name,
                "name": display,
                "retrodeck": retrodeck,
                "count": len(games),
                "games": games,
            })
        _library["systems"] = systems
        _library["time"] = time.time()
        return systems


# ---------------------------------------------------------------------------
# Box art
# ---------------------------------------------------------------------------

_lists = {}
_list_lock = threading.Lock()


def libretro_names(thumb_system):
    """Every box-art file name libretro has for a system, cached for a week."""
    with _list_lock:
        if thumb_system in _lists:
            return _lists[thumb_system]
        cache_file = os.path.join(CACHE, "lists", hashlib.sha1(thumb_system.encode()).hexdigest() + ".json")
        names = None
        if os.path.exists(cache_file) and time.time() - os.path.getmtime(cache_file) < 7 * 86400:
            try:
                with open(cache_file) as handle:
                    names = json.load(handle)
            except Exception:
                names = None
        if names is None:
            url = "https://thumbnails.libretro.com/%s/Named_Boxarts/" % urllib.parse.quote(thumb_system)
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "Ossuary/1.0 (home game library)"})
                with urllib.request.urlopen(request, timeout=30) as response:
                    html = response.read().decode("utf-8", "replace")
                names = [urllib.parse.unquote(m) for m in re.findall(r'href="([^"?/][^"]*\.png)"', html)]
                with open(cache_file, "w") as handle:
                    json.dump(names, handle)
                log.info("Fetched %d box-art names for %s", len(names), thumb_system)
            except Exception as error:
                log.warning("Couldn't list libretro art for %s: %s", thumb_system, error)
                names = []
        index = {}
        for name in names:
            index.setdefault(match_key(name[:-4]), []).append(name)
        _lists[thumb_system] = (names, index)
        return _lists[thumb_system]


def best_libretro_name(thumb_system, game_name):
    names, index = libretro_names(thumb_system)
    if not names:
        return None
    key = match_key(clean_title(game_name))
    candidates = index.get(key)
    if candidates:
        # Prefer USA/Europe/World releases.
        for region in ("USA", "Europe", "World", "UK"):
            for c in candidates:
                if region in c:
                    return c
        return candidates[0]
    # Fuzzy: best ratio among names sharing the first letters.
    best, score = None, 0.0
    for candidate_key, files in index.items():
        if not candidate_key or candidate_key[:3] != key[:3]:
            continue
        ratio = SequenceMatcher(None, key, candidate_key).ratio()
        if ratio > score:
            best, score = files[0], ratio
    return best if score >= 0.86 else None


def local_art(full):
    base = os.path.splitext(full)[0] if os.path.isfile(full) else full
    directory = os.path.dirname(full)
    for ext in ART_EXT:
        if os.path.exists(base + ext):
            return base + ext
    for folder in ("art", "covers"):
        for ext in ART_EXT:
            candidate = os.path.join(directory, folder, os.path.splitext(os.path.basename(full))[0] + ext)
            if os.path.exists(candidate):
                return candidate
    if os.path.isdir(full):
        for name in ("cover", "boxart", "folder", "poster", "header"):
            for ext in ART_EXT:
                candidate = os.path.join(full, name + ext)
                if os.path.exists(candidate):
                    return candidate
    return None


def art_for(full):
    """Path to an image for a game, or None."""
    found = local_art(full)
    if found:
        return found
    if not ONLINE_ART:
        return None
    system_folder = rel(full).split("/")[0]
    thumb_system = system_info(system_folder)[1]
    if not thumb_system:
        return None
    key = hashlib.sha1(rel(full).encode()).hexdigest()
    cached = os.path.join(CACHE, "art", key + ".png")
    missing = cached + ".none"
    if os.path.exists(cached):
        return cached
    if os.path.exists(missing) and time.time() - os.path.getmtime(missing) < 7 * 86400:
        return None
    name = best_libretro_name(thumb_system, os.path.basename(full))
    if name:
        url = "https://thumbnails.libretro.com/%s/Named_Boxarts/%s" % (urllib.parse.quote(thumb_system), urllib.parse.quote(name))
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Ossuary/1.0 (home game library)"})
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
            with open(cached, "wb") as handle:
                handle.write(data)
            return cached
        except Exception as error:
            log.info("No art for %s: %s", os.path.basename(full), error)
    open(missing, "w").close()
    return None


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "Ossuary/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def authorized(self, query):
        header = self.headers.get("Authorization", "")
        supplied = header[7:] if header.startswith("Bearer ") else query.get("token", [""])[0]
        return bool(TOKEN) and supplied == TOKEN

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        route = parsed.path.rstrip("/") or "/"
        if route == "/api/health":
            self.send_json(200, {"ok": True, "name": "Ossuary"})
            return
        if not self.authorized(query):
            self.send_json(401, {"error": "wrong token"})
            return
        try:
            if route == "/api/systems":
                systems = scan()
                self.send_json(200, {"systems": [
                    {k: v for k, v in s.items() if k != "games"} | {"cover": s["games"][0]["path"] if s["games"] else None}
                    for s in systems
                ]})
            elif route == "/api/games":
                system = query.get("system", [""])[0]
                for s in scan():
                    if s["id"] == system:
                        self.send_json(200, {"games": s["games"], "name": s["name"]})
                        return
                self.send_json(404, {"error": "no such system"})
            elif route == "/api/recent":
                games = [g for s in scan() for g in s["games"]]
                games.sort(key=lambda g: g["added"], reverse=True)
                self.send_json(200, {"games": games[:60]})
            elif route == "/api/search":
                text = match_key(query.get("q", [""])[0])
                games = [g for s in scan() for g in s["games"] if text and text in match_key(g["title"])]
                self.send_json(200, {"games": games[:200]})
            elif route == "/art":
                self.art(query)
            elif route == "/file":
                self.file(query)
            else:
                self.send_json(404, {"error": "not found"})
        except PermissionError:
            self.send_json(403, {"error": "outside the games folder"})
        except FileNotFoundError:
            self.send_json(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            log.warning("%s failed: %s", route, error)
            try:
                self.send_json(500, {"error": str(error)})
            except Exception:
                pass

    def art(self, query):
        full = resolve(query.get("path", [""])[0])
        if not os.path.exists(full):
            raise FileNotFoundError(full)
        image = art_for(full)
        if not image:
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "private, max-age=86400")
            self.end_headers()
            return
        with open(image, "rb") as handle:
            data = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(image)[0] or "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, max-age=604800")
        self.end_headers()
        self.wfile.write(data)

    def file(self, query):
        full = resolve(query.get("path", [""])[0])
        if os.path.isdir(full):
            self.send_json(400, {"error": "folders can't be downloaded; zip the game on the NAS first"})
            return
        if not os.path.isfile(full):
            raise FileNotFoundError(full)
        size = os.path.getsize(full)
        start, end, partial = 0, size - 1, False
        header = self.headers.get("Range")
        if header:
            match = re.match(r"bytes=(\d*)-(\d*)", header)
            if match:
                if match.group(1):
                    start = int(match.group(1))
                    if match.group(2):
                        end = min(int(match.group(2)), size - 1)
                elif match.group(2):
                    start = max(0, size - int(match.group(2)))
                partial = True
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(os.path.basename(full)))
        self.end_headers()
        with open(full, "rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                chunk = handle.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main():
    if not TOKEN or TOKEN.startswith("CHANGE-ME"):
        log.error("Set OSSUARY_TOKEN in the app's YAML to a long random password, then restart.")
        sys.exit(1)
    if not os.path.isdir(ROOT):
        log.error("%s isn't there. Check the volume line that mounts your games folder.", ROOT)
        sys.exit(1)
    systems = scan()
    log.info("Games folder: %s (%d systems, %d games)", ROOT, len(systems), sum(s["count"] for s in systems))
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    log.info("Ossuary listening on port %d", PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
