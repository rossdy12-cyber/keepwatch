"""Jarvis voice hub: a "Hey Jarvis" speaker made from a Raspberry Pi and your TrueNAS.

The Pi only streams its microphone (16 kHz, 16-bit mono) to this hub over the network and plays whatever audio the
hub sends back. Everything else happens here:

  1. openWakeWord listens for "Hey Jarvis".
  2. A beep tells you it's listening; your question is recorded until you stop talking.
  3. faster-whisper turns it into text.
  4. The Jarvis core answers (POST /api/chat).
  5. The reply is spoken in the core's own voice when it sends one, otherwise with Kokoro: a natural British
     male voice (Piper as a backup).

It also serves that voice to the Jarvis iPhone app (GET or POST /tts), so the phone sounds the same.

It also serves the Pi's setup script: on the Pi run the command printed in this app's logs.
"""

import io
import json
from datetime import datetime, timedelta
import math
import os
import queue
import re
import secrets
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

DATA = os.environ.get("DATA_DIR", "/data")
JARVIS_URL = os.environ.get("JARVIS_URL", "https://jarvis.nas-server.co.uk").rstrip("/")
JARVIS_PATH = os.environ.get("JARVIS_PATH", "/api/chat")
SESSION_ID = os.environ.get("SESSION_ID", "voice-hub")
AUDIO_PORT = int(os.environ.get("AUDIO_PORT", "10700"))
HTTP_PORT = int(os.environ.get("HTTP_PORT", "10701"))
WAKE_THRESHOLD = float(os.environ.get("WAKE_THRESHOLD", "0.5"))
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "base.en")
VOICE = os.environ.get("VOICE", "en_GB-alan-medium")  # Piper backup voice
TTS_VOICE = os.environ.get("TTS_VOICE", "bm_george")  # Kokoro: bm_george, bm_fable, bm_lewis, bm_daniel
TTS_SPEED = float(os.environ.get("TTS_SPEED", "0.95"))
VOICE_EFFECT = os.environ.get("VOICE_EFFECT", "light").lower()  # "light" adds a subtle AI-assistant sheen; "none"
USE_CORE_VOICE = os.environ.get("USE_CORE_VOICE", "true").lower() in ("1", "true", "yes")
FOLLOW_UP_SECONDS = float(os.environ.get("FOLLOW_UP_SECONDS", "0"))
GREETING = os.environ.get("GREETING", "Jarvis is listening.")

# Cloudflare blocks Python's default user agent.
USER_AGENT = "Mozilla/5.0 (compatible; JarvisVoiceHub/1.0)"

RATE = 16000
FRAME = 1280  # 80 ms, what openWakeWord expects
FRAME_BYTES = FRAME * 2


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


# ---------------------------------------------------------------------------------------------- setup

def load_token():
    """The key the Pi must present. From TOKEN, or made once and kept in /data/token."""
    token = os.environ.get("TOKEN", "").strip()
    if token:
        return token
    path = os.path.join(DATA, "token")
    if os.path.exists(path):
        return open(path).read().strip()
    token = secrets.token_urlsafe(18)
    os.makedirs(DATA, exist_ok=True)
    with open(path, "w") as handle:
        handle.write(token)
    return token


TOKEN = load_token()


def ensure_voice():
    folder = os.path.join(DATA, "voices")
    os.makedirs(folder, exist_ok=True)
    model = os.path.join(folder, VOICE + ".onnx")
    if not os.path.exists(model) or not os.path.exists(model + ".json"):
        # e.g. en_GB-alan-medium -> en/en_GB/alan/medium/
        lang, name, quality = VOICE.split("-", 2)
        base = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/%s/%s/%s/%s/%s" % (
            lang.split("_")[0], lang, name, quality, VOICE)
        for suffix in (".onnx", ".onnx.json"):
            log("Downloading voice %s%s" % (VOICE, suffix))
            urllib.request.urlretrieve(base + suffix, model + suffix[5:] if suffix == ".onnx.json" else model)
    return model


KOKORO_FILES = {
    "kokoro-v1.0.onnx": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
    "voices-v1.0.bin": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
}


def load_kokoro():
    folder = os.path.join(DATA, "kokoro")
    os.makedirs(folder, exist_ok=True)
    try:
        for name, url in KOKORO_FILES.items():
            path = os.path.join(folder, name)
            if not os.path.exists(path):
                log("Downloading the Kokoro voice model (%s, first start only)" % name)
                urllib.request.urlretrieve(url, path + ".part")
                os.replace(path + ".part", path)
        from kokoro_onnx import Kokoro
        kokoro = Kokoro(os.path.join(folder, "kokoro-v1.0.onnx"), os.path.join(folder, "voices-v1.0.bin"))
        if TTS_VOICE not in kokoro.get_voices():
            log("Kokoro has no voice %s; using bm_george" % TTS_VOICE)
        return kokoro
    except Exception as error:
        log("Kokoro unavailable, using Piper instead: %s" % error)
        return None


