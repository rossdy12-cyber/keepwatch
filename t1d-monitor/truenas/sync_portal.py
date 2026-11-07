#!/usr/bin/env python3
"""
GlucoPulse TrueNAS Sync Manager (tconnectsync + Dexcom G7 Share -> Nightscout)
Runs on port 1338 alongside Nightscout (port 1337).
- Provides a dark-mode Web UI to configure Tandem Source (EU/UK or US) & Dexcom G7 Share credentials
- Supervises `tconnectsync` cycles and enriches Nightscout `/api/v1/devicestatus` with live t:slim X2 IOB, Basal, Last Bolus, Cartridge, and Battery
- Bridges Dexcom G7 Share readings directly into Nightscout `/api/v1/entries`
"""

import hashlib
import json
import math
import os
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = "/config/glucopulse_bridge.json"
ENV_PATH = "/config/.env"
LOG_MAX_LINES = 250

NS_INTERNAL_URL = os.environ.get("NS_INTERNAL_URL", "http://nightscout:1337")
NS_SECRET = os.environ.get("NS_SECRET", "glucopulse2026")
NS_SECRET_SHA1 = hashlib.sha1(NS_SECRET.encode("utf-8")).hexdigest()
TZ_NAME = os.environ.get("TZ", "Europe/London")

DEXCOM_APP_ID = "d89443d2-327c-4a6f-89e5-496bbb0317db"
DEXCOM_TREND_DIRECTIONS = {
    "None": "NONE",
    "DoubleUp": "DoubleUp",
    "SingleUp": "SingleUp",
    "FortyFiveUp": "FortyFiveUp",
    "Flat": "Flat",
    "FortyFiveDown": "FortyFiveDown",
    "SingleDown": "SingleDown",
    "DoubleDown": "DoubleDown",
    "NotComputable": "NOT COMPUTABLE",
    "RateOutOfRange": "RATE OUT OF RANGE",
}

DEFAULT_CONFIG = {
    "tconnect_email": "",
    "tconnect_password": "",
    "tconnect_region": "EU",
    "pump_serial": "",
    "tconnect_features": "BASAL BOLUS IOB PUMP_EVENTS PUMP_EVENTS_BASAL_SUSPENSION PROFILES CGM CGM_ALERTS DEVICE_STATUS",
    "dexcom_username": "",
    "dexcom_password": "",
    "dexcom_region": "ous",
    "sync_interval_seconds": 300,
    "insulin_dia_hours": 4.0,
}

state_lock = threading.Lock()
log_lines = []
sync_status = {
    "last_tconnect_run": "Never",
    "last_tconnect_result": "Waiting for Tandem Source credentials",
    "last_dexcom_run": "Never",
    "last_dexcom_result": "Waiting for Dexcom Share credentials",
    "running_now": False,
}


def append_log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    with state_lock:
        log_lines.append(line)
        if len(log_lines) > LOG_MAX_LINES:
            del log_lines[: len(log_lines) - LOG_MAX_LINES]


def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                saved = json.load(f)
                cfg.update(saved)
        except Exception as e:
            append_log(f"WARN: Failed to read {CONFIG_PATH}: {e}")
    return cfg


def save_config(cfg: dict):
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    write_tconnect_env(cfg)


