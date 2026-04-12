"""Twinkly HTTP API client for controlling device mode.

Used to switch controllers between 'off' (dark, no DDP needed) and 'rt'
(real-time / DDP mode, ready to receive frames from fppd).

This is the "once and done" idle mechanism: one HTTP call per controller,
no continuous DDP broadcast required.

All controllers are contacted in parallel so the total time is bounded by
the slowest single device, not the sum of all devices.
"""

import base64
import json
import os
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from logger import log


_CO_UNIVERSES_PATH = "/home/fpp/media/config/co-universes.json"
_TIMEOUT = 2  # seconds per HTTP request — fast LAN, no need for 4s

# Cache per-IP auth tokens so repeated mode changes don't need a full re-auth
_token_cache: dict[str, str] = {}
_token_lock = threading.Lock()


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
    """Return a cached auth token, or authenticate and cache a fresh one."""
    with _token_lock:
        cached = _token_cache.get(ip)
    if cached:
        return cached

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

        with _token_lock:
            _token_cache[ip] = token
        return token
    except Exception as e:
        log(f"Twinkly auth failed for {ip}: {e}", level="WARNING", module="Twinkly")
        return None


def _set_mode_one(ip, mode):
    """Authenticate (using cache) and set the mode on a single controller."""
    token = _twinkly_auth(ip)
    if not token:
        return False
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
        # Token may have expired — evict cache so next call re-auths
        with _token_lock:
            _token_cache.pop(ip, None)
        log(f"Twinkly set mode '{mode}' failed for {ip}: {e}", level="WARNING", module="Twinkly")
        return False


def _set_all_mode(mode, config_path=_CO_UNIVERSES_PATH):
    """Set all controllers to *mode* in parallel. Returns when all are done."""
    ips = _load_controller_ips(config_path)
    if not ips:
        log("No Twinkly IPs found — skipping mode change", level="WARNING", module="Twinkly")
        return

    ok = 0
    fail = 0
    with ThreadPoolExecutor(max_workers=len(ips), thread_name_prefix="twinkly") as pool:
        futures = {pool.submit(_set_mode_one, ip, mode): ip for ip in ips}
        for fut in as_completed(futures):
            if fut.result():
                ok += 1
            else:
                fail += 1

    log(f"Twinkly mode '{mode}': {ok} ok, {fail} failed (of {len(ips)} controllers)", module="Twinkly")


def set_all_off():
    """Switch all controllers to 'off' mode in a background thread (non-blocking)."""
    t = threading.Thread(target=_set_all_mode, args=("off",), daemon=True, name="twinkly-off")
    t.start()


def set_all_rt():
    """Switch all controllers to real-time/DDP mode in parallel (blocks until done)."""
    _set_all_mode("rt")