def load_models():
    from openwakeword.utils import download_models
    download_models(["hey_jarvis"])
    from faster_whisper import WhisperModel
    log("Loading Whisper model %s (first start downloads it)" % WHISPER_MODEL)
    whisper = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8", download_root=os.path.join(DATA, "whisper"))
    return whisper, ensure_voice()


WHISPER, VOICE_MODEL = load_models()
whisper_lock = threading.Lock()
KOKORO = load_kokoro()
kokoro_lock = threading.Lock()


def new_wake_model():
    from openwakeword.model import Model
    return Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")


# ---------------------------------------------------------------------------------------------- audio helpers

def tone_wav(freqs, length=0.12, rate=16000, volume=0.35):
    """A short beep (one tone per entry) as WAV bytes."""
    samples = []
    for freq in freqs:
        count = int(rate * length)
        for i in range(count):
            fade = min(1.0, i / (rate * 0.01), (count - i) / (rate * 0.01))
            samples.append(int(volume * fade * 32767 * math.sin(2 * math.pi * freq * i / rate)))
    return pcm_to_wav(struct.pack("<%dh" % len(samples), *samples), rate)


def pcm_to_wav(pcm, rate):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm)
    return buffer.getvalue()


def wav_seconds(data):
    try:
        with wave.open(io.BytesIO(data)) as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return 2.0


BEEP_LISTEN = tone_wav([880, 1320])
BEEP_NOTHING = tone_wav([660, 440])


def add_effect(wav):
    """A subtle "AI assistant" sheen: trims rumble, adds a faint short room reflection, evens out the level."""
    if VOICE_EFFECT in ("none", "off", ""):
        return wav
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", "pipe:0", "-af",
         "highpass=f=70,aecho=0.8:0.6:18|36:0.10|0.05,acompressor=threshold=-20dB:ratio=2.5:attack=5:release=80,"
         "loudnorm=I=-16:TP=-1.5", "-ar", "24000", "-ac", "1", "-f", "s16le", "pipe:1"],
        input=wav, capture_output=True, timeout=60)
    # Raw samples, wrapped here: a WAV that ffmpeg writes to a pipe has no length in its header.
    return pcm_to_wav(result.stdout, 24000) if result.returncode == 0 and result.stdout else wav


def speak(text):
    """Text to speech as WAV bytes: Kokoro (natural British voice), or Piper if Kokoro isn't available."""
    clean = re.sub(r"[*_`#>]", "", text)
    clean = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", clean).strip()
    if not clean:
        return None
    if KOKORO is not None:
        try:
            voice = TTS_VOICE if TTS_VOICE in KOKORO.get_voices() else "bm_george"
            with kokoro_lock:
                samples, rate = KOKORO.create(clean, voice=voice, speed=TTS_SPEED, lang="en-gb")
            pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16).tobytes()
            return add_effect(pcm_to_wav(pcm, rate))
        except Exception as error:
            log("Kokoro failed, using Piper: %s" % error)
    return speak_piper(clean)


def speak_piper(clean):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        path = handle.name
    try:
        piper = os.path.join(os.path.dirname(sys.executable), "piper")
        subprocess.run([piper if os.path.exists(piper) else "piper", "--model", VOICE_MODEL, "--output_file", path],
                       input=clean.encode("utf-8"), capture_output=True, timeout=120, check=True)
        with open(path, "rb") as handle:
            return handle.read()
    except Exception as error:
        log("Piper failed: %s" % error)
        return None
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


# ---------------------------------------------------------------------------------------------- local skills
# Alarms, timers, the time, and volume are handled right here on the hub, so they're instant and work
# even if the Jarvis core is busy or offline. Anything not recognised falls through to the core.

ALARM_CHIME = tone_wav([1047, 1319, 1047, 1319], length=0.18, volume=0.6)
TIMER_CHIME = tone_wav([880, 1175, 880, 1175, 880], length=0.14, volume=0.55)
ALARM_MAX_SECONDS = int(os.environ.get("ALARM_MAX_SECONDS", "600"))   # ring at most this long
SNOOZE_MINUTES = int(os.environ.get("SNOOZE_MINUTES", "9"))