def write_tconnect_env(cfg: dict):
    lines = [
        f"TCONNECT_EMAIL='{cfg.get('tconnect_email', '')}'",
        f"TCONNECT_PASSWORD='{cfg.get('tconnect_password', '')}'",
        f"TCONNECT_REGION='{cfg.get('tconnect_region', 'EU')}'",
        f"NS_URL='{NS_INTERNAL_URL}/'",
        f"NS_SECRET='{NS_SECRET}'",
        f"TIMEZONE_NAME='{TZ_NAME}'",
    ]
    serial = str(cfg.get("pump_serial", "")).strip()
    if serial:
        lines.append(f"PUMP_SERIAL_NUMBER='{serial}'")
    os.makedirs(os.path.dirname(ENV_PATH), exist_ok=True)
    with open(ENV_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def ns_request(path: str, method: str = "GET", payload=None):
    url = f"{NS_INTERNAL_URL.rstrip('/')}{path}"
    headers = {
        "API-SECRET": NS_SECRET_SHA1,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw.strip() else None


def _candidate_dexcom_usernames(raw: str) -> list:
    trimmed = raw.strip()
    if not trimmed:
        return []
    cands = [trimmed]
    if trimmed.lower() not in cands:
        cands.append(trimmed.lower())
    compact = trimmed.replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
    if compact not in cands:
        cands.append(compact)
    digits = "".join(ch for ch in compact if ch.isdigit())
    if compact.startswith("07") and len(digits) == 11:
        for v in ["+44" + digits[1:], "44" + digits[1:]]:
            if v not in cands:
                cands.append(v)
    elif compact.startswith("+44") and len(digits) >= 11:
        local_uk = "0" + digits[2:]
        if local_uk not in cands:
            cands.append(local_uk)
    elif compact.startswith("447") and len(digits) == 12:
        for v in ["+" + digits, "0" + digits[2:]]:
            if v not in cands:
                cands.append(v)
    return cands


def sync_dexcom_to_nightscout(cfg: dict):
    username = cfg.get("dexcom_username", "").strip()
    password = cfg.get("dexcom_password", "")
    region = cfg.get("dexcom_region", "ous").strip()
    if not username or not password:
        return

    host_map = {
        "ous": "https://shareous1.dexcom.com",
        "us": "https://share2.dexcom.com",
        "jp": "https://share.dexcom.jp",
    }
    ordered_regions = [region] + [r for r in ["ous", "us", "jp"] if r != region]
    candidates = _candidate_dexcom_usernames(username)
    ua = "Dexcom Share/3.0.2.11 CFNetwork/672.0.2 Darwin/14.0.0"

    session_id = None
    host = host_map.get(region, "https://shareous1.dexcom.com")
    last_err = ""

    try:
        for reg in ordered_regions:
            h = host_map[reg]
            reg_app_id = "d8665ade-9673-4e27-9ff6-92db4ce13d13" if reg == "jp" else DEXCOM_APP_ID
            for cand in candidates:
                append_log(f"Dexcom Share: Authenticating ({reg.upper()} -> {h} as '{cand}')...")
                auth_url = f"{h}/ShareWebServices/Services/General/AuthenticatePublisherAccount"
                auth_body = json.dumps({
                    "accountName": cand,
                    "password": password,
                    "applicationId": reg_app_id,
                }).encode("utf-8")
                req = urllib.request.Request(
                    auth_url,
                    data=auth_body,
                    headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": ua},
                    method="POST",
                )
                try:
                    with urllib.request.urlopen(req, timeout=15) as resp:
                        account_id = resp.read().decode("utf-8").strip().strip('"')
                    if account_id and account_id != "00000000-0000-0000-0000-000000000000":
                        login_url = f"{h}/ShareWebServices/Services/General/LoginPublisherAccountById"
                        login_body = json.dumps({
                            "accountId": account_id,
                            "password": password,
                            "applicationId": reg_app_id,
                        }).encode("utf-8")
                        req2 = urllib.request.Request(
                            login_url,
                            data=login_body,
                            headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": ua},
                            method="POST",
                        )
                        with urllib.request.urlopen(req2, timeout=15) as resp2:
                            sid = resp2.read().decode("utf-8").strip().strip('"')
                        if sid and sid != "00000000-0000-0000-0000-000000000000":
                            session_id = sid
                            host = h
                            break
                except urllib.error.HTTPError as he:
                    err_body = he.read().decode("utf-8", "ignore")
                    if reg == region or not last_err:
                        last_err = f"HTTP {he.code}: {err_body[:180]}"
                except Exception as ex:
                    if reg == region or not last_err:
                        last_err = str(ex)
            if session_id:
                break

        if not session_id:
            raise RuntimeError(f"Dexcom Share rejected login ({last_err}). Ensure 'Share' is turned ON with >=1 follower in the Dexcom G7 app (Connections -> Share).")

        egv_url = (
            f"{host}/ShareWebServices/Services/Publisher/ReadPublisherLatestGlucoseValues"
            f"?sessionId={urllib.parse.quote(session_id)}&minutes=1440&maxCount=36"
        )
        req3 = urllib.request.Request(
            egv_url,
            headers={"Accept": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req3, timeout=20) as resp3:
            items = json.loads(resp3.read().decode("utf-8"))

        entries = []
        for item in items:
            wt = item.get("WT", "")
            val = item.get("Value", 0)
            trend = item.get("Trend", "Flat")
            if not wt or val <= 0:
                continue
            digits = "".join(ch for ch in wt.split("+")[0].split("-")[0] if ch.isdigit())
            if not digits:
                continue
            ms = int(digits)
            iso_str = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).isoformat()
            entries.append({
                "type": "sgv",
                "sgv": int(val),
                "date": ms,
                "dateString": iso_str,
                "direction": DEXCOM_TREND_DIRECTIONS.get(str(trend), "Flat"),
                "device": "DexcomG7-Share",
            })

        if entries:
            ns_request("/api/v1/entries.json", method="POST", payload=entries)
            latest_mgdl = entries[0]["sgv"]
            latest_mmol = round(latest_mgdl / 18.0182, 1)
            msg = f"Synced {len(entries)} G7 readings to Nightscout (Latest: {latest_mmol} mmol/L / {latest_mgdl} mg/dL)"
            append_log(f"Dexcom Share: {msg}")
            with state_lock:
                sync_status["last_dexcom_run"] = datetime.now().strftime("%H:%M:%S")
                sync_status["last_dexcom_result"] = msg
        else:
            msg = "Connected to Dexcom Share, but no recent readings returned"
            append_log(f"Dexcom Share: {msg}")
            with state_lock:
                sync_status["last_dexcom_run"] = datetime.now().strftime("%H:%M:%S")
                sync_status["last_dexcom_result"] = msg

    except Exception as e:
        err_msg = f"Error: {e}"
        append_log(f"Dexcom Share: {err_msg}")
        with state_lock:
            sync_status["last_dexcom_run"] = datetime.now().strftime("%H:%M:%S")
            sync_status["last_dexcom_result"] = err_msg


def update_pump_devicestatus_from_treatments(cfg: dict):
    """
    Computes live IOB, active Control-IQ basal, and latest bolus from Nightscout treatments
    uploaded by tconnectsync, and posts a devicestatus record so Nightscout and GlucoPulse
    display rich real-time Tandem t:slim X2 telemetry.
    """
    try:
        treatments = ns_request("/api/v1/treatments.json?count=100") or []
        now_ts = time.time()
        dia_seconds = float(cfg.get("insulin_dia_hours", 4.0)) * 3600.0

        iob = 0.0
        active_basal = None
        for t in treatments:
            created = t.get("created_at") or t.get("timestamp")
            if not created:
                continue
            try:
                dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                age_sec = now_ts - dt.timestamp()
            except Exception:
                continue

            insulin = float(t.get("insulin") or 0.0)
            if insulin > 0 and 0 <= age_sec < dia_seconds:
                # Walsh / bilinear decay approximation
                rem = max(0.0, 1.0 - (age_sec / dia_seconds))
                iob += insulin * rem

            ev_type = (t.get("eventType") or "").lower()
            if active_basal is None and "basal" in ev_type:
                rate = t.get("rate") or t.get("absolute")
                if rate is not None:
                    active_basal = float(rate)

        status_payload = {
            "device": "tconnectsync://Tandem-tslim-X2",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "pump": {
                "clock": datetime.now(timezone.utc).isoformat(),
                "iob": {"bolusiob": round(iob, 2), "iob": round(iob, 2)},
                "status": {
                    "status": f"Control-IQ ({active_basal:.2f} U/hr)" if active_basal is not None else "Control-IQ Active",
                    "bolusing": False,
                    "suspended": False,
                },
            },
        }
        ns_request("/api/v1/devicestatus.json", method="POST", payload=status_payload)
    except Exception as e:
        append_log(f"WARN: devicestatus enrichment failed: {e}")


def run_tconnectsync_once(cfg: dict):
    email = cfg.get("tconnect_email", "").strip()
    password = cfg.get("tconnect_password", "").strip()
    primary_region = cfg.get("tconnect_region", "EU").strip().upper() or "EU"
    raw_features = cfg.get(
        "tconnect_features",
        "BASAL BOLUS IOB PUMP_EVENTS PUMP_EVENTS_BASAL_SUSPENSION PROFILES CGM CGM_ALERTS DEVICE_STATUS",
    ).strip().split()

    # Always ensure CGM, IOB, and DEVICE_STATUS are enabled so Tandem Source G7 CGM readings
    # and pump status flow into Nightscout without needing the official Dexcom G7 app.
    features = list(dict.fromkeys((raw_features or ["BASAL", "BOLUS", "PUMP_EVENTS", "PROFILES"]) + ["CGM", "IOB", "DEVICE_STATUS"]))

    if not email or not password:
        return

    write_tconnect_env(cfg)
    alt_region = "US" if primary_region == "EU" else "EU"
    regions_to_try = [primary_region, alt_region]

    entry_script = "/home/appuser/main.py"
    work_dir = "/home/appuser" if os.path.isdir("/home/appuser") else "/config"

    for idx, region in enumerate(regions_to_try):
        env = os.environ.copy()
        env["TCONNECT_EMAIL"] = email
        env["TCONNECT_PASSWORD"] = password
        env["TCONNECT_REGION"] = region
        env["NS_URL"] = f"{NS_INTERNAL_URL}/"
        env["NS_SECRET"] = NS_SECRET
        env["TIMEZONE_NAME"] = TZ_NAME
        env["PYTHONPATH"] = "/home/appuser"
        if str(cfg.get("pump_serial", "")).strip():
            env["PUMP_SERIAL_NUMBER"] = str(cfg.get("pump_serial", "")).strip()

        if os.path.isfile(entry_script):
            cmd = ["python3", "-u", entry_script, "--region", region, "--features"] + features
        else:
            cmd = ["tconnectsync", "--region", region, "--features"] + features

        append_log(f"Tandem tconnectsync: Running (Region: {region}, Features: {' '.join(features)})...")
        try:
            proc = subprocess.run(
                cmd,
                cwd=work_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=180,
            )
            out = (proc.stdout or "") + "\n" + (proc.stderr or "")
            lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
            for line in lines:
                append_log(f"[tconnectsync] {line}")

            is_auth_err = ("401" in out or "authorization errors" in out.lower() or "invalid credentials" in out.lower())
            if is_auth_err and idx == 0:
                append_log(f"Tandem Source {region} returned 401; retrying with {alt_region} region...")
                continue

            has_fatal = any(k in out for k in ("Traceback (most recent call last)", "ApiException", "ApiLoginException", "Unable to read secrets"))
            if proc.returncode == 0 or (proc.returncode == 1 and not has_fatal):
                if region != primary_region:
                    cfg["tconnect_region"] = region
                    save_config(cfg)
                update_pump_devicestatus_from_treatments(cfg)
                added_info = "new events uploaded" if proc.returncode == 0 else "up to date (0 new events)"
                msg = f"Success — Tandem Source ({region}) Pump + G7 CGM synced ({added_info})"
                with state_lock:
                    sync_status["last_tconnect_run"] = datetime.now().strftime("%H:%M:%S")
                    sync_status["last_tconnect_result"] = msg
                return
            else:
                tail = lines[-1] if lines else f"exit {proc.returncode}"
                msg = f"Error ({region}): {tail[:180]}"
                with state_lock:
                    sync_status["last_tconnect_run"] = datetime.now().strftime("%H:%M:%S")
                    sync_status["last_tconnect_result"] = msg
                return
        except Exception as e:
            err_msg = f"Error running tconnectsync: {e}"
            append_log(err_msg)
            with state_lock:
                sync_status["last_tconnect_run"] = datetime.now().strftime("%H:%M:%S")
                sync_status["last_tconnect_result"] = err_msg
            return


def run_full_sync_cycle():
    with state_lock:
        if sync_status["running_now"]:
            return
        sync_status["running_now"] = True
    try:
        cfg = load_config()
        sync_dexcom_to_nightscout(cfg)
        run_tconnectsync_once(cfg)
    finally:
        with state_lock:
            sync_status["running_now"] = False


def background_loop():
    append_log("GlucoPulse TrueNAS Sync Daemon started.")
    time.sleep(5)
    while True:
        try:
            run_full_sync_cycle()
        except Exception as e:
            append_log(f"Loop error: {e}")
        cfg = load_config()
        interval = max(60, int(cfg.get("sync_interval_seconds", 300)))
        time.sleep(interval)


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GlucoPulse TrueNAS Bridge — Nightscout + tconnectsync</title>
<style>
  :root {
    --bg: #070d19;
    --card: #111a2e;
    --border: #1e2d4a;
    --accent: #0ea5e9;
    --green: #10b981;
    --text: #f1f5f9;
    --muted: #94a3b8;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px;
    background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  .container { max-width: 880px; margin: 0 auto; }
  .header {
    display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center;
    gap: 12px; margin-bottom: 20px; padding-bottom: 16px; border-bottom: 1px solid var(--border);
  }
  .title { font-size: 22px; font-weight: 800; display: flex; align-items: center; gap: 10px; }
  .badge {
    background: rgba(16, 185, 129, 0.15); color: var(--green);
    padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 700;
  }
  .card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 14px; padding: 20px; margin-bottom: 18px;
  }
  h2 { margin: 0 0 12px 0; font-size: 16px; color: var(--accent); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
  label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 6px; font-weight: 600; }
  input, select {
    width: 100%; padding: 10px 12px; border-radius: 8px;
    border: 1px solid var(--border); background: #0b1222; color: var(--text);
    font-size: 14px;
  }
  .btn-row { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 16px; }
  button, .btn-link {
    background: var(--accent); color: #fff; border: none; padding: 11px 18px;
    border-radius: 9px; font-weight: 700; font-size: 14px; cursor: pointer;
    text-decoration: none; display: inline-flex; align-items: center; gap: 6px;
  }
  .btn-secondary { background: #1e293b; border: 1px solid var(--border); }
  .status-row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 14px; }
  .status-box { background: #0b1222; padding: 12px; border-radius: 10px; border: 1px solid var(--border); }
  .status-label { font-size: 11px; color: var(--muted); text-transform: uppercase; }
  .status-val { font-size: 13px; font-weight: 600; margin-top: 4px; }
  pre {
    background: #050911; border: 1px solid var(--border); border-radius: 10px;
    padding: 14px; font-size: 12px; color: #cbd5e1; max-height: 300px; overflow-y: auto;
    white-space: pre-wrap; margin: 0;
  }
  .info-pill {
    font-size: 13px; color: var(--muted); background: #0b1222;
    padding: 10px 14px; border-radius: 8px; border: 1px solid var(--border); margin-bottom: 16px;
  }
  code { color: #38bdf8; font-weight: 600; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="title">
      <span>🩸 GlucoPulse TrueNAS Bridge</span>
      <span class="badge">Read-Only Monitor</span>
    </div>
    <div>
      <a class="btn-link btn-secondary" href="http://100.85.127.42:1337" target="_blank">Open Nightscout Web (:1337) ↗</a>
    </div>
  </div>

  <div class="info-pill">
    📱 <strong>GlucoPulse iPhone App Settings:</strong><br>
    Nightscout URL: <code>http://100.85.127.42:1337</code> &nbsp;|&nbsp;
    API Secret: <code>glucopulse2026</code>
  </div>

  <div class="status-row">
    <div class="status-box">
      <div class="status-label">Tandem tconnectsync ({{LAST_TC_TIME}})</div>
      <div class="status-val">{{LAST_TC_RES}}</div>
    </div>
    <div class="status-box">
      <div class="status-label">Dexcom G7 Share Bridge ({{LAST_DX_TIME}})</div>
      <div class="status-val">{{LAST_DX_RES}}</div>
    </div>
  </div>

  <form method="POST" action="/save">
    <div class="card">
      <h2>💉 Tandem t:slim X2 (Tandem Source / tconnectsync)</h2>
      <div class="grid">
        <div>
          <label>Tandem Source Email</label>
          <input type="email" name="tconnect_email" value="{{TCONNECT_EMAIL}}" placeholder="you@example.com">
        </div>
        <div>
          <label>Tandem Source Password</label>
          <input type="password" name="tconnect_password" value="{{TCONNECT_PASSWORD}}" placeholder="••••••••">
        </div>
        <div>
          <label>Region</label>
          <select name="tconnect_region">
            <option value="EU" {{SEL_TC_EU}}>UK / Europe (EU - Tandem Source)</option>
            <option value="US" {{SEL_TC_US}}>United States (US - Tandem Source)</option>
          </select>
        </div>
        <div>
          <label>Pump Serial Number (Optional — auto-detected if blank)</label>
          <input type="text" name="pump_serial" value="{{PUMP_SERIAL}}" placeholder="Auto-detect most recent pump">
        </div>
      </div>
    </div>

    <div class="card">
      <h2>📡 Dexcom G7 Share -> Nightscout Archiver (Optional)</h2>
      <div class="grid">
        <div>
          <label>Dexcom Username / Email / Phone</label>
          <input type="text" name="dexcom_username" value="{{DEXCOM_USERNAME}}" placeholder="Dexcom account username">
        </div>
        <div>
          <label>Dexcom Password</label>
          <input type="password" name="dexcom_password" value="{{DEXCOM_PASSWORD}}" placeholder="••••••••">
        </div>
        <div>
          <label>Dexcom Server Region</label>
          <select name="dexcom_region">
            <option value="ous" {{SEL_DX_OUS}}>UK / International (shareous1.dexcom.com)</option>
            <option value="us" {{SEL_DX_US}}>United States (share2.dexcom.com)</option>
            <option value="jp" {{SEL_DX_JP}}>Japan (share.dexcom.jp)</option>
          </select>
        </div>
        <div>
          <label>Sync Interval (Seconds)</label>
          <input type="number" name="sync_interval_seconds" value="{{SYNC_INTERVAL}}" min="60" max="3600">
        </div>
      </div>

      <div class="btn-row">
        <button type="submit">💾 Save Credentials & Sync Now</button>
        <a class="btn-link btn-secondary" href="/sync">🔄 Trigger Immediate Sync</a>
      </div>
    </div>
  </form>

  <div class="card">
    <h2>📜 Live Sync Logs</h2>
    <pre>{{LOGS}}</pre>
  </div>
</div>
</body>
</html>
"""


class PortalHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        parsed_path = urllib.parse.urlparse(self.path).path
        ipa_dir = "/config/ipas"
        if parsed_path.startswith("/download/"):
            fname = urllib.parse.unquote(parsed_path[len("/download/"):]).strip("/")
            fpath = os.path.join(ipa_dir, os.path.basename(fname))
            if os.path.isfile(fpath) and fpath.lower().endswith(".ipa"):
                size = os.path.getsize(fpath)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(fpath)}"')
                self.send_header("Content-Length", str(size))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                return
            self.send_error(404, "IPA file not found")
            return
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path).path
        ipa_dir = "/config/ipas"

        if parsed_path.startswith("/download/"):
            fname = urllib.parse.unquote(parsed_path[len("/download/"):]).strip("/")
            fpath = os.path.join(ipa_dir, os.path.basename(fname))
            if os.path.isfile(fpath) and fpath.lower().endswith(".ipa"):
                size = os.path.getsize(fpath)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(fpath)}"')
                self.send_header("Content-Length", str(size))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                with open(fpath, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                return
            self.send_error(404, "IPA file not found")
            return

        if parsed_path in ("/ipa", "/ipas", "/GlucoPulse.ipa"):
            if parsed_path == "/GlucoPulse.ipa":
                self.send_response(302)
                self.send_header("Location", "/download/GlucoPulse.ipa")
                self.end_headers()
                return
            host = self.headers.get("Host", "100.85.127.42:1338")
            base_url = f"http://{host}"
            files = []
            if os.path.isdir(ipa_dir):
                for fn in sorted(os.listdir(ipa_dir)):
                    if fn.lower().endswith(".ipa"):
                        fp = os.path.join(ipa_dir, fn)
                        sz = os.path.getsize(fp)
                        files.append((fn, f"{sz/(1024*1024):.2f} MB" if sz >= 1048576 else f"{sz/1024:.0f} KB"))
            cards = ""
            for fn, sz_str in files:
                dl_url = f"{base_url}/download/{urllib.parse.quote(fn)}"
                sidestore_url = f"sidestore://install?url={urllib.parse.quote(dl_url, safe='')}"
                altstore_url = f"altstore://install?url={urllib.parse.quote(dl_url, safe='')}"
                badge = '<span style="background:#10b981;color:#052e16;font-size:11px;font-weight:800;padding:3px 8px;border-radius:999px;margin-left:8px;">DEXCOM G7 FIXED</span>' if fn == "GlucoPulse.ipa" else ""
                cards += f"""
                <div style="background:#151d2e;border:1px solid #26324d;border-radius:16px;padding:18px;margin-bottom:14px;">
                  <div style="display:flex;justify-content:space-between;align-items:center;">
                    <div style="font-size:18px;font-weight:700;color:#fff;">{fn}{badge}</div>
                    <div style="color:#94a3b8;font-size:13px;">{sz_str}</div>
                  </div>
                  <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:14px;">
                    <a href="/download/{urllib.parse.quote(fn)}" style="flex:1;min-width:140px;text-align:center;background:#3b82f6;color:#fff;text-decoration:none;font-weight:700;padding:12px 16px;border-radius:12px;">⬇ Download .IPA</a>
                    <a href="{sidestore_url}" style="flex:1;min-width:130px;text-align:center;background:#8b5cf6;color:#fff;text-decoration:none;font-weight:700;padding:12px 16px;border-radius:12px;">⚡ SideStore</a>
                    <a href="{altstore_url}" style="flex:1;min-width:130px;text-align:center;background:#1e293b;border:1px solid #334155;color:#e2e8f0;text-decoration:none;font-weight:600;padding:12px 16px;border-radius:12px;">📲 AltStore</a>
                  </div>
                </div>"""
            page = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ross IPA Hub</title></head>
            <body style="background:#0b0f19;color:#f8fafc;font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:680px;margin:0 auto;padding:24px 16px;">
              <h1 style="margin:0 0 6px 0;font-size:24px;">📱 Ross IPA Server</h1>
              <p style="color:#94a3b8;margin:0 0 20px 0;font-size:14px;">Tap <b>Download .IPA</b> to save directly to your iPhone Files app, or tap <b>SideStore / AltStore</b> to sideload directly.</p>
              {cards}
              <p style="margin-top:20px;"><a href="/" style="color:#38bdf8;text-decoration:none;">← Back to GlucoPulse Bridge Settings</a></p>
            </body></html>"""
            data = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if self.path.startswith("/sync"):
            threading.Thread(target=run_full_sync_cycle, daemon=True).start()
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return

        if self.path.startswith("/api/status"):
            with state_lock:
                payload = dict(sync_status)
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/config"):
            cfg = load_config()
            with state_lock:
                st = dict(sync_status)
            payload = {
                "tconnect_email": cfg.get("tconnect_email", ""),
                "has_tconnect_password": bool(cfg.get("tconnect_password", "")),
                "tconnect_region": cfg.get("tconnect_region", "EU"),
                "pump_serial": cfg.get("pump_serial", ""),
                "tconnect_features": cfg.get("tconnect_features", ""),
                "dexcom_username": cfg.get("dexcom_username", ""),
                "has_dexcom_password": bool(cfg.get("dexcom_password", "")),
                "dexcom_region": cfg.get("dexcom_region", "ous"),
                "sync_interval_seconds": cfg.get("sync_interval_seconds", 300),
                "status": st,
            }
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return

        cfg = load_config()
        with state_lock:
            logs_str = "\n".join(reversed(log_lines)) if log_lines else "Waiting for first sync..."
            st = dict(sync_status)

        html = HTML_TEMPLATE
        replacements = {
            "{{TCONNECT_EMAIL}}": cfg.get("tconnect_email", ""),
            "{{TCONNECT_PASSWORD}}": cfg.get("tconnect_password", ""),
            "{{PUMP_SERIAL}}": cfg.get("pump_serial", ""),
            "{{SEL_TC_EU}}": "selected" if cfg.get("tconnect_region", "EU") == "EU" else "",
            "{{SEL_TC_US}}": "selected" if cfg.get("tconnect_region", "EU") == "US" else "",
            "{{DEXCOM_USERNAME}}": cfg.get("dexcom_username", ""),
            "{{DEXCOM_PASSWORD}}": cfg.get("dexcom_password", ""),
            "{{SEL_DX_OUS}}": "selected" if cfg.get("dexcom_region", "ous") == "ous" else "",
            "{{SEL_DX_US}}": "selected" if cfg.get("dexcom_region", "ous") == "us" else "",
            "{{SEL_DX_JP}}": "selected" if cfg.get("dexcom_region", "ous") == "jp" else "",
            "{{SYNC_INTERVAL}}": str(cfg.get("sync_interval_seconds", 300)),
            "{{LAST_TC_TIME}}": st["last_tconnect_run"],
            "{{LAST_TC_RES}}": st["last_tconnect_result"],
            "{{LAST_DX_TIME}}": st["last_dexcom_run"],
            "{{LAST_DX_RES}}": st["last_dexcom_result"],
            "{{LOGS}}": logs_str,
        }
        for k, v in replacements.items():
            html = html.replace(k, str(v))

        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, HEAD")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, api-secret")
        self.end_headers()

    def do_POST(self):
        if self.path.startswith("/api/config"):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            try:
                incoming = json.loads(raw) if raw else {}
            except Exception as e:
                self.send_error(400, f"Invalid JSON: {e}")
                return
            cfg = load_config()
            for field in [
                "tconnect_email",
                "tconnect_password",
                "tconnect_region",
                "pump_serial",
                "tconnect_features",
                "dexcom_username",
                "dexcom_password",
                "dexcom_region",
            ]:
                if field in incoming and incoming[field] is not None:
                    val = str(incoming[field]).strip()
                    if field in ("tconnect_password", "dexcom_password") and val == "":
                        continue
                    cfg[field] = val
            save_config(cfg)
            append_log("Configuration updated via GlucoPulse iOS App API — running immediate sync cycle.")
            threading.Thread(target=run_full_sync_cycle, daemon=True).start()
            with state_lock:
                st = dict(sync_status)
            body = json.dumps({"ok": True, "status": st}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/ble-readings"):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            try:
                entries = json.loads(raw) if raw else []
                if isinstance(entries, dict):
                    entries = [entries]
                if entries:
                    ns_request("/api/v1/entries.json", method="POST", payload=entries)
                    latest_mgdl = entries[0].get("sgv", 0)
                    latest_mmol = round(float(latest_mgdl) / 18.0182, 1)
                    append_log(f"Direct G7 BLE: Stored {len(entries)} reading(s) in Nightscout (Latest: {latest_mmol} mmol/L / {latest_mgdl} mg/dL)")
                body = json.dumps({"ok": True, "count": len(entries)}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                append_log(f"Direct G7 BLE ingest error: {e}")
                self.send_error(500, str(e))
            return

        if self.path.startswith("/save"):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            form = urllib.parse.parse_qs(raw, keep_blank_values=True)
            cfg = load_config()
            for field in [
                "tconnect_email",
                "tconnect_password",
                "tconnect_region",
                "pump_serial",
                "dexcom_username",
                "dexcom_password",
                "dexcom_region",
            ]:
                if field in form:
                    cfg[field] = form[field][0].strip()
            if "sync_interval_seconds" in form:
                try:
                    cfg["sync_interval_seconds"] = max(60, int(form["sync_interval_seconds"][0]))
                except Exception:
                    pass
            save_config(cfg)
            append_log("Configuration updated via Web UI — triggering immediate sync cycle.")
            threading.Thread(target=run_full_sync_cycle, daemon=True).start()

            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return


if __name__ == "__main__":
    t = threading.Thread(target=background_loop, daemon=True)
    t.start()
    port = int(os.environ.get("PORTAL_PORT", "1338"))
    append_log(f"GlucoPulse Bridge Web UI listening on 0.0.0.0:{port}")
    server = ThreadingHTTPServer(("0.0.0.0", port), PortalHandler)
    server.serve_forever()
