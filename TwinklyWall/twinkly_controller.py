"""Twinkly HTTP API client for controlling device mode.

Used to switch controllers between 'off' (dark, no DDP needed) and 'rt'
(real-time / DDP mode, ready to receive frames from fppd).

This is the "once and done" idle mechanism: one HTTP call per state change,
no continuous DDP broadcast required.
"""

import base64
import json
import os
import urllib.request
from logger import log


_CO_UNIVERSES_PATH = "/home/fpp/media/config/co-universes.json"
_TIMEOUT = 4  # seconds per HTTP request


def _load_controller_ips(config_path=_CO_UNIVERSES_PATH):
    """Return a deduplicated list of Twinkly controller IP addresses from FPP config."""
    try:
        with open(config_path) as f:
            data = json.load(f)
        ips = []
        seen = set()
        for output in data.get("channelOutputs", []):
            for universe in output.get("universes", []):
                ip = universe.get("address", "").strip()
                if ip and ip not in seen:
                    seen.add(ip)
                    ips.append(ip)
        return ips
    except FileNotFoundError:
        return []
    except Exception as e:
        log(f"Failed to load Twinkly IPs from {config_path}: {e}", level="WARNING", module="Twinkly")
        return []


def _twinkly_auth(ip):
    """Authenticate with a Twinkly device and return the auth token, or None on failure."""
    try:
        challenge = base64.b64encode(os.urandom(16)).decode()
        req = urllib.request.Request(
            f"http://{ip}/xled/v1/login",
            data=json.dumps({"challenge": challenge}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as r:
            login = json.loads(r.read())

        token = login.get("authentication_token", "")
        chalresp = login.get("challenge_response", "")

        req_v = urllib.request.Request(
            f"http://{ip}/xled/v1/verify",
            data=json.dumps({"challenge-response": chalresp}).encode(),
            headers={"Content-Type": "application/json", "X-Auth-Token": token},
            method="POST",
        )
        with urllib.request.urlopen(req_v, timeout=_TIMEOUT) as r:
            r.read()

        return token
    except Exception as e:
        log(f"Twinkly auth failed for {ip}: {e}", level="WARNING", module="Twinkly")
        return None


def _set_mode(ip, token, mode):
    """Set the LED mode on a single Twinkly controller."""
    try:
        req = urllib.request.Request(
            f"http://{ip}/xled/v1/led/mode",
            data=json.dumps({"mode": mode}).encode(),
            headers={"Content-Type": "application/json", "X-Auth-Token": token},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as r:
            r.read()
        return True
    except Exception as e:
        log(f"Twinkly set mode '{mode}' failed for {ip}: {e}", level="WARNING", module="Twinkly")
        return False


def _set_all_mode(mode, config_path=_CO_UNIVERSES_PATH):
    """Set all Twinkly controllers to the given mode. Runs in a background thread."""
    ips = _load_controller_ips(config_path)
    if not ips:
        log("No Twinkly IPs found — skipping mode change", level="WARNING", module="Twinkly")
        return

    ok = 0
    fail = 0
    for ip in ips:
        token = _twinkly_auth(ip)
        if token and _set_mode(ip, token, mode):
            ok += 1
        else:
            fail += 1

    log(f"Twinkly mode '{mode}': {ok} ok, {fail} failed (of {len(ips)} controllers)", module="Twinkly")


def set_all_off():
    """Switch all Twinkly controllers to 'off' mode (lights dark, no DDP needed).

    Call this once at idle. The lights will stay dark until set_all_rt() is called.
    No continuous DDP broadcast is required — this is truly once-and-done.
    """
    import threading
    t = threading.Thread(target=_set_all_mode, args=("off",), daemon=True, name="twinkly-off")
    t.start()


def set_all_rt():
    """Switch all Twinkly controllers to real-time / DDP mode.

    Blocks until complete (called just before playback begins so the controllers
    are ready to receive frames from fppd).
    """
    _set_all_mode("rt")