ALARMS_FILE = os.path.join(DATA, "alarms.json")
alarms_lock = threading.Lock()

def load_alarms():
    try:
        with open(ALARMS_FILE) as handle:
            data = json.load(handle)
            return data if isinstance(data, list) else []
    except Exception:
        return []

ALARMS = load_alarms()

def save_alarms():
    try:
        with open(ALARMS_FILE, "w") as handle:
            json.dump(ALARMS, handle)
    except Exception as error:
        log("Couldn't save alarms: %s" % error)

# Connected Pis, by name, so the scheduler can ring the right one.
SATELLITES = {}
satellites_lock = threading.Lock()

WORD_NUMBERS = {"zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
                "thirty": 30, "forty": 40, "fifty": 50, "quarter": 15, "half": 30, "an": 1, "a": 1, "one": 1}

def _num(word):
    word = word.strip().lower()
    if word.isdigit():
        return int(word)
    return WORD_NUMBERS.get(word)

def parse_alarm_time(text):
    """Finds a clock time in the text and returns the next datetime it falls on (or None)."""
    t = text.lower()
    tomorrow = "tomorrow" in t or "next day" in t
    pm_hint = any(w in t for w in ["afternoon", "evening", "tonight", "night", "p.m", "pm"])
    am_hint = any(w in t for w in ["morning", "a.m", "am"])
    hour = minute = None

    m = re.search(r"\b(\d{1,2})[:.\s](\d{2})\s*(a\.?m\.?|p\.?m\.?)?", t)
    if m:
        hour, minute = int(m.group(1)), int(m.group(2))
        mer = (m.group(3) or "").replace(".", "")
    else:
        m = re.search(r"\b(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)", t)
        if m:
            hour, minute, mer = int(m.group(1)), 0, m.group(2).replace(".", "")
        else:
            oclock = re.search(r"\b(\w+)\s*o'?clock", t)
            pastto = re.search(r"\b(quarter|half|\w+)\s+(past|to)\s+(\w+)", t)
            lone = re.search(r"\b(?:at|for)\s+(\w+)", t)
            if oclock and _num(oclock.group(1)) is not None:
                hour, minute, mer = _num(oclock.group(1)), 0, ""
            elif pastto and _num(pastto.group(1)) is not None and _num(pastto.group(3)) is not None:
                mins, hr = _num(pastto.group(1)), _num(pastto.group(3))
                if pastto.group(2) == "to":
                    minute, hour = (60 - mins) % 60, (hr - 1) if mins else hr
                else:
                    minute, hour = mins, hr
                mer = ""
            elif lone and _num(lone.group(1)) is not None and 0 <= _num(lone.group(1)) <= 23:
                hour, minute, mer = _num(lone.group(1)), 0, ""
            else:
                    return None
    if hour is None:
        return None
    # Apply am/pm.
    if mer.startswith("p") or (not mer and pm_hint and hour < 12):
        if hour < 12:
            hour += 12
    elif mer.startswith("a") or (not mer and am_hint):
        if hour == 12:
            hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    now = datetime.now()
    target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if tomorrow:
        target += timedelta(days=1)
    elif target <= now + timedelta(seconds=1):
        target += timedelta(days=1)
    return target

def parse_duration(text):
    """Total seconds from phrases like '5 minutes', '1 hour 30 minutes', 'half an hour', '90 seconds'."""
    t = text.lower()
    total = 0
    if "half an hour" in t or "half hour" in t:
        total += 1800
    if re.search(r"\b(an|one)\s+hour\b", t) and "half an hour" not in t:
        total += 3600
    for value, unit in re.findall(r"(\d+)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)", t):
        value = int(value)
        if unit.startswith(("hour", "hr")):
            total += value * 3600
        elif unit.startswith(("min",)):
            total += value * 60
        else:
            total += value
    return total if total > 0 else None

def format_when(when):
    now = datetime.now()
    clock = when.strftime("%I:%M %p").lstrip("0")
    if when.date() == now.date():
        day = "today"
    elif when.date() == (now + timedelta(days=1)).date():
        day = "tomorrow"
    else:
        day = when.strftime("%A")
    return "%s %s" % (clock, day)

def add_alarm(name, when, label, kind, repeat="once"):
    entry = {"id": secrets.token_hex(4), "name": name, "at": when.timestamp(),
             "label": label, "kind": kind, "repeat": repeat, "enabled": True}
    with alarms_lock:
        ALARMS.append(entry)
        save_alarms()
    return entry

