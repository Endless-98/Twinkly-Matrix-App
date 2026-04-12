"""Twinkly HTTP API client — one-time 'rt' mode at startup.

Sets all controllers to real-time (DDP) mode once on boot so they respond
to fppd immediately.  No mode toggling during playback — the FPP Pixel
Overlay state (3 = on, 0 = off) controls whether the lights show data or
go dark.  That's a local mmap/HTTP-to-localhost call, instant and reliable.
"""

import base64
import json
import os
import threading
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from logger import log


_CO_UNIVERSES_PATH = "/home/fpp/media/config/co-universes.json"
_TIMEOUT = 2  # seconds per HTTP request — fast LAN

# Cache per-IP auth tokens so repeated calls don't need a full re-auth
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
    """Authenticate (using cache) and set the mode on a single controller.

    Retries once with a fresh token if the first attempt gets a 401.
    """
    for attempt in range(2):
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
        except urllib.error.HTTPError as e:
            with _token_lock:
                _token_cache.pop(ip, None)
            if e.code == 401 and attempt == 0:
                continue  # retry with fresh auth
            log(f"Twinkly set mode '{mode}' failed for {ip}: {e}", level="WARNING", module="Twinkly")
            return False
        except Exception as e:
            with _token_lock:
                _token_cache.pop(ip, None)
            log(f"Twinkly set mode '{mode}' failed for {ip}: {e}", level="WARNING", module="Twinkly")
            return False
    return False


def _set_all_rt(config_path=_CO_UNIVERSES_PATH):
    """Set all controllers to 'rt' mode in parallel.  Returns (ok, fail) counts."""
    ips = _load_controller_ips(config_path)
    if not ips:
        log("No Twinkly IPs found — skipping mode change", level="WARNING", module="Twinkly")
        return 0, 0

    ok = 0
    fail = 0
    with ThreadPoolExecutor(max_workers=len(ips), thread_name_prefix="twinkly") as pool:
        futures = {pool.submit(_set_mode_one, ip, "rt"): ip for ip in ips}
        for fut in as_completed(futures):
            if fut.result():
                ok += 1
            else:
                fail += 1

    log(f"Twinkly mode 'rt': {ok} ok, {fail} failed (of {len(ips)} controllers)", module="Twinkly")
    return ok, fail


def ensure_rt_mode():
    """Set all controllers to 'rt' once in a background thread.

    Retries failed controllers up to 3 times with a short delay.
    Safe to call multiple times — it's idempotent.
    """
    def _worker():
        for attempt in range(3):
            ok, fail = _set_all_rt()
            if fail == 0:
                return
            log(f"Twinkly rt attempt {attempt + 1}: {fail} failed — retrying in 2s",
                level="WARNING", module="Twinkly")
            import time
            time.sleep(2)
            # Clear token cache for retry — stale tokens may be the issue
            with _token_lock:
                _token_cache.clear()

    t = threading.Thread(target=_worker, daemon=True, name="twinkly-ensure-rt")
    t.start()

