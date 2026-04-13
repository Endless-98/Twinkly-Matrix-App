#!/usr/bin/env python3
"""Direct Twinkly controller test — bypasses fppd entirely.

Authenticates with Twinkly controllers using their HTTP API and sends
solid-colour frames via the native Twinkly real-time UDP protocol
(port 7777).  This is the definitive test: if lights turn on, the
controllers work and the problem is with fppd.

Usage
-----
  # 1) Check device info only (safe, doesn't touch fppd tokens):
  python3 test_twinkly_direct.py --gestalt-only

  # 2) Full bypass test (invalidates fppd tokens! — stop fppd first):
  sudo systemctl stop fppd
  python3 test_twinkly_direct.py --all --color ff0000 --duration 10
  sudo systemctl restart fppd
"""

import argparse
import base64
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

TWINKLY_RT_PORT = 7777
TIMEOUT = 3


def load_controller_ips():
    """Read controller IPs from FPP co-universes.json."""
    path = "/home/fpp/media/config/co-universes.json"
    try:
        with open(path) as f:
            data = json.load(f)
        ips = []
        for output in data.get("channelOutputs", []):
            for u in output.get("universes", []):
                ip = u.get("address", "").strip()
                if ip and ip not in ips:
                    ips.append(ip)
        return ips
    except Exception as e:
        print(f"Warning: Cannot read co-universes.json: {e}")
        return []


def get_gestalt(ip):
    """Query controller device info.  Works without auth on most firmware."""
    try:
        req = urllib.request.Request(f"http://{ip}/xled/v1/gestalt")
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError:
        # Some firmware requires auth for gestalt — try with a fresh token
        try:
            token, _ = twinkly_login(ip)
            req = urllib.request.Request(
                f"http://{ip}/xled/v1/gestalt",
                headers={"X-Auth-Token": token},
            )
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return json.loads(r.read())
        except Exception as e2:
            return {"error": str(e2)}
    except Exception as e:
        return {"error": str(e)}