def scheduler():
    while True:
        time.sleep(2)
        now = time.time()
        changed = False
        with alarms_lock:
            due = [a for a in ALARMS if a.get("enabled") and now >= a["at"]]
        for alarm in due:
            with satellites_lock:
                sat = SATELLITES.get(alarm["name"])
            fired = False
            if sat:
                sat.start_ring(alarm)
                fired = True
            if fired or now > alarm["at"] + 600:   # ring it, or give up after 10 min with nobody listening
                with alarms_lock:
                    if alarm.get("repeat") == "daily":
                        alarm["at"] += 86400
                    else:
                        alarm["enabled"] = False
                    changed = True
        if changed:
            with alarms_lock:
                save_alarms()

threading.Thread(target=scheduler, daemon=True).start()

def apply_gain(wav, gain):
    """Scales a 16-bit PCM WAV's volume (software volume for the Pi)."""
    if gain >= 0.999:
        return wav
    try:
        with wave.open(io.BytesIO(wav)) as w:
            channels, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
            frames = w.readframes(w.getnframes())
        if width != 2:
            return wav
        samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) * gain
        pcm = np.clip(samples, -32768, 32767).astype(np.int16).tobytes()
        out = io.BytesIO()
        with wave.open(out, "wb") as w2:
            w2.setnchannels(channels); w2.setsampwidth(2); w2.setframerate(rate); w2.writeframes(pcm)
        return out.getvalue()
    except Exception:
        return wav

def handle_command(text, sat):
    """Handles alarms, timers, the time and volume on the hub. Returns True if it dealt with the request."""
    t = " " + text.lower().strip() + " "
    say = lambda words: sat.send_audio(speak(words) or BEEP_NOTHING)

    stop_words = re.search(r"\b(stop|cancel|dismiss|snooze|turn (it|that|the alarm|the timer) off|be quiet|silence|enough|shut up)\b", t)

    # Stop or snooze a ringing alarm/timer.
    if sat.ringing and stop_words:
        ringing = sat.ringing
        sat.stop_ring()
        if "snooze" in t:
            when = datetime.now() + timedelta(minutes=SNOOZE_MINUTES)
            add_alarm(sat.name, when, ringing.get("label") or "", ringing.get("kind", "alarm"))
            say("Snoozing for %d minutes." % SNOOZE_MINUTES)
        else:
            say("Alarm off." if ringing.get("kind") != "timer" else "Timer stopped.")
        return True

    # Cancel scheduled (not currently ringing) alarms/timers.
    if stop_words and ("alarm" in t or "timer" in t) and "set" not in t and "for" not in t:
        kind = "timer" if "timer" in t else "alarm"
        with alarms_lock:
            mine = [a for a in ALARMS if a["name"] == sat.name and a.get("enabled") and a.get("kind") == kind]
            for a in mine:
                a["enabled"] = False
            save_alarms()
        say("Cancelled your %s." % kind if len(mine) == 1 else ("Cancelled your %ss." % kind if mine else "You have no %s set." % kind))
        return True

    # Set a timer.
    if "timer" in t or (re.search(r"\b(set|start)\b", t) and re.search(r"\bfor\b.*\b(minute|second|hour|min|sec|hr)", t) and "alarm" not in t):
        seconds = parse_duration(t)
        if not seconds:
            say("How long would you like the timer for?")
            return True
        when = datetime.now() + timedelta(seconds=seconds)
        add_alarm(sat.name, when, "", "timer")
        mins, secs = divmod(seconds, 60)
        hrs, mins = divmod(mins, 60)
        parts = [("%d hour%s" % (hrs, "" if hrs == 1 else "s")) if hrs else "",
                 ("%d minute%s" % (mins, "" if mins == 1 else "s")) if mins else "",
                 ("%d second%s" % (secs, "" if secs == 1 else "s")) if secs and not hrs else ""]
        say("Timer set for %s." % " ".join(p for p in parts if p).strip())
        return True

    # Set an alarm.
    if "alarm" in t or re.search(r"\b(wake me|set .* for)\b", t):
        when = parse_alarm_time(t)
        if not when:
            say("What time would you like the alarm for?")
            return True
        repeat = "daily" if ("every day" in t or "daily" in t or "every morning" in t) else "once"
        add_alarm(sat.name, when, "", "alarm", repeat)
        say("Alarm set for %s%s." % (format_when(when), ", every day" if repeat == "daily" else ""))
        return True

    # List alarms.
    if re.search(r"\b(what|any|list|my).{0,20}(alarm|timer)", t) or re.search(r"\balarms?\b.{0,10}\?", t):
        with alarms_lock:
            mine = sorted([a for a in ALARMS if a["name"] == sat.name and a.get("enabled")], key=lambda a: a["at"])
        if not mine:
            say("You have no alarms set.")
        else:
            items = ", ".join("%s%s" % (format_when(datetime.fromtimestamp(a["at"])),
                                        " (timer)" if a.get("kind") == "timer" else "") for a in mine[:5])
            say("You have %d set: %s." % (len(mine), items))
        return True

    # The time / date.
    if re.search(r"\b(what('s| is)? the )?(time|date)\b", t) or "what day" in t or "time is it" in t:
        now = datetime.now()
        if "date" in t or "day" in t:
            say("It's %s." % now.strftime("%A the %d of %B").replace(" 0", " "))
        else:
            say("It's %s." % now.strftime("%I:%M %p").lstrip("0"))
        return True

    # Volume.
    if re.search(r"\b(volume|louder|quieter|turn (it|the volume) (up|down)|mute|unmute|too (loud|quiet))\b", t):
        m = re.search(r"(\d{1,3})\s*(percent|%)", t)
        if "mute" in t and "unmute" not in t:
            sat.gain = 0.0
            return True
        if "unmute" in t or "max" in t:
            sat.gain = 1.0
        elif m:
            sat.gain = max(0.0, min(1.5, int(m.group(1)) / 100.0))
        elif re.search(r"\b(up|louder|too quiet)\b", t):
            sat.gain = min(1.5, sat.gain + 0.25)
        elif re.search(r"\b(down|quieter|too loud)\b", t):
            sat.gain = max(0.1, sat.gain - 0.25)
        say("Volume %d percent." % round(sat.gain * 100))
        return True

    return False


