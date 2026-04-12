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
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from logger import log


_CO_UNIVERSES_PATH = "/home/fpp/media/config/co-universes.json"
_TIMEOUT = 2  # seconds per HTTP request — fast LAN, no need for 4s

# Cache per-IP auth tokens so repeated mode changes don't need a full re-auth
_token_cache: dict[str, str] = {}
_token_lock = threading.Lock()

# Generation counter: incremented on every set_all_rt() call.
# Background set_all_off() threads check this and abort if it changed,
# preventing a stale "off" from overriding a newer "rt".
_mode_generation = 0
_mode_gen_lock = threading.Lock()


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


def _set_all_mode(mode, config_path=_CO_UNIVERSES_PATH, generation=None):
    """Set all controllers to *mode* in parallel. Returns when all are done.

    If *generation* is provided (used by background "off" threads), abort early
    when the global generation counter has advanced — meaning a newer "rt"
    request superseded this "off".
    """
    ips = _load_controller_ips(config_path)
    if not ips:
        log("No Twinkly IPs found — skipping mode change", level="WARNING", module="Twinkly")
        return

    # Check if already superseded before even starting
    if generation is not None:
        with _mode_gen_lock:
            if _mode_generation != generation:
                log(f"Twinkly '{mode}' aborted — superseded by newer request", module="Twinkly")
                return

    ok = 0
    fail = 0
    with ThreadPoolExecutor(max_workers=len(ips), thread_name_prefix="twinkly") as pool:
        futures = {pool.submit(_set_mode_one, ip, mode): ip for ip in ips}
        for fut in as_completed(futures):
            # Check if superseded while we were waiting
            if generation is not None:
                with _mode_gen_lock:
                    if _mode_generation != generation:
                        pool.shutdown(wait=False, cancel_futures=True)
                        log(f"Twinkly '{mode}' aborted mid-flight — superseded", module="Twinkly")
                        return
            if fut.result():
                ok += 1
            else:
                fail += 1

    log(f"Twinkly mode '{mode}': {ok} ok, {fail} failed (of {len(ips)} controllers)", module="Twinkly")


def set_all_off():
    """Switch all controllers to 'off' mode in a background thread (non-blocking).

    Uses a generation snapshot so this will abort if set_all_rt() is called
    before it finishes — preventing the race where "off" undoes a newer "rt".
    """
    with _mode_gen_lock:
        gen = _mode_generation
    t = threading.Thread(target=_set_all_mode, args=("off",),
                         kwargs={"generation": gen},
                         daemon=True, name="twinkly-off")
    t.start()


def set_all_rt():
    """Switch all controllers to real-time/DDP mode in parallel (blocks until done).

    Increments the generation counter first so any in-flight set_all_off()
    background thread will detect the change and abort.
    """
    global _mode_generation
    with _mode_gen_lock:
        _mode_generation += 1
    _set_all_mode("rt")

