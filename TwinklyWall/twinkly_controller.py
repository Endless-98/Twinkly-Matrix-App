"""Twinkly HTTP API client — keeps controllers in 'rt' mode permanently.

Sets all controllers to real-time (DDP) mode at startup and re-asserts it
every 30 seconds via a background keepalive thread.  Twinkly controllers
have short auth-token timeouts and will revert to their built-in pattern
if not refreshed.  The keepalive is cheap (~200 ms for all 9 in parallel)
and prevents the sporadic "lights go to default pattern" issue.

The FPP Pixel Overlay state (3 = on, 0 = off) controls whether the lights
show data or go dark.  That's a local mmap/HTTP-to-localhost call, instant
and reliable.
"""

import base64
import json
import os
import time
import threading
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from logger import log


_CO_UNIVERSES_PATH = "/home/fpp/media/config/co-universes.json"
_TIMEOUT = 2  # seconds per HTTP request — fast LAN
_KEEPALIVE_INTERVAL = 30  # seconds between rt re-assertions

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


def set_all_rt(config_path=_CO_UNIVERSES_PATH):
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


def set_all_off(config_path=_CO_UNIVERSES_PATH):
    """Set all controllers to 'off' mode (LEDs dark, no RT stream).  Returns (ok, fail) counts."""
    ips = _load_controller_ips(config_path)
    if not ips:
        log("No Twinkly IPs found — skipping mode change", level="WARNING", module="Twinkly")
        return 0, 0

    ok = 0
    fail = 0
    with ThreadPoolExecutor(max_workers=len(ips), thread_name_prefix="twinkly") as pool:
        futures = {pool.submit(_set_mode_one, ip, "off"): ip for ip in ips}
        for fut in as_completed(futures):
            if fut.result():
                ok += 1
            else:
                fail += 1

    log(f"Twinkly mode 'off': {ok} ok, {fail} failed (of {len(ips)} controllers)", module="Twinkly")
    return ok, fail


def ensure_rt_mode():
    """Set all controllers to 'rt' now, then keep them there with a background loop.

    The keepalive re-asserts 'rt' every 30s, which also refreshes the auth
    token before it expires.  If any controller fails, tokens are cleared and
    it retries next cycle.  Safe to call multiple times — only one keepalive
    thread will run.
    """
    def _initial():
        """Initial burst: try up to 3 times with short delays."""
        for attempt in range(3):
            ok, fail = set_all_rt()
            if fail == 0:
                return
            log(f"Twinkly rt attempt {attempt + 1}: {fail} failed — retrying in 2s",
                level="WARNING", module="Twinkly")
            time.sleep(2)
            with _token_lock:
                _token_cache.clear()

    def _keepalive():
        """Background loop: re-assert 'rt' every _KEEPALIVE_INTERVAL seconds."""
        _initial()
        while True:
            time.sleep(_KEEPALIVE_INTERVAL)
            try:
                ok, fail = set_all_rt()
                if fail > 0:
                    # Clear stale tokens so next cycle re-authenticates
                    with _token_lock:
                        _token_cache.clear()
            except Exception as e:
                log(f"Twinkly keepalive error: {e}", level="WARNING", module="Twinkly")

    t = threading.Thread(target=_keepalive, daemon=True, name="twinkly-keepalive")
    t.start()