def fetch_as_wav(url):
    """The core's own voice recording (usually MP3), converted to WAV for the Pi."""
    if not url.lower().startswith("http"):
        url = JARVIS_URL + ("" if url.startswith("/") else "/") + url
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=30) as response:
            data = response.read()
        result = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-ac", "1", "-ar", "22050", "-f", "s16le", "pipe:1"],
                                input=data, capture_output=True, timeout=60)
        return pcm_to_wav(result.stdout, 22050) if result.returncode == 0 and result.stdout else None
    except Exception as error:
        log("Couldn't fetch the core's voice: %s" % error)
        return None


def transcribe(audio):
    samples = audio.astype(np.float32) / 32768.0
    with whisper_lock:
        segments, _ = WHISPER.transcribe(samples, language="en", beam_size=1, vad_filter=False,
                                         condition_on_previous_text=False)
        text = " ".join(segment.text for segment in segments).strip()
    # Whisper's usual guesses for silence or noise.
    if re.fullmatch(r"[\s.,!?]*|(thanks for watching|thank you|you)[.!]?", text.lower()):
        return ""
    return text


def ask_jarvis(text):
    body = json.dumps({"message": text, "session_id": SESSION_ID}).encode()
    request = urllib.request.Request(JARVIS_URL + JARVIS_PATH, data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Accept": "application/json",
                                              "User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=90) as response:
        reply = json.loads(response.read() or b"{}")
    if isinstance(reply, dict):
        return str(reply.get("reply") or reply.get("response") or reply.get("text") or ""), reply.get("audio_url")
    return str(reply), None


# ---------------------------------------------------------------------------------------------- one Pi

class Satellite:
    """One connected Pi: wake word, recording, answering."""

    def __init__(self, sock, name):
        self.sock = sock
        self.name = name
        self.send_lock = threading.Lock()
        self.wake = new_wake_model()
        self.state = "wake"
        self.muted_until = 0.0
        self.noise = 300.0
        self.recording = []
        self.speech_started = False
        self.silence = 0.0
        self.recorded = 0.0
        self.wait_limit = 5.0
        self.pending = b""
        self.gain = 1.0
        self.ringing = None

    def send_audio(self, wav, tail=0.6, mute=True):
        if not wav:
            return
        wav = apply_gain(wav, self.gain)
        frame = b"A" + struct.pack(">I", len(wav)) + wav
        with self.send_lock:
            self.sock.sendall(frame)
        # Ignore what the microphone hears while (and just after) the Pi is playing — but not while an
        # alarm is ringing, so "Hey Jarvis, stop" can still be heard over it.
        if mute:
            self.muted_until = max(self.muted_until, time.time()) + wav_seconds(wav) + tail

    def start_ring(self, alarm):
        if self.ringing:
            return
        self.ringing = alarm
        threading.Thread(target=self._ring_loop, args=(alarm,), daemon=True).start()
        log("[%s] %s ringing" % (self.name, alarm.get("kind", "alarm")))

    def stop_ring(self):
        self.ringing = None

    def _ring_loop(self, alarm):
        chime = TIMER_CHIME if alarm.get("kind") == "timer" else ALARM_CHIME
        started = time.time()
        while self.ringing is alarm and time.time() - started < ALARM_MAX_SECONDS:
            # Pause the chiming while the person is talking to Jarvis, so their command is heard clearly.
            if self.state == "wake" and time.time() >= self.muted_until:
                self.send_audio(chime, tail=0.0, mute=False)
                time.sleep(1.5)
            else:
                time.sleep(0.3)
        if self.ringing is alarm:
            self.ringing = None

    def feed(self, data):
        self.pending += data
        while len(self.pending) >= FRAME_BYTES:
            chunk, self.pending = self.pending[:FRAME_BYTES], self.pending[FRAME_BYTES:]
            self.frame(np.frombuffer(chunk, dtype=np.int16))

    def frame(self, samples):
        now = time.time()
        level = float(np.sqrt(np.mean(samples.astype(np.float32) ** 2)))
        if self.state == "busy":
            return
        if now < self.muted_until:
            if self.state == "wake":
                self.wake.predict(np.zeros(FRAME, dtype=np.int16))
            return
        if self.state == "wake":
            self.noise = 0.98 * self.noise + 0.02 * level
            scores = self.wake.predict(samples)
            if max(scores.values()) >= WAKE_THRESHOLD:
                log("[%s] Wake word heard (%.2f)" % (self.name, max(scores.values())))
                self.wake.reset()
                self.start_recording(wait_limit=5.0)
                self.send_audio(BEEP_LISTEN, tail=0.05)
            return
        # Recording a question.
        self.recording.append(samples.copy())
        self.recorded += FRAME / RATE
        loud = level > max(self.noise * 2.5, 400)
        if loud:
            self.speech_started = True
            self.silence = 0.0
        else:
            self.silence += FRAME / RATE
        if not self.speech_started and self.recorded > self.wait_limit:
            log("[%s] Nothing said" % self.name)
            self.back_to_wake()
            if self.wait_limit > 3:  # after the wake word, not after a follow-up window
                self.send_audio(BEEP_NOTHING)
        elif (self.speech_started and self.silence > 0.9) or self.recorded > 15:
            audio = np.concatenate(self.recording)
            self.state = "busy"
            threading.Thread(target=self.answer, args=(audio,), daemon=True).start()

    def start_recording(self, wait_limit):
        self.state = "record"
        self.recording, self.speech_started, self.silence, self.recorded = [], False, 0.0, 0.0
        self.wait_limit = wait_limit

    def back_to_wake(self):
        self.state = "wake"
        self.recording = []
        self.wake.reset()

    def answer(self, audio):
        try:
            text = transcribe(audio)
            if not text:
                log("[%s] Couldn't make out any words" % self.name)
                self.send_audio(BEEP_NOTHING)
                return
            log("[%s] Heard: %s" % (self.name, text))
            # Alarms, timers, the time and volume are handled on the hub; everything else goes to the core.
            try:
                if handle_command(text, self):
                    return
            except Exception as error:
                log("[%s] Local command error: %s" % (self.name, error))
            try:
                reply, audio_url = ask_jarvis(text)
            except Exception as error:
                log("[%s] Jarvis core error: %s" % (self.name, error))
                reply, audio_url = "Sorry, I can't reach the Jarvis core at the moment.", None
            log("[%s] Jarvis: %s" % (self.name, reply))
            wav = fetch_as_wav(audio_url) if (USE_CORE_VOICE and audio_url) else None
            self.send_audio(wav or speak(reply) or BEEP_NOTHING)
        except Exception as error:
            log("[%s] Error: %s" % (self.name, error))
            self.send_audio(BEEP_NOTHING)
        finally:
            if FOLLOW_UP_SECONDS > 0 and self.state == "busy":
                # Carry on the conversation without the wake word, once the reply has finished.
                self.start_recording(wait_limit=FOLLOW_UP_SECONDS)
            else:
                self.back_to_wake()


class AudioHandler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(30)
        name, satellite = None, None
        try:
            hello = b""
            while not hello.endswith(b"\n") and len(hello) < 512:
                byte = sock.recv(1)
                if not byte:
                    return
                hello += byte
            parts = hello.decode("utf-8", "replace").split()
            if len(parts) < 2 or parts[0] != "JARVIS1" or not secrets.compare_digest(parts[1], TOKEN):
                log("Refused a connection from %s (wrong key)" % self.client_address[0])
                return
            name = parts[2] if len(parts) > 2 else self.client_address[0]
            log("[%s] Connected from %s" % (name, self.client_address[0]))
            satellite = Satellite(sock, name)
            with satellites_lock:
                SATELLITES[name] = satellite
            if GREETING:
                threading.Thread(target=lambda: satellite.send_audio(speak(GREETING)), daemon=True).start()
            while True:
                data = sock.recv(8192)
                if not data:
                    break
                satellite.feed(data)
        except (OSError, socket.timeout) as error:
            log("Connection ended: %s" % error)
        finally:
            if name is not None:
                with satellites_lock:
                    if SATELLITES.get(name) is satellite:
                        SATELLITES.pop(name, None)
            log("Disconnected: %s" % self.client_address[0])


class AudioServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


# ---------------------------------------------------------------------------------------------- Pi installer over HTTP

PI_CLIENT = r'''#!/usr/bin/env python3
"""Jarvis Pi speaker: streams the microphone to the Jarvis voice hub and plays what it sends back.
Only uses the Python standard library plus arecord/aplay, so it runs happily on a Raspberry Pi 1."""
import os, queue, socket, struct, subprocess, threading, time

HUB = os.environ.get("HUB_HOST", "")
PORT = int(os.environ.get("HUB_PORT", "10700"))
TOKEN = os.environ.get("HUB_TOKEN", "")
NAME = os.environ.get("SATELLITE_NAME", socket.gethostname())
MIC = os.environ.get("MIC_DEVICE", "default")
SPEAKER = os.environ.get("SPEAKER_DEVICE", "default")

playback = queue.Queue()

def player():
    while True:
        wav = playback.get()
        try:
            subprocess.run(["aplay", "-q", "-D", SPEAKER, "-"], input=wav, timeout=300)
        except Exception as error:
            print("aplay failed:", error, flush=True)

threading.Thread(target=player, daemon=True).start()

def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("hub closed the connection")
        data += chunk
    return data

def run_once():
    sock = socket.create_connection((HUB, PORT), timeout=10)
    sock.settimeout(None)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.sendall(("JARVIS1 %s %s\n" % (TOKEN, NAME)).encode())
    mic = subprocess.Popen(["arecord", "-q", "-D", MIC, "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw"],
                           stdout=subprocess.PIPE)
    stop = threading.Event()

    def stream():
        try:
            while not stop.is_set():
                data = mic.stdout.read(2560)
                if not data:
                    break
                sock.sendall(data)
        except OSError:
            pass
        finally:
            stop.set()
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    threading.Thread(target=stream, daemon=True).start()
    print("Connected to the Jarvis hub at %s:%d" % (HUB, PORT), flush=True)
    try:
        while not stop.is_set():
            kind = recv_exact(sock, 1)
            length = struct.unpack(">I", recv_exact(sock, 4))[0]
            payload = recv_exact(sock, length)
            if kind == b"A":
                playback.put(payload)
    finally:
        stop.set()
        mic.kill()
        sock.close()

while True:
    try:
        run_once()
    except Exception as error:
        print("Hub connection problem:", error, "- retrying in 5 s", flush=True)
    time.sleep(5)
'''

PI_SETUP = r'''#!/bin/bash
# Sets up this Raspberry Pi as a "Hey Jarvis" speaker. Run as: curl -sSL '<link from the hub logs>' | sudo bash
set -e
HUB_HOST="__HUB_HOST__"
HUB_PORT="__HUB_PORT__"
HUB_TOKEN="__HUB_TOKEN__"
HTTP_PORT="__HTTP_PORT__"

echo "== Installing sound tools"
apt-get update -qq
apt-get install -y -qq alsa-utils python3 curl >/dev/null

echo "== Finding the USB microphone / speakerphone"
MIC_CARD=$(arecord -l 2>/dev/null | awk '/^card [0-9]+:/ && tolower($0) ~ /usb|jabra|respeaker|emeet|anker|seeed|audio/ {gsub(":","",$2); print $2; exit}')
if [ -z "$MIC_CARD" ]; then
  MIC_CARD=$(arecord -l 2>/dev/null | awk '/^card [0-9]+:/ {gsub(":","",$2); print $2; exit}')
fi
if [ -z "$MIC_CARD" ]; then
  echo "!! No microphone found. Plug in the USB microphone / speakerphone and run this again."
  exit 1
fi
# Play through the same USB device when it has a speaker (speakerphone, or a speaker plugged into the ReSpeaker);
# otherwise through the Pi's own headphone socket.
if aplay -l 2>/dev/null | grep -q "^card $MIC_CARD:"; then SPK_CARD=$MIC_CARD; else SPK_CARD=0; fi
echo "   microphone: card $MIC_CARD, speaker: card $SPK_CARD"
cat > /etc/asound.conf <<EOF
pcm.!default {
  type asym
  playback.pcm "plug:hw:$SPK_CARD"
  capture.pcm "plug:hw:$MIC_CARD"
}
ctl.!default {
  type hw
  card $SPK_CARD
}
EOF
# Sensible levels (not every device has these controls).
for control in Mic Capture; do amixer -q -c "$MIC_CARD" sset "$control" 85% cap 2>/dev/null || true; done
for control in Speaker PCM Master Headphone; do amixer -q -c "$SPK_CARD" sset "$control" 85% unmute 2>/dev/null || true; done

echo "== Installing the Jarvis speaker service"
mkdir -p /opt/jarvis-voice
curl -sSL "http://$HUB_HOST:$HTTP_PORT/pi/client.py?token=$HUB_TOKEN" -o /opt/jarvis-voice/jarvis-pi.py
cat > /etc/jarvis-voice.env <<EOF
HUB_HOST=$HUB_HOST
HUB_PORT=$HUB_PORT
HUB_TOKEN=$HUB_TOKEN
SATELLITE_NAME=$(hostname)
EOF
chmod 600 /etc/jarvis-voice.env
cat > /etc/systemd/system/jarvis-voice.service <<EOF
[Unit]
Description=Jarvis voice speaker
After=network-online.target sound.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/jarvis-voice.env
ExecStart=/usr/bin/python3 -u /opt/jarvis-voice/jarvis-pi.py
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now jarvis-voice.service
sleep 3
systemctl --no-pager --lines=5 status jarvis-voice.service || true
echo
echo "== Done. You should hear \"Jarvis is listening\" in a moment. Then say \"Hey Jarvis\"."
echo "   Logs: journalctl -u jarvis-voice -f"
'''


class InstallerHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/tts":
            return self.reply(404, b"Not found", "text/plain")
        length = min(int(self.headers.get("Content-Length") or 0), 20000)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        token = (urllib.parse.parse_qs(parsed.query).get("token") or [""])[0] or str(body.get("token") or "")
        self.tts(token, str(body.get("text") or ""))

    def tts(self, token, text):
        """The Jarvis voice for the iPhone app."""
        if not secrets.compare_digest(token, TOKEN):
            return self.reply(403, b"Wrong key", "text/plain")
        text = text.strip()[:2000]
        if not text:
            return self.reply(400, b"No text", "text/plain")
        wav = speak(text)
        if not wav:
            return self.reply(500, b"Couldn't make speech", "text/plain")
        self.reply(200, wav, "audio/wav")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        token = (urllib.parse.parse_qs(parsed.query).get("token") or [""])[0]
        if parsed.path == "/health":
            return self.reply(200, b"ok", "text/plain")
        if parsed.path == "/tts":
            return self.tts(token, (urllib.parse.parse_qs(parsed.query).get("text") or [""])[0])
        if parsed.path not in ("/pi/setup.sh", "/pi/client.py"):
            return self.reply(404, b"Not found", "text/plain")
        if not secrets.compare_digest(token, TOKEN):
            return self.reply(403, b"echo 'Wrong key: copy the command from the jarvis-voice app logs again.'; exit 1\n", "text/plain")
        if parsed.path == "/pi/client.py":
            return self.reply(200, PI_CLIENT.encode(), "text/x-python")
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        script = (PI_SETUP.replace("__HUB_HOST__", host).replace("__HUB_PORT__", str(AUDIO_PORT))
                  .replace("__HUB_TOKEN__", TOKEN).replace("__HTTP_PORT__", str(HTTP_PORT)))
        self.reply(200, script.encode(), "text/x-shellscript")

    def reply(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), InstallerHandler).serve_forever, daemon=True).start()
    log("Jarvis voice hub ready. Jarvis core: %s%s" % (JARVIS_URL, JARVIS_PATH))
    log("To set up the Raspberry Pi, run this on the Pi (use your NAS's IP address):")
    log("  curl -sSL 'http://<NAS-IP>:%d/pi/setup.sh?token=%s' | sudo bash" % (HTTP_PORT, TOKEN))
    log("For the same voice in the Jarvis iPhone app (Settings > Voice): address http://<NAS-IP>:%d, key %s"
        % (HTTP_PORT, TOKEN))
    AudioServer(("0.0.0.0", AUDIO_PORT), AudioHandler).serve_forever()


if __name__ == "__main__":
    main()
