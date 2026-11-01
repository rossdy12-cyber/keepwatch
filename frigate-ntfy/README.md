# Frigate → ntfy notifier

Sends a push notification to your iPhone every time Frigate spots something on a camera, with the snapshot attached:

> **Person on Tapo C200**
> in Front Door - 85% sure - 18:42:07  *(plus the snapshot)*

It listens to Frigate's MQTT messages (`frigate/events`), so alerts arrive within a second or two.
By default every camera and every object type notifies you (so both the Tapo and the EZVIZ camera),
with at most one alert per camera and object type per minute.

## 1. Set up the iPhone

1. Install **ntfy** from the App Store (free).
2. Tap **+**, and subscribe to a topic with a long, random name, e.g. `cams-k7f2q9x4m1`.
   Use **ntfy.sh** as the server. Allow notifications when asked.

Anyone who knows the topic name can read your alerts and snapshots, so don't use anything guessable.

## 2. Install it on TrueNAS

1. **Apps → Discover Apps →** the three dots (⋮) **→ Install via YAML**.
2. Name: `frigate-ntfy`. Paste the whole of [`compose.yaml`](compose.yaml).
3. Change these lines before saving:
   - `NTFY_TOPIC`: the topic you subscribed to in step 1.
   - `MQTT_HOST` / `MQTT_PORT`: the broker in Frigate's config (`mqtt: host:` / `port:`). If Frigate's
     config has `user:` and `password:` under `mqtt:`, copy them into `MQTT_USER` / `MQTT_PASSWORD`.
   - `FRIGATE_USER` / `FRIGATE_PASSWORD` *(optional)*: a Frigate login (Frigate → Settings → Users; a "viewer" user is
     enough). With it, each alert carries that exact event's snapshot with a box around the object. Without it, the
     notifier uses the latest snapshot Frigate posted over MQTT, which is usually the same picture.
4. **Save.** Within a minute your phone gets **"Frigate notifier is running"**.

Check **Apps → frigate-ntfy → Logs** if it doesn't: it says exactly what failed (wrong broker address,
MQTT password refused, ntfy topic not set).

## Fine-tuning (in the app's YAML: Apps → frigate-ntfy → Edit)

| Setting | Example | What it does |
|---|---|---|
| `CAMERAS` | `tapo_c200,ezviz` | Only these cameras (Frigate's camera names). Empty = all. |
| `LABELS` | `person,car` | Only these objects. Empty = all. |
| `ZONES` | `driveway` | Only when the object is in one of these Frigate zones. |
| `MIN_SCORE` | `0.7` | Ignore detections Frigate is less sure about. |
| `COOLDOWN_SECONDS` | `300` | Quieter: one alert per camera and object every 5 minutes. |
| `CLICK_URL` | `https://100.85.127.42:8971/review` | What opens when you tap the notification (default: Frigate's Review page). |
| `SEND_TEST` | `false` | Don't send the "running" message on start. |

## Notes

- **Privacy:** snapshots pass through the public ntfy.sh server (kept for a few hours). For full privacy, run the
  ntfy app on TrueNAS and set `NTFY_SERVER` to it (it needs `upstream-base-url: https://ntfy.sh` for iPhone pushes).
- ntfy.sh's free tier allows about 250 messages a day per home connection; the cooldown keeps you well under it.
- `compose.yaml` is generated: edit `notifier.py`, then run `python3 build_compose.py`.
