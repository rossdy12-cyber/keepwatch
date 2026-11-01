"""Frigate -> ntfy notifier.

Listens to Frigate's MQTT events and sends one push notification per detection to an ntfy topic,
with the event's snapshot attached. Configured entirely with environment variables (see compose.yaml).

Needs only the paho-mqtt package; everything else is the Python standard library.
"""

import json
import logging
import os
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict

import paho.mqtt.client as mqtt

log = logging.getLogger("frigate-ntfy")


def env(name, default=""):
    return os.environ.get(name, default).strip()


def env_list(name):
    return [item.strip().lower() for item in env(name).split(",") if item.strip()]


class Config:
    def __init__(self):
        self.mqtt_host = env("MQTT_HOST", "100.85.127.42")
        self.mqtt_port = int(env("MQTT_PORT", "1883"))
        self.mqtt_user = env("MQTT_USER")
        self.mqtt_password = env("MQTT_PASSWORD")
        self.topic_prefix = env("FRIGATE_TOPIC_PREFIX", "frigate")

        self.frigate_url = env("FRIGATE_URL", "https://100.85.127.42:8971").rstrip("/")
        self.frigate_user = env("FRIGATE_USER")
        self.frigate_password = env("FRIGATE_PASSWORD")
        self.click_url = env("CLICK_URL", self.frigate_url + "/review")

        self.ntfy_server = env("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
        self.ntfy_topic = env("NTFY_TOPIC")
        self.ntfy_token = env("NTFY_TOKEN")
        self.ntfy_priority = env("NTFY_PRIORITY", "high")

        self.cameras = env_list("CAMERAS")          # empty = every camera
        self.labels = env_list("LABELS")            # empty = every object type
        self.zones = env_list("ZONES")              # empty = anywhere in the picture
        self.min_score = float(env("MIN_SCORE", "0") or 0)
        self.cooldown = float(env("COOLDOWN_SECONDS", "60") or 0)
        self.snapshot_wait = float(env("SNAPSHOT_WAIT_SECONDS", "4") or 0)

    def check(self):
        problems = []
        if not self.ntfy_topic or self.ntfy_topic.upper().startswith("CHANGE-ME"):
            problems.append("Set NTFY_TOPIC to your own long, hard-to-guess topic name.")
        return problems


def title_case(text):
    return text.replace("_", " ").replace("-", " ").title()


def ascii_header(text):
    """HTTP headers must be plain ASCII; ntfy shows them as-is."""
    return text.encode("ascii", "replace").decode("ascii")


LABEL_TAGS = {
    "person": "bust_in_silhouette",
    "car": "red_car",
    "motorcycle": "motorcycle",
    "bicycle": "bike",
    "dog": "dog",
    "cat": "cat",
    "bird": "bird",
    "package": "package",
}


class FrigateHTTP:
    """Fetches event snapshots from Frigate's API, logging in when the port needs it (8971 does)."""

    def __init__(self, config):
        self.config = config
        self.cookie = None
        self.lock = threading.Lock()
        # Frigate ships with a self-signed certificate on 8971, so don't verify it.
        self.ssl = ssl.create_default_context()
        self.ssl.check_hostname = False
        self.ssl.verify_mode = ssl.CERT_NONE

    def _open(self, request, timeout=10):
        return urllib.request.urlopen(request, timeout=timeout, context=self.ssl)

    def login(self):
        if not (self.config.frigate_user and self.config.frigate_password):
            return False
        body = json.dumps({"user": self.config.frigate_user, "password": self.config.frigate_password}).encode()
        request = urllib.request.Request(self.config.frigate_url + "/api/login", data=body, method="POST",
                                         headers={"Content-Type": "application/json"})
        try:
            with self._open(request) as response:
                for header in response.headers.get_all("Set-Cookie") or []:
                    name_value = header.split(";", 1)[0]
                    if name_value.startswith("frigate_token="):
                        self.cookie = name_value
                        return True
        except (urllib.error.URLError, OSError) as error:
            log.warning("Frigate login failed: %s", error)
        return False

    def snapshot(self, event_id):
        if not self.config.frigate_url:
            return None
        path = "/api/events/%s/snapshot.jpg?bbox=1" % urllib.parse.quote(event_id)
        for attempt in range(2):
            with self.lock:
                if attempt == 1 or (self.cookie is None and self.config.frigate_user):
                    if not self.login():
                        return None
                headers = {"Cookie": self.cookie} if self.cookie else {}
            try:
                with self._open(urllib.request.Request(self.config.frigate_url + path, headers=headers)) as response:
                    data = response.read()
                    if data[:2] == b"\xff\xd8":  # JPEG
                        return data
                    return None
            except urllib.error.HTTPError as error:
                if error.code in (401, 403) and attempt == 0 and self.config.frigate_user:
                    continue
                log.info("No snapshot from Frigate for %s (HTTP %s)", event_id, error.code)
                return None
            except (urllib.error.URLError, OSError) as error:
                log.info("Couldn't fetch snapshot for %s: %s", event_id, error)
                return None
        return None


class Notifier:
    def __init__(self, config, publish=None, frigate=None, clock=time.time):
        self.config = config
        self.publish = publish or self.send_to_ntfy
        self.frigate = frigate or FrigateHTTP(config)
        self.clock = clock
        self.lock = threading.Lock()
        self.notified = OrderedDict()   # event id -> time, so each event notifies once
        self.pending = {}               # event id -> timer waiting for a snapshot
        self.last_sent = {}             # (camera, label) -> time, for the cooldown
        self.mqtt_snapshots = {}        # (camera, label) -> latest JPEG from MQTT

    # MARK: Filtering

    def wanted(self, event):
        camera = str(event.get("camera", "")).lower()
        label = str(event.get("label", "")).lower()
        if event.get("false_positive"):
            return False
        if self.config.cameras and camera not in self.config.cameras:
            return False
        if self.config.labels and label not in self.config.labels:
            return False
        score = event.get("top_score") or event.get("score") or 0
        if score < self.config.min_score:
            return False
        if self.config.zones:
            zones = [str(z).lower() for z in (event.get("entered_zones") or []) + (event.get("current_zones") or [])]
            if not any(zone in self.config.zones for zone in zones):
                return False
        return True

    # MARK: MQTT handlers

    def on_event(self, payload):
        try:
            message = json.loads(payload)
        except (ValueError, TypeError):
            return
        kind = message.get("type")
        event = message.get("after") or {}
        event_id = event.get("id")
        if not event_id or kind not in ("new", "update", "end"):
            return
        with self.lock:
            if event_id in self.notified:
                return
            if not self.wanted(event):
                return
            ready = bool(event.get("has_snapshot")) or kind == "end" or self.config.snapshot_wait <= 0
            if not ready:
                # Give Frigate a moment to pick a snapshot, but notify anyway if it doesn't.
                if event_id not in self.pending:
                    timer = threading.Timer(self.config.snapshot_wait, self._fire, args=(event_id, event))
                    timer.daemon = True
                    self.pending[event_id] = timer
                    timer.start()
                return
            self._claim(event_id)
        self._notify(event)

    def on_snapshot(self, topic, payload):
        # frigate/<camera>/<label>/snapshot
        parts = topic.split("/")
        if len(parts) >= 4 and payload[:2] == b"\xff\xd8":
            self.mqtt_snapshots[(parts[-3].lower(), parts[-2].lower())] = payload

    def _fire(self, event_id, event):
        with self.lock:
            if event_id in self.notified:
                return
            self._claim(event_id)
        self._notify(event)

    def _claim(self, event_id):
        """Marks an event as notified. Call with the lock held."""
        timer = self.pending.pop(event_id, None)
        if timer:
            timer.cancel()
        self.notified[event_id] = self.clock()
        while len(self.notified) > 500:
            self.notified.popitem(last=False)

    # MARK: Sending

    def _notify(self, event):
        camera = str(event.get("camera", "camera"))
        label = str(event.get("label", "object"))
        key = (camera.lower(), label.lower())
        now = self.clock()
        if self.config.cooldown > 0 and now - self.last_sent.get(key, 0) < self.config.cooldown:
            log.info("Skipping %s on %s (cooldown)", label, camera)
            return
        self.last_sent[key] = now

        sub_label = event.get("sub_label")
        if isinstance(sub_label, list):
            sub_label = sub_label[0] if sub_label else None
        what = title_case(str(sub_label)) if sub_label else title_case(label)
        title = "%s on %s" % (what, title_case(camera))
        score = event.get("top_score") or event.get("score")
        zones = event.get("entered_zones") or event.get("current_zones") or []
        details = []
        if zones:
            details.append("in " + ", ".join(title_case(str(z)) for z in zones))
        if score:
            details.append("%d%% sure" % round(float(score) * 100))
        details.append(time.strftime("%H:%M:%S", time.localtime(event.get("start_time") or now)))
        message = " - ".join(details)

        image = None
        if event.get("id"):
            image = self.frigate.snapshot(event["id"])
        if image is None:
            image = self.mqtt_snapshots.get(key)
        self.publish(title=title, message=message, tags=LABEL_TAGS.get(label.lower(), "rotating_light"),
                     image=image, event_id=event.get("id"))

    def send_to_ntfy(self, title, message, tags, image=None, event_id=None):
        url = "%s/%s" % (self.config.ntfy_server, urllib.parse.quote(self.config.ntfy_topic))
        headers = {
            "Title": ascii_header(title),
            "Tags": tags,
            "Priority": self.config.ntfy_priority,
        }
        if self.config.click_url:
            headers["Click"] = self.config.click_url
        if self.config.ntfy_token:
            headers["Authorization"] = "Bearer " + self.config.ntfy_token
        if image:
            headers["Message"] = ascii_header(message)
            headers["Filename"] = "snapshot.jpg"
            body = image
            method = "PUT"
        else:
            body = message.encode("utf-8")
            method = "POST"
        request = urllib.request.Request(url, data=body, method=method, headers=headers)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    response.read()
                log.info("Sent: %s (%s)%s", title, message, " with snapshot" if image else "")
                return True
            except urllib.error.HTTPError as error:
                detail = error.read()[:300].decode("utf-8", "replace")
                log.error("ntfy refused the notification (HTTP %s): %s", error.code, detail)
                if error.code == 413 and image:
                    # Attachment too big for this server: send without it.
                    return self.send_to_ntfy(title, message, tags, None, event_id)
                if error.code < 500:
                    return False
            except (urllib.error.URLError, OSError) as error:
                log.warning("Couldn't reach ntfy (try %d): %s", attempt + 1, error)
            time.sleep(2 * (attempt + 1))
        return False


def main():
    logging.basicConfig(level=env("LOG_LEVEL", "INFO").upper(), format="%(asctime)s %(levelname)s %(message)s",
                        stream=sys.stdout)
    config = Config()
    problems = config.check()
    if problems:
        for problem in problems:
            log.error(problem)
        sys.exit(1)

    notifier = Notifier(config)
    events_topic = config.topic_prefix + "/events"
    snapshot_topic = config.topic_prefix + "/+/+/snapshot"

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="frigate-ntfy-%d" % os.getpid())
    if config.mqtt_user:
        client.username_pw_set(config.mqtt_user, config.mqtt_password or None)

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            log.error("MQTT broker refused the connection: %s (check MQTT_USER / MQTT_PASSWORD)", reason_code)
            return
        log.info("Connected to MQTT at %s:%s, watching %s", config.mqtt_host, config.mqtt_port, events_topic)
        client.subscribe([(events_topic, 0), (snapshot_topic, 0)])

    def on_disconnect(client, userdata, flags, reason_code, properties):
        log.warning("MQTT disconnected (%s); reconnecting", reason_code)

    def on_message(client, userdata, msg):
        try:
            if msg.topic == events_topic:
                notifier.on_event(msg.payload)
            elif msg.topic.endswith("/snapshot"):
                notifier.on_snapshot(msg.topic, msg.payload)
        except Exception:  # never let one bad message stop the notifier
            log.exception("Error handling %s", msg.topic)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=2, max_delay=60)

    log.info("Cameras: %s. Objects: %s. Sending to %s/%s",
             ", ".join(config.cameras) or "all", ", ".join(config.labels) or "all",
             config.ntfy_server, config.ntfy_topic)
    if env("SEND_TEST", "true").lower() in ("1", "true", "yes"):
        notifier.send_to_ntfy("Frigate notifier is running",
                              "You'll get a notification here when a camera spots something.", "white_check_mark")

    while True:
        try:
            client.connect(config.mqtt_host, config.mqtt_port, keepalive=60)
            break
        except OSError as error:
            log.error("Can't reach the MQTT broker at %s:%s (%s); retrying in 15 s",
                      config.mqtt_host, config.mqtt_port, error)
            time.sleep(15)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()