def twinkly_login(ip):
    """Authenticate and return (token_str, token_bytes)."""
    challenge = base64.b64encode(os.urandom(16)).decode()
    req = urllib.request.Request(
        f"http://{ip}/xled/v1/login",
        data=json.dumps({"challenge": challenge}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        resp = json.loads(r.read())

    token_str = resp["authentication_token"]
    chalresp = resp.get("challenge_response", "")

    # Verify
    req_v = urllib.request.Request(
        f"http://{ip}/xled/v1/verify",
        data=json.dumps({"challenge-response": chalresp}).encode(),
        headers={"Content-Type": "application/json", "X-Auth-Token": token_str},
        method="POST",
    )
    with urllib.request.urlopen(req_v, timeout=TIMEOUT) as r:
        r.read()

    token_bytes = base64.b64decode(token_str)
    return token_str, token_bytes


def set_mode(ip, token_str, mode):
    """Set controller mode: 'rt', 'off', 'movie', 'demo', etc."""
    req = urllib.request.Request(
        f"http://{ip}/xled/v1/led/mode",
        data=json.dumps({"mode": mode}).encode(),
        headers={"Content-Type": "application/json", "X-Auth-Token": token_str},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read())


def get_mode(ip, token_str):
    """Get controller's current mode."""
    req = urllib.request.Request(
        f"http://{ip}/xled/v1/led/mode",
        headers={"X-Auth-Token": token_str},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read())


def send_rt_frame(sock, ip, token_bytes, num_leds, rgb):
    """Send a Twinkly rt frame (protocol version 3).

    For >~480 LEDs, fragments the frame into multiple packets
    to stay under Ethernet MTU.
    """
    r, g, b = rgb
    pixel_data = bytes([r, g, b]) * num_leds

    # Max payload per UDP packet: ~1400 bytes (conservative)
    max_pixels_per_pkt = 350  # 350 * 3 = 1050 bytes payload
    num_fragments = (num_leds + max_pixels_per_pkt - 1) // max_pixels_per_pkt

    for frag_idx in range(num_fragments):
        start = frag_idx * max_pixels_per_pkt * 3
        end = min(start + max_pixels_per_pkt * 3, len(pixel_data))

        # Version 3 header: version(1) + token(8) + num_fragments(1) + frag_index(1)
        header = bytearray(11)
        header[0] = 0x03
        header[1:1 + len(token_bytes[:8])] = token_bytes[:8]
        header[9] = num_fragments & 0xFF
        header[10] = frag_idx & 0xFF

        pkt = bytes(header) + pixel_data[start:end]
        sock.sendto(pkt, (ip, TWINKLY_RT_PORT))


def main():
    parser = argparse.ArgumentParser(description="Direct Twinkly controller bypass test")
    parser.add_argument("--ip", help="Test specific controller IP")
    parser.add_argument("--all", action="store_true", help="Test all controllers")
    parser.add_argument("--color", default="ff0000", help="Hex RGB (default: ff0000)")
    parser.add_argument("--duration", type=float, default=5, help="Hold seconds (default: 5)")
    parser.add_argument("--leds", type=int, default=0, help="LEDs per controller (0=auto from gestalt)")
    parser.add_argument("--gestalt-only", action="store_true", help="Only query device info (safe)")
    args = parser.parse_args()

    color_hex = args.color.lstrip("#")
    rgb = (int(color_hex[0:2], 16), int(color_hex[2:4], 16), int(color_hex[4:6], 16))

    all_ips = load_controller_ips()
    if args.ip:
        ips = [args.ip]
    elif args.all:
        ips = all_ips
    else:
        ips = all_ips[:1] if all_ips else []

    if not ips:
        print("No controller IPs.  Use --ip <ip> or check co-universes.json.")
        sys.exit(1)

    print(f"Controllers: {', '.join(ips)}")
    print()

    # ---------- gestalt ----------
    led_counts = {}
    for ip in ips:
        print(f"--- {ip} gestalt ---")
        g = get_gestalt(ip)
        if "error" in g:
            print(f"  ERROR: {g['error']}")
        else:
            for key in ["product_name", "hardware_version", "firmware_version",
                        "number_of_led", "led_profile", "device_name", "mac", "code"]:
                if key in g:
                    print(f"  {key}: {g[key]}")
            if "number_of_led" in g:
                led_counts[ip] = g["number_of_led"]
        print()

    if args.gestalt_only:
        return

    # ---------- bypass test ----------
    print("=" * 60)
    print("⚠️  This INVALIDATES fppd's auth tokens!")
    print("   Stop fppd first:  sudo systemctl stop fppd")
    print("   Restart after:    sudo systemctl restart fppd")
    print("=" * 60)
    print()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    token_map = {}  # ip -> (token_str, token_bytes)

    for ip in ips:
        num_leds = args.leds if args.leds > 0 else led_counts.get(ip, 500)
        print(f"[{ip}] leds={num_leds}  Authenticating...")
        try:
            token_str, token_bytes = twinkly_login(ip)
            token_map[ip] = (token_str, token_bytes, num_leds)
            print(f"[{ip}] ✅ Auth OK  token={token_str[:16]}...  ({len(token_bytes)} bytes decoded)")
        except Exception as e:
            print(f"[{ip}] ❌ AUTH FAILED: {e}")
            continue

        print(f"[{ip}] Setting rt mode...")
        try:
            resp = set_mode(ip, token_str, "rt")
            print(f"[{ip}] ✅ Mode → rt  (response: {resp.get('code', '?')})")
        except Exception as e:
            print(f"[{ip}] ❌ SET MODE FAILED: {e}")
            continue

        # Verify mode
        try:
            mode_resp = get_mode(ip, token_str)
            print(f"[{ip}] Current mode: {mode_resp.get('mode', '?')}")
        except Exception:
            pass

        # Send first frame
        send_rt_frame(sock, ip, token_bytes, num_leds, rgb)
        print(f"[{ip}] First frame sent (port {TWINKLY_RT_PORT})")
        print()

    if not token_map:
        print("No controllers authenticated successfully.")
        sock.close()
        sys.exit(1)

    print(f"🔴 LOOK AT THE LIGHTS NOW — holding #{color_hex} for {args.duration}s")
    print(f"   ✅ Lights on  → controllers work, fppd is broken")
    print(f"   ❌ Lights off → controller or network issue")
    print()

    start = time.time()
    frame_count = 0
    while time.time() - start < args.duration:
        for ip, (token_str, token_bytes, num_leds) in token_map.items():
            send_rt_frame(sock, ip, token_bytes, num_leds, rgb)
            frame_count += 1
        time.sleep(0.05)  # ~20 fps per controller

    elapsed = time.time() - start
    ccount = len(token_map)
    print(f"Sent {frame_count} frames ({frame_count / elapsed:.0f} total/s, "
          f"{frame_count / elapsed / ccount:.0f}/s per controller) over {elapsed:.1f}s")

    # Cleanup: set mode to off
    for ip, (token_str, _, _) in token_map.items():
        try:
            set_mode(ip, token_str, "off")
            print(f"[{ip}] Mode → off")
        except Exception:
            pass

    sock.close()
    print()
    print("Done.  Restart fppd:  sudo systemctl restart fppd")


if __name__ == "__main__":
    main()
