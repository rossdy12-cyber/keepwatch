"""Adjusts Synapse's generated config for a private, bridge-only server (idempotent)."""
import os
import secrets
import sys

import yaml

SERVER = os.environ["SERVER_NAME"]
CONFIG = "/data/homeserver.yaml"
APPSERVICES = "/appservices"


def doublepuppet():
    token = secrets.token_urlsafe(32)
    registration = {
        "id": "doublepuppet",
        "url": None,
        "as_token": token,
        "hs_token": secrets.token_urlsafe(32),
        "sender_localpart": secrets.token_hex(8),
        "rate_limited": False,
        "namespaces": {"users": [{"regex": "@.*:" + SERVER.replace(".", "\\."), "exclusive": False}]},
    }
    os.makedirs(APPSERVICES, exist_ok=True)
    with open(os.path.join(APPSERVICES, "doublepuppet.yaml"), "w") as handle:
        yaml.safe_dump(registration, handle, sort_keys=False)
    with open(os.path.join(APPSERVICES, "doublepuppet.token"), "w") as handle:
        handle.write(token)
    print("Created the double-puppeting registration")


def config():
    with open(CONFIG) as handle:
        conf = yaml.safe_load(handle)
    files = [os.path.join(APPSERVICES, name) for name in ("doublepuppet.yaml", "whatsapp.yaml", "discord.yaml")
             if os.path.exists(os.path.join(APPSERVICES, name))]
    conf["app_service_config_files"] = files
    # Private server: no federation, no public sign-ups, no phoning home.
    conf["federation_domain_whitelist"] = []
    conf["trusted_key_servers"] = []
    conf["suppress_key_server_warning"] = True
    conf["enable_registration"] = False
    conf["report_stats"] = False
    conf["url_preview_enabled"] = False
    conf["max_upload_size"] = os.environ.get("MAX_UPLOAD", "100M")
    conf["presence"] = {"enabled": True}
    conf["media_retention"] = conf.get("media_retention") or {}
    # Bridges create many rooms and send many messages: loosen the default rate limits.
    conf["rc_message"] = {"per_second": 50, "burst_count": 200}
    conf["rc_joins"] = {"local": {"per_second": 50, "burst_count": 200}}
    conf["rc_login"] = {"address": {"per_second": 1, "burst_count": 10}, "account": {"per_second": 1, "burst_count": 10}}
    for listener in conf.get("listeners", []):
        if listener.get("port") == 8008:
            listener["bind_addresses"] = ["0.0.0.0"]
            listener["resources"] = [{"names": ["client"], "compress": False}]
    with open(CONFIG, "w") as handle:
        yaml.safe_dump(conf, handle, sort_keys=False)
    print("Synapse config ready with %d bridge registration(s)" % len(files))


if __name__ == "__main__":
    {"doublepuppet": doublepuppet, "config": config}[sys.argv[1]]()
