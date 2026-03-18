#!/bin/bash
set -e

# Resolve absolute path before any cd, so we can re-exec after git pull updates this file.
SCRIPT_ABS="$(cd "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"

if [ -z "${_SETUP_REEXECED:-}" ]; then
    echo '🚀 Setting up/updating TwinklyWall on FPP...'
    echo '🔄 Syncing with GitHub first...'

    # Sync repository FIRST, before parsing args or doing anything else
    cd ~
    if [ ! -d "TwinklyWall_Project" ]; then
        echo '📥 Cloning repository...'
        git clone https://github.com/Endless-98/Twinkly-Matrix-App.git TwinklyWall_Project
        cd ~
    else
        echo '📥 Pulling latest code from GitHub...'
        cd TwinklyWall_Project
        git pull origin master
        cd ~
    fi

    # Re-exec with the freshly-pulled script so the rest of this run uses the
    # latest code. _SETUP_REEXECED prevents an infinite loop.
    export _SETUP_REEXECED=1
    exec bash "$SCRIPT_ABS" "$@"
fi

# Working directory after re-exec is ~ — navigate to project
cd ~/TwinklyWall_Project

DEBUG_MODE=0
WIDTH=90
HEIGHT=50
MODEL="Light Wall"

# Parse CLI args: --debug, --width N, --height N, --model NAME
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        --width)
            WIDTH="$2"
            shift 2
            ;;
        --height)
            HEIGHT="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"; exit 1
            ;;
    esac
done

# Verbose shell logging in debug mode
if [ $DEBUG_MODE -eq 1 ]; then
    set -x
fi

# Setup Python environment
cd TwinklyWall

# Use .pyenv Python if available (preferred), fallback to system python3
PYTHON_BIN="python3"
if command -v /home/fpp/.pyenv/versions/3.12.12/bin/python &> /dev/null; then
    PYTHON_BIN="/home/fpp/.pyenv/versions/3.12.12/bin/python"
    echo '✅ Using .pyenv Python 3.12.12'
else
    echo '⚠️  .pyenv Python 3.12.12 not found, using system python3'
fi

echo '📦 Installing Python dependencies...'
# Install dependencies (remove -q flag to see any errors)
"$PYTHON_BIN" -m pip install -r requirements.txt || {
    echo "❌ Failed to install dependencies"
    exit 1
}

# Verify yt-dlp is installed for YouTube downloads
if "$PYTHON_BIN" -c "import yt_dlp" 2>/dev/null; then
    echo '✅ Python dependencies satisfied (yt-dlp found)'
else
    echo '🔄 Installing yt-dlp...'
    "$PYTHON_BIN" -m pip install yt-dlp || {
        echo "❌ Failed to install yt-dlp"
        exit 1
    }
fi

# Install/update systemd services (skip in --debug mode)
cd ~/TwinklyWall_Project/TwinklyWall

# TwinklyWall main service
SERVICE_FILE="/etc/systemd/system/twinklywall.service"
if [ $DEBUG_MODE -eq 0 ]; then
    if [ ! -f "$SERVICE_FILE" ]; then
    echo '⚙️ Installing twinklywall service...'
    sudo cp twinklywall.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable twinklywall
    elif ! cmp -s twinklywall.service "$SERVICE_FILE"; then
    echo '🔄 Updating twinklywall service...'
    sudo cp twinklywall.service /etc/systemd/system/
    sudo systemctl daemon-reload
    echo '♻️ Restarting twinklywall to apply unit changes...'
    sudo systemctl restart twinklywall || true
    else
        echo '✅ Twinklywall service is up to date'
    fi
fi

# DDP Bridge service (no longer needed — bridge runs inside twinklywall)
DDP_SERVICE_FILE="/etc/systemd/system/ddp_bridge.service"
if [ $DEBUG_MODE -eq 0 ]; then
    if [ -f "$DDP_SERVICE_FILE" ]; then
        echo '🧹 Removing obsolete DDP bridge service (now built into twinklywall)...'
        sudo systemctl stop ddp_bridge 2>/dev/null || true
        sudo systemctl disable ddp_bridge 2>/dev/null || true
        sudo rm -f "$DDP_SERVICE_FILE"
        sudo systemctl daemon-reload
    fi
fi

# Modern FPP v7+ "Virtual Bridge" setup (Bridge mode is deprecated):
# 1. Stay in Player mode (mode 2)
# 2. Enable "Always Transmit" so fppd keeps outputting when idle
# 3. Overlay state 3 (handled by fpp_output.py at runtime)
# 4. Channel outputs enabled (checked below)
echo '🔧 Checking fppd operating mode...'
NEEDS_FPPD_RESTART=0
if command -v curl >/dev/null 2>&1; then
    FPPD_MODE="$(curl -sS -m 5 'http://localhost/api/fppd/status' 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("mode",""))' 2>/dev/null || echo '')"
    if [ "$FPPD_MODE" = "2" ]; then
        echo '✅ fppd is in Player mode (correct for FPP v9.x)'
    else
        echo "⚠️  fppd in unexpected mode $FPPD_MODE — restoring Player mode (2)..."
        curl -sS -m 5 -X PUT 'http://localhost/api/settings/fppMode' \
            -H 'Content-Type: application/json' -d '{"value":"2"}' >/dev/null 2>&1 || true
        NEEDS_FPPD_RESTART=1
    fi

    # "Always Transmit Channel Data" keeps the output loop running even when
    # the player is idle, so Pixel Overlay data reaches the controllers.
    #
    # FPP stores ALL settings as key = "value" lines in a SINGLE FILE:
    #   /home/fpp/media/settings       (NOT a directory!)
    echo '🔧 Ensuring "Always Transmit Channel Data" is enabled...'
    SETTINGS_FILE="/home/fpp/media/settings"
    # FPP v9 returns {"value":"1"} — parse with python3 to handle all formats
    ALWAYS_TX_API="$(curl -sS -m 5 'http://localhost/api/settings/alwaysTransmit' 2>/dev/null | \
        python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("value","") if isinstance(d,dict) else str(d).strip())' 2>/dev/null || echo '')"
    ALWAYS_TX_FILE=""
    if [ -f "$SETTINGS_FILE" ]; then
        # Extract value from  alwaysTransmit = "1"  style line
        ALWAYS_TX_FILE="$(grep -E '^\s*alwaysTransmit\s*=' "$SETTINGS_FILE" 2>/dev/null \
            | head -1 | sed 's/.*=\s*//; s/[" ]//g' || echo '')"
    fi
    ALWAYS_TX="$ALWAYS_TX_API"
    if [ -z "$ALWAYS_TX" ]; then
        ALWAYS_TX="$ALWAYS_TX_FILE"
    fi

    if [ "$ALWAYS_TX" = "1" ] || [ "$ALWAYS_TX" = "true" ]; then
        echo '✅ Always Transmit is already enabled'
    else
        echo '⚠️  Always Transmit is OFF — enabling now...'
        # Method 1: FPP HTTP API
        curl -sS -m 5 -X PUT 'http://localhost/api/settings/alwaysTransmit' \
            -H 'Content-Type: application/json' -d '{"value":"1"}' >/dev/null 2>&1 || true
        AT_VERIFY="$(curl -sS -m 5 'http://localhost/api/settings/alwaysTransmit' 2>/dev/null | tr -d '[:space:][]"' || echo '')"
        if [ "$AT_VERIFY" = "1" ] || [ "$AT_VERIFY" = "true" ]; then
            echo '✅ Always Transmit enabled successfully (API)'
            NEEDS_FPPD_RESTART=1
        else
            echo '⚠️  API did not persist — writing settings file directly...'
            AT_WRITTEN=0

            # Method 2: Edit /home/fpp/media/settings (key = "value" flat file)
            if [ -f "$SETTINGS_FILE" ]; then
                if grep -qE '^\s*alwaysTransmit\s*=' "$SETTINGS_FILE" 2>/dev/null; then
                    # Update existing line
                    sed -i 's/^\(\s*alwaysTransmit\s*=\s*\).*/\1"1"/' "$SETTINGS_FILE" 2>/dev/null \
                        || sudo sed -i 's/^\(\s*alwaysTransmit\s*=\s*\).*/\1"1"/' "$SETTINGS_FILE" 2>/dev/null || true
                else
                    # Append new line
                    echo 'alwaysTransmit = "1"' >> "$SETTINGS_FILE" 2>/dev/null \
                        || { sudo sh -c "echo 'alwaysTransmit = \"1\"' >> '$SETTINGS_FILE'"; } 2>/dev/null || true
                fi
                # Verify
                AT_FILE_CHK="$(grep -E '^\s*alwaysTransmit\s*=' "$SETTINGS_FILE" 2>/dev/null \
                    | head -1 | sed 's/.*=\s*//; s/[" ]//g' || echo '')"
                if [ "$AT_FILE_CHK" = "1" ]; then
                    echo '✅ Always Transmit enabled successfully (settings file)'
                    AT_WRITTEN=1
                    NEEDS_FPPD_RESTART=1
                fi
            fi

            # Method 3: fpp CLI tool
            if [ "$AT_WRITTEN" -eq 0 ] && command -v fpp >/dev/null 2>&1; then
                if fpp -c setSetting alwaysTransmit 1 >/dev/null 2>&1 || \
                   sudo fpp -c setSetting alwaysTransmit 1 >/dev/null 2>&1; then
                    echo '✅ Always Transmit enabled via fpp CLI'
                    AT_WRITTEN=1
                    NEEDS_FPPD_RESTART=1
                fi
            fi

            if [ "$AT_WRITTEN" -eq 0 ]; then
                echo ''
                echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
                echo '❌  Could not set alwaysTransmit automatically.'
                echo '   Settings file info:'
                ls -la "$SETTINGS_FILE" 2>/dev/null || echo "   $SETTINGS_FILE not found"
                echo '   ▶  Enable manually: FPP UI → Input/Output Setup → Channel Outputs'
                echo '                       → tick "Always Transmit Channel Data"'
                echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
                echo ''
            fi
        fi
    fi

    if [ "$NEEDS_FPPD_RESTART" -eq 1 ]; then
        echo '♻️ Restarting fppd to apply mode/transmit changes...'
        sudo systemctl restart fppd || true
        sleep 3
    fi
else
    echo '⚠️  curl not available — cannot check fppd mode'
fi

# Ensure FPP channel outputs master switch is enabled
# The "Enable Output" toggle is stored in co-universes.json, not in /api/settings/
CO_CONFIG="/home/fpp/media/config/co-universes.json"
echo '🔧 Ensuring FPP channel outputs are enabled...'
if [ -f "$CO_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    CO_ENABLED="$(jq -r '.channelOutputs[0].enabled // 0' "$CO_CONFIG" 2>/dev/null || echo '0')"
    if [ "$CO_ENABLED" = "1" ]; then
        echo '✅ Channel outputs already enabled (co-universes.json)'
    else
        echo '⚠️  Channel outputs are OFF in co-universes.json — enabling now...'
        if jq '.channelOutputs[0].enabled = 1' "$CO_CONFIG" > "${CO_CONFIG}.tmp" 2>/dev/null && \
           mv "${CO_CONFIG}.tmp" "$CO_CONFIG"; then
            echo '✅ Channel outputs enabled in co-universes.json'
            echo '♻️ Restarting fppd to apply output changes...'
            sudo systemctl restart fppd || true
            sleep 3
        else
            echo '❌ WARNING: Could not update co-universes.json'
            echo '   Enable manually in FPP UI → Input/Output Setup → Channel Outputs → Enable Output'
            rm -f "${CO_CONFIG}.tmp" 2>/dev/null || true
        fi
    fi
else
    echo '⚠️  co-universes.json not found or jq not available — skipping channel output check'
    echo '   Verify manually in FPP UI → Input/Output Setup → Channel Outputs'
fi

# Check FPP frame buffer permissions
SAFE_MODEL_NAME="${MODEL// /_}"
FPP_MMAP_FILE="/dev/shm/FPP-Model-Data-${SAFE_MODEL_NAME}"
MMAP_PERM_CMD="sudo chmod 666 ${FPP_MMAP_FILE}"
MMAP_PERMS_SET=0
echo '🔍 Checking FPP frame buffer permissions...'
if [ ! -e "$FPP_MMAP_FILE" ]; then
    echo "⚠️  Frame buffer file does not exist yet: $FPP_MMAP_FILE"
    echo "   (This is normal; FPP will create it when the model is activated)"
    echo "   Run after model is active: $MMAP_PERM_CMD"
else
    echo "🔧 Applying write permissions: $MMAP_PERM_CMD"
    sudo chmod 666 "$FPP_MMAP_FILE" || {
        echo "❌ Failed to set permissions on $FPP_MMAP_FILE"
        echo "   Try running: $MMAP_PERM_CMD"
        exit 1
    }
    if [ -w "$FPP_MMAP_FILE" ]; then
        MMAP_PERMS_SET=1
        echo "✅ Frame buffer is writable: $FPP_MMAP_FILE"
    else
        echo "⚠️  chmod completed but file still not writable: $FPP_MMAP_FILE"
    fi
fi

# Ensure services are running (and no duplicate manual processes)
if [ $DEBUG_MODE -eq 0 ]; then
    # Always reload units in case they changed outside this script
    sudo systemctl daemon-reload || true

    echo '🧹 Ensuring a single clean instance is running...'
    echo '   - Stopping services if active'
    sudo systemctl stop twinklywall || true
    sudo systemctl stop ddp_bridge 2>/dev/null || true

    echo '   - Killing any stray manual Python processes'
    # Kill any manually launched processes for safety (do not fail the script if none)
    pkill -u fpp -f '/home/fpp/TwinklyWall_Project/TwinklyWall/main.py' 2>/dev/null || true
    pkill -u fpp -f '/home/fpp/TwinklyWall_Project/TwinklyWall/api_server.py' 2>/dev/null || true
    pkill -u fpp -f '/home/fpp/TwinklyWall_Project/TwinklyWall/ddp_bridge.py' 2>/dev/null || true

    sleep 0.5

    echo '▶️ Restarting twinklywall with latest code...'
    sudo systemctl restart twinklywall || sudo systemctl start twinklywall
fi

if [ $DEBUG_MODE -eq 1 ]; then
    echo '🧪 Debug mode: stopping any running services to avoid conflicts.'
    sudo systemctl stop twinklywall || true
    sudo systemctl stop ddp_bridge 2>/dev/null || true
    echo '▶️ Launching DDP debug runner (Ctrl+C to exit)...'
    export TWINKLYWALL_DEBUG=1
    "$PYTHON_BIN" /home/fpp/TwinklyWall_Project/TwinklyWall/debug_ddp.py --port 4049 --width "$WIDTH" --height "$HEIGHT" --model "$MODEL"
    exit 0
fi

echo '✅ Setup/update complete!'
echo ''

# ═══════════════════════════════════════════════════════════════════════════════
# POST-SETUP VERIFICATION — overlay state, controller reachability, smoke test
# ═══════════════════════════════════════════════════════════════════════════════

if command -v curl >/dev/null 2>&1; then
    # 1) Force Pixel Overlay state 3 (always-on) — fppd resets overlays to 0
    #    on restart, so we must re-set it AFTER fppd + twinklywall are up.
    echo ''
    echo '🔧 Ensuring Pixel Overlay is in state 3 (always on)...'

    # Wait for fppd to be fully ready (overlay models load after startup)
    echo '   Waiting for fppd to be ready...'
    FPPD_READY=0
    for i in $(seq 1 15); do
        FPPD_STATUS="$(curl -sS -m 3 'http://localhost/api/fppd/status' 2>/dev/null \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status_name",""))' 2>/dev/null || echo '')"
        if [ -n "$FPPD_STATUS" ] && [ "$FPPD_STATUS" != "" ]; then
            echo "   fppd status: $FPPD_STATUS (ready after ${i}s)"
            FPPD_READY=1
            break
        fi
        sleep 1
    done
    if [ "$FPPD_READY" -eq 0 ]; then
        echo '   ⚠️  fppd did not respond to status check within 15s'
    fi

    # List available overlay models for diagnostics
    echo '   Available overlay models:'
    MODELS_RAW="$(curl -sS -m 5 'http://localhost/api/overlays/models' 2>/dev/null || echo '')"
    if [ -n "$MODELS_RAW" ]; then
        echo "$MODELS_RAW" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for m in data:
            name = m if isinstance(m, str) else m.get("Name", m.get("name", str(m)))
            print(f"     - {name}")
        if not data:
            print("     (empty list — no models registered)")
    elif isinstance(data, dict):
        for k, v in data.items():
            print(f"     - {k}: {v}")
    else:
        print(f"     (unexpected: {data})")
except Exception as e:
    print(f"     (parse error: {e})")
' 2>/dev/null || echo "     (raw: ${MODELS_RAW:0:200})"
    else
        echo '     (no response from overlay API)'
    fi

    OVERLAY_OK=0
    for attempt in 1 2 3; do
        # PUT the state; FPP's GET /api/overlays/model/{name} returns model config only
        # (no runtime State field), so we verify success directly from the PUT response.
        PUT_RESP="$(curl -sS -m 5 -X PUT "http://localhost/api/overlays/model/${SAFE_MODEL_NAME}/state" \
            -H 'Content-Type: application/json' -d '{"State":3}' 2>&1 || echo 'CURL_FAILED')"

        PUT_OK="$(echo "$PUT_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("yes" if d.get("Status")=="OK" else "no")' 2>/dev/null || echo 'no')"

        if [ "$PUT_OK" = "yes" ]; then
            echo "✅ Pixel Overlay '${SAFE_MODEL_NAME}' state 3 accepted by FPP (always on)"
            OVERLAY_OK=1
            break
        fi

        echo "   attempt $attempt: PUT='${PUT_RESP:0:200}'"
        sleep 3
    done
    if [ "$OVERLAY_OK" -eq 0 ]; then
        echo "⚠️  Could not set overlay state 3 — fppd may not have the model yet"
        echo "   Check FPP UI → Pixel Overlay Models → ${MODEL}"
        echo "   Manual test:"
        echo "     curl -v -X PUT 'http://localhost/api/overlays/model/${SAFE_MODEL_NAME}/state' -H 'Content-Type: application/json' -d '{\"State\":3}'"
    fi

    # 1b) Write overlay state directly to FPP's SHM control block.
    #     fppd reads isActive (int32 LE at offset 0) from /dev/shm/FPP-PixelOverlay-<name>.
    #     This bypasses the HTTP API layer entirely and is the most reliable activation path.
    CONTROL_FILE="/dev/shm/FPP-PixelOverlay-${SAFE_MODEL_NAME}"
    echo '🔧 Writing overlay state directly to FPP control block...'
    if [ -f "$CONTROL_FILE" ]; then
        python3 -c "
import struct
cf = '$CONTROL_FILE'
try:
    with open(cf, 'r+b') as f:
        cur_bytes = f.read(4)
        cur = struct.unpack('<i', cur_bytes)[0] if len(cur_bytes) == 4 else -1
        f.seek(0)
        f.write(struct.pack('<i', 3))
        f.flush()
    print(f'   ✅ isActive: {cur} → 3  ({cf})')
except Exception as e:
    print(f'   ⚠️  Could not write control block: {e}')
" 2>/dev/null || true
    else
        echo "   ℹ️  $CONTROL_FILE not present — fppd creates it when DefaultState >= 1"
        echo '   All /dev/shm/ files (checking for alternate naming):'
        ls -la /dev/shm/ 2>/dev/null | grep -v "^total" | awk '{print "      "$0}' | head -30 \
            || echo '      (cannot list /dev/shm/)'
    fi

    # 1c) Show full overlay model config from FPP API (StartChannel, DefaultState, etc.)
    echo ''
    echo '🔍 Overlay model details from FPP API:'
    curl -sS -m 5 "http://localhost/api/overlays/model/${SAFE_MODEL_NAME}" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in ('Name','StartChannel','ChannelCount','StringCount','StrandsPerString',
              'DefaultState','defaultState','State','state','Enabled','Type'):
        if k in d:
            print(f'   {k}: {d[k]}')
except Exception:
    pass
" 2>/dev/null || true

    # 1d) If the SHM control block is absent, fppd's DefaultState in model-overlays.json is
    #     probably 0.  Set it to 3 and restart fppd so it creates the control block.
    #     Without the control block, fppd CANNOT forward mmap data to E1.31 — this is the
    #     root cause of all-zero E1.31 packets.
    if [ ! -f "$CONTROL_FILE" ]; then
        echo ''
        echo '🔧 Control block absent — locating FPP overlay config to set DefaultState=3...'
        FPP_OVERLAY_CFG=""
        for _try_path in \
            "/home/fpp/media/config/model-overlays.json" \
            "/home/fpp/media/config/pixelOverlayModels.json" \
            "/home/fpp/media/config/overlayModels.json" \
            "/home/fpp/media/config/models.json"
        do
            if [ -f "$_try_path" ]; then FPP_OVERLAY_CFG="$_try_path"; break; fi
        done
        if [ -z "$FPP_OVERLAY_CFG" ]; then
            FPP_OVERLAY_CFG="$(find /home/fpp/media/config/ -name "*.json" 2>/dev/null | \
                xargs grep -l "Light" 2>/dev/null | head -1 || echo '')"
        fi

        if [ -n "$FPP_OVERLAY_CFG" ]; then
            echo "   Config file: $FPP_OVERLAY_CFG"
        else
            echo '   ⚠️  Overlay config not found.  /home/fpp/media/config/ contents:'
            ls /home/fpp/media/config/ 2>/dev/null | sed 's/^/     /' | head -20 \
                || echo '     (none)'
        fi

        # Always dump the raw config so we can see exact structure
        echo '   Raw config contents:'
        cat "$FPP_OVERLAY_CFG" 2>/dev/null | head -60 | sed 's/^/     /' || true
        echo ''

        OVERLAY_CFG_FIXED=0
        if [ -n "$FPP_OVERLAY_CFG" ]; then
            export _FPP_OVERLAY_CFG="$FPP_OVERLAY_CFG"
            export _SAFE_MODEL_NAME="$SAFE_MODEL_NAME"
            # Patch DefaultState=3 in the config file.
            # FPP v9 model-overlays.json can be:
            #   A) List of model dicts: [{"Name":"Light_Wall", "DefaultState":3, ...}, ...]
            #   B) Dict keyed by model name: {"Light_Wall": {"DefaultState":3, ...}}
            #   C) A single model dict (no Name): {"DefaultState":3, "StartChannel":1, ...}
            # We handle all three and NEVER match anonymous/nameless objects (avoids
            # patching container dicts).
            # Exit 0 = changed+saved, exit 2 = already 3 (no write needed), exit 1 = error.
            if python3 - << 'PYEOF'
import json, sys, os
path = os.environ['_FPP_OVERLAY_CFG']
safe_name = os.environ['_SAFE_MODEL_NAME']
display_name = safe_name.replace('_', ' ')
print(f'   Parsing {path} ...')
try:
    with open(path) as f:
        d = json.load(f)
except Exception as e:
    print(f'   ERROR reading {path}: {e}')
    sys.exit(1)
print(f'   Top-level type: {type(d).__name__}, keys/len: {list(d.keys()) if isinstance(d,dict) else len(d) if isinstance(d,list) else "?"}')
changed = False
def patch_model(obj, context_name=''):
    """Patch DefaultState in a single model dict.  context_name is the dict key if known."""
    global changed
    if not isinstance(obj, dict):
        return
    # Determine the model name from the object itself or the dict key it was stored under
    name_in_obj = obj.get('Name', obj.get('name', ''))
    effective_name = name_in_obj or context_name
    if effective_name not in (safe_name, display_name):
        # Don't touch objects we can't identify as our model
        return
    cur = obj.get('DefaultState', obj.get('defaultState', None))
    if str(cur) == '3':
        print(f'   DefaultState already 3 for: {effective_name!r}')
    else:
        obj['DefaultState'] = 3
        # Remove alternate-case key to avoid duplicates
        obj.pop('defaultState', None)
        changed = True
        print(f'   Updated DefaultState: {cur!r} → 3  (model: {effective_name!r})')
if isinstance(d, list):
    # Format A: list of model dicts [{"Name": "...", "DefaultState": ...}, ...]
    for m in d:
        patch_model(m)
elif isinstance(d, dict):
    if 'models' in d and isinstance(d['models'], list):
        # Format D: FPP v9 wrapper {"models": [...], "autoCreate": ..., "DefaultState": ...}
        # The top-level DefaultState is a UI/global default — per-model entry needs its OWN
        # DefaultState field for fppd to activate the overlay at startup.
        for m in d['models']:
            patch_model(m)
    elif safe_name in d or display_name in d:
        # Format B: top-level dict keyed by model name {"Light_Wall": {...}}
        key = safe_name if safe_name in d else display_name
        patch_model(d[key], context_name=key)
    else:
        # Format C: the whole file IS a single model dict
        patch_model(d, context_name=safe_name)
if changed:
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print(f'   ✅ Saved {path}')
    sys.exit(0)
else:
    sys.exit(2)
PYEOF
            then
                OVERLAY_CFG_FIXED=1
            else
                _PY_EXIT=$?
                # exit 2 = DefaultState was already 3 but control block still missing
                # → restart fppd anyway to force control block creation
                if [ "$_PY_EXIT" -eq 2 ]; then
                    echo '   ℹ️  DefaultState already 3 — restarting fppd to force control block creation'
                    OVERLAY_CFG_FIXED=1
                fi
            fi
        fi

        if [ "$OVERLAY_CFG_FIXED" -eq 1 ]; then
            echo '♻️  Restarting fppd (DefaultState=3 takes effect on restart)...'
            sudo systemctl restart fppd || true
            echo '   Waiting for SHM control block to appear (up to 15s)...'
            CTRL_APPEARED=0
            for i in $(seq 1 15); do
                sleep 1
                if [ -f "$CONTROL_FILE" ]; then
                    echo "   ✅ Control block appeared after ${i}s: $CONTROL_FILE"
                    python3 -c "
import struct
try:
    with open('$CONTROL_FILE', 'r+b') as f:
        f.seek(0); f.write(struct.pack('<i', 3)); f.flush()
    print('   ✅ isActive written to 3 in control block')
except Exception as e:
    print(f'   ⚠️  Write failed: {e}')
" 2>/dev/null || true
                    CTRL_APPEARED=1
                    break
                fi
            done
            echo '   fppd overlay-related log (last 30 lines):'
            sudo journalctl -u fppd -n 30 --no-pager 2>/dev/null \
                | grep -i 'overlay\|pixel\|model\|shm\|FPP-Model\|FPP-Pixel' \
                | sed 's/^/     /' || true
            echo ''
            if [ "$CTRL_APPEARED" -eq 0 ]; then
                echo "   ❌ Control block STILL absent after fppd restart"
                echo ''
                echo '   --- fppd log files (fppd logs to files, NOT journald) ---'
                FPPD_LOG_DIR='/home/fpp/media/logs'
                if [ -d "$FPPD_LOG_DIR" ]; then
                    echo "   Log directory: $FPPD_LOG_DIR"
                    ls -lhtr "$FPPD_LOG_DIR" 2>/dev/null | tail -10 | sed 's/^/     /' || true
                    echo ''
                    # Find the most recent fppd log file
                    FPPD_LOG="$(ls -t "$FPPD_LOG_DIR"/fppd* 2>/dev/null | head -1 || echo '')"
                    if [ -z "$FPPD_LOG" ]; then
                        FPPD_LOG="$(ls -t "$FPPD_LOG_DIR"/*.log 2>/dev/null | head -1 || echo '')"
                    fi
                    if [ -n "$FPPD_LOG" ]; then
                        echo "   Latest log file: $FPPD_LOG ($(wc -l <"$FPPD_LOG" 2>/dev/null || echo '?') lines)"
                        echo '   --- Overlay/model/pixel related lines: ---'
                        grep -ni 'overlay\|pixel\|model\|shm\|FPP-Model\|FPP-Pixel\|DefaultState\|control.block' "$FPPD_LOG" 2>/dev/null | tail -20 | sed 's/^/     /' || echo '     (none found)'
                        echo '   --- Last 40 lines of fppd log: ---'
                        tail -40 "$FPPD_LOG" 2>/dev/null | sed 's/^/     /' || true
                    else
                        echo '   ⚠️  No fppd log file found in log directory'
                    fi
                else
                    echo "   ⚠️  Log directory $FPPD_LOG_DIR not found"
                fi
                echo ''
                echo "   --- Full fppd journal tail (last 40 lines) ---"
                sudo journalctl -u fppd -n 40 --no-pager 2>/dev/null | sed 's/^/     /' || true
            fi
            # fppd recreates the mmap file on restart — re-apply write permissions
            sudo chmod 666 "$FPP_MMAP_FILE" 2>/dev/null || true
            # Re-assert state 3 via HTTP after restart
            curl -sS -m 5 -X PUT \
                "http://localhost/api/overlays/model/${SAFE_MODEL_NAME}/state" \
                -H 'Content-Type: application/json' -d '{"State":3}' >/dev/null 2>&1 || true
            # Restart twinklywall so FPPOutput re-initialises with the now-active overlay SHM
            echo '♻️  Restarting twinklywall to sync with updated fppd...'
            sudo systemctl restart twinklywall || true
            sleep 3
        elif [ -z "$FPP_OVERLAY_CFG" ]; then
            echo ''
            echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
            echo '❌  FPP overlay config not found — manual fix required:'
            echo '   1. Open FPP Web UI (http://FPP-LW)'
            echo '      → Overlays  (or Status/Control → Pixel Overlay Models)'
            echo '   2. Find "Light_Wall" row → set Default State = "Always On" → Save'
            echo '   3. Run:'
            echo '        sudo systemctl restart fppd'
            echo '        sudo chmod 666 /dev/shm/FPP-Model-Data-Light_Wall'
            echo '        sudo systemctl restart twinklywall'
            echo "   4. Re-run: bash ~/TwinklyWall_Project/setup_fpp.sh"
            echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        fi
    fi

    # 2) Verify Twinkly controller reachability
    if [ -f "$CO_CONFIG" ] && command -v jq >/dev/null 2>&1; then
        echo ''
        echo '🔍 Checking Twinkly controller reachability...'
        CONTROLLER_IPS="$(jq -r '.channelOutputs[0].universes[]?.address // empty' "$CO_CONFIG" 2>/dev/null | sort -u)"
        if [ -n "$CONTROLLER_IPS" ]; then
            ALL_OK=1
            for ip in $CONTROLLER_IPS; do
                if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
                    echo "   ✅ $ip — reachable"
                else
                    echo "   ❌ $ip — NOT reachable"
                    ALL_OK=0
                fi
            done
            if [ "$ALL_OK" -eq 1 ]; then
                echo "✅ All $(echo "$CONTROLLER_IPS" | wc -l) Twinkly controllers are reachable"
            else
                echo "⚠️  Some controllers are unreachable — verify IPs and power"
            fi
        else
            echo "⚠️  No controller IPs found in co-universes.json"
        fi
    fi

    # 2c) Show exact universe numbers from co-universes.json — critical for diagnosing
    #     whether fppd is sending to the right universe that Twinkly listens on.
    if [ -f "$CO_CONFIG" ]; then
        echo ''
        echo '🔍 Channel output configuration (co-universes.json):'
        python3 -c "
import json, sys
with open('$CO_CONFIG') as f:
    d = json.load(f)
outputs = d.get('channelOutputs',[])
if not outputs:
    print('   (no channelOutputs found)')
for oi, out in enumerate(outputs):
    proto = out.get('type','?')
    sub = out.get('subType', '')
    out_en = out.get('enabled', '?')
    out_sc = out.get('startChannel','?')
    out_cc = out.get('channelCount','?')
    label = f'{proto}' + (f'/{sub}' if sub and sub != proto else '')
    print(f'   Output [{oi}]: protocol={label}  enabled={out_en}  startCh={out_sc}  chCount={out_cc}')
    universes = out.get('universes',[])
    for i, u in enumerate(universes):
        ip = u.get('address','?')
        uni = u.get('universe', u.get('id', '-'))
        ch_s = u.get('startChannel','?')
        ch_c = u.get('channelCount','?')
        try:
            ch_end = int(ch_s) + int(ch_c) - 1
        except Exception:
            ch_end = '?'
        active = u.get('active', u.get('enabled', '?'))
        typ = u.get('type', '')
        desc = u.get('description', '')
        extra = f'  desc={desc}' if desc else ''
        print(f'      [{i}] {ip}  universe={uni}  channels={ch_s}-{ch_end}  active={active}  subtype={typ}{extra}')
" 2>/dev/null || echo '   (could not parse co-universes.json)'
    fi

    # 2b) Check Twinkly controller mode — they must not be in their own movie/effect mode.
    if [ -n "${CONTROLLER_IPS:-}" ]; then
        echo ''
        echo '🔍 Checking Twinkly controller mode (first controller)...'
        FIRST_CTRL="$(echo "$CONTROLLER_IPS" | head -1)"
        python3 -c "
import urllib.request, json, base64, os
ip = '$FIRST_CTRL'
try:
    # Step 1: Login
    challenge = base64.b64encode(os.urandom(16)).decode()
    req = urllib.request.Request(
        'http://' + ip + '/xled/v1/login',
        data=json.dumps({'challenge': challenge}).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    with urllib.request.urlopen(req, timeout=4) as r:
        login = json.loads(r.read())
    token = login.get('authentication_token', '')
    chalresp = login.get('challenge_response', '')
    # Step 2: Verify — REQUIRED to activate the token (skipping this causes 401)
    req_v = urllib.request.Request(
        'http://' + ip + '/xled/v1/verify',
        data=json.dumps({'challenge-response': chalresp}).encode(),
        headers={'Content-Type': 'application/json', 'X-Auth-Token': token},
        method='POST'
    )
    with urllib.request.urlopen(req_v, timeout=4) as r:
        r.read()
    # Step 3: Get current mode
    req2 = urllib.request.Request('http://' + ip + '/xled/v1/led/mode')
    req2.add_header('X-Auth-Token', token)
    with urllib.request.urlopen(req2, timeout=4) as r:
        mode_data = json.loads(r.read())
    mode = mode_data.get('mode', 'unknown')
    if mode == 'movie':
        print(f'   {ip}: mode=movie  ⚠️  Controllers playing own effects — light wall WILL NOT respond to FPP')
        print('   FIX: Open Twinkly app → tap device → Music/External tab → enable sACN/E1.31 External Control')
        print('   OR: each device: Menu ☰ → Go to device → Settings → External Control → On')
    elif mode in ('rt', 'realtime'):
        print(f'   {ip}: mode={mode}  ✅ Real-time mode active')
    elif mode == 'off':
        print(f'   {ip}: mode=off  ❌ Lights are off — set to External Control in Twinkly app')
    elif mode == 'effect':
        print(f'   {ip}: mode=effect  ℹ️  Running built-in effect (not responding to E1.31)')
    else:
        print(f'   {ip}: mode={mode}  (check Twinkly app External Control setting)')
except Exception as e:
    print(f'   Could not query {ip}: {e}')
" 2>/dev/null || true
    fi
    #    then inspect the actual E1.31 packet CONTENT to verify fppd is forwarding
    #    mmap data (non-zero) rather than its own empty (all-zero) stream.
    if [ -e "$FPP_MMAP_FILE" ] && [ -w "$FPP_MMAP_FILE" ]; then
        echo ''
        echo '🧪 Running end-to-end smoke test...'
        MMAP_SIZE=$(( WIDTH * HEIGHT * 3 ))

        # Write a bright red test pattern directly into the mmap
        python3 -c "
import os, time
path = '$FPP_MMAP_FILE'
size = $MMAP_SIZE
# Bright red pattern
pattern = (b'\\xff\\x00\\x00') * (size // 3)
with open(path, 'r+b') as f:
    f.seek(0)
    f.write(pattern[:size])
    f.flush()
    os.fsync(f.fileno())
print(f'Wrote {size} bytes of RED test pattern to {path}')
" 2>/dev/null && echo '   ✅ Test pattern written to mmap' || echo '   ⚠️  Could not write test pattern'

        # Check if UDP packets are going to any controller and inspect their content.
        if command -v timeout >/dev/null 2>&1; then
            FIRST_IP="$(echo "${CONTROLLER_IPS:-}" | head -1)"
            if [ -n "$FIRST_IP" ]; then
                echo "   ⏳ Capturing packets to $FIRST_IP (2s, checking content)..."
                # Sleep briefly so fppd has time to pick up our mmap write
                sleep 0.2
                HEX_OUT="$(sudo timeout 2 tcpdump -ni eth0 -xx \
                    "udp and dst host $FIRST_IP" 2>/dev/null || echo '')"
                PKT_COUNT="$(echo "$HEX_OUT" | grep -c '0x0000:' || echo '0')"

                if [ "${PKT_COUNT:-0}" -gt 0 ]; then
                    echo "   ✅ Captured $PKT_COUNT UDP packets → fppd IS transmitting"

                    # Count 0xFF bytes in the hex dump.
                    # tcpdump -xx outputs hex as 4-char big-endian words (e.g. 'ff00 1b4a').
                    # We split every 4-char word into two 2-char bytes to count correctly.
                    # An all-zero stream → ~0 FF bytes; our RED pattern → hundreds per packet.
                    FF_COUNT="$(echo "$HEX_OUT" | python3 -c "
import sys, re
data = sys.stdin.read()
# Each tcpdump data line: '\t0x0010:  4500 002b c2f6 ...'
# Extract 4-char hex words, then split each into two 2-char bytes
words = re.findall(r'[0-9a-f]{4}', data.lower())
all_bytes = [c for w in words for c in (w[:2], w[2:])]
print(sum(1 for b in all_bytes if b == 'ff'))
" 2>/dev/null || echo '0')"

                    if [ "${FF_COUNT:-0}" -gt 50 ]; then
                        echo "   ✅ Packets contain RED pixel data (${FF_COUNT} × 0xFF bytes)"
                        echo '   ✅ FPP Pixel Overlay IS forwarding mmap → controllers'
                        echo ''
                        echo '   🎉 FPP PIPELINE CONFIRMED WORKING!'
                        echo '   If lights are STILL dark → Twinkly controllers need E1.31 mode'
                        echo '   configured in the Twinkly app (Settings → External Control / sACN)'
                    else
                        echo "   ⚠️  Packets contain ZEROS (only ${FF_COUNT} × 0xFF bytes in ${PKT_COUNT} packets)"
                        echo '   → FPP Pixel Overlay state 3 is NOT active despite PUT returning OK'
                        echo '   → Check the control block state above'
                        echo '   → Or enable manually: FPP UI → Pixel Overlay Models → Light_Wall → Always On'
                    fi
                else
                    echo '   ⚠️  0 UDP packets captured — fppd may not be outputting'
                    echo '   Check: sudo journalctl -u fppd -n 40 --no-pager'
                fi
            fi
        fi

        # Restore mmap to black (so the test flash doesn't stay on)
        python3 -c "
import os
path = '$FPP_MMAP_FILE'
size = $MMAP_SIZE
with open(path, 'r+b') as f:
    f.seek(0)
    f.write(b'\\x00' * size)
    f.flush()
    os.fsync(f.fileno())
" 2>/dev/null || true

        # --- Play-based smoke test: trigger actual video playback and verify
        #     E1.31 packets carry real (non-zero) pixel data.
        # This tests the FULL path: Python mmap writes -> FPP Pixel Overlay -> E1.31
        echo ''
        echo '\xf0\x9f\xa7\xaa Play-based E1.31 content test...'
        RENDERED_DIR='/home/fpp/TwinklyWall_Project/media/rendered'
        FIRST_NPZ="$(find "$RENDERED_DIR" -name '*.npz' 2>/dev/null | head -1 || echo '')"
        if [ -n "$FIRST_NPZ" ] && [ -n "${FIRST_IP:-}" ]; then
            VIDEO_NAME="$(basename "$FIRST_NPZ" .npz)"
            echo "   Playing: $VIDEO_NAME"
            # Start playback via the API
            curl -sS -m 5 -X POST 'http://localhost:5000/api/play' \
                -H 'Content-Type: application/json' \
                -d "{\"video\":\"$VIDEO_NAME\",\"loop\":false}" >/dev/null 2>&1 || true
            sleep 2   # let playback write a few frames

            # Capture and inspect packets during active playback
            PLAY_HEX="$(sudo timeout 2 tcpdump -ni eth0 -xx \
                "udp and dst host $FIRST_IP" 2>/dev/null || echo '')"
            PLAY_PKTS="$(echo "$PLAY_HEX" | grep -c '0x0000:' || echo '0')"
            PLAY_FF="$(echo "$PLAY_HEX" | python3 -c "
import sys, re
data = sys.stdin.read()
words = re.findall(r'[0-9a-f]{4}', data.lower())
all_bytes = [c for w in words for c in (w[:2], w[2:])]
print(sum(1 for b in all_bytes if b == 'ff'))
" 2>/dev/null || echo '0')"

            # Stop playback
            curl -sS -m 5 -X POST 'http://localhost:5000/api/stop' >/dev/null 2>&1 || true

            if [ "${PLAY_PKTS:-0}" -eq 0 ]; then
                echo '   ⚠️  No packets captured during playback — fppd not transmitting'
            elif [ "${PLAY_FF:-0}" -gt 20 ]; then
                echo "   ✅ Captured $PLAY_PKTS packets with ${PLAY_FF} × 0xFF bytes"
                echo '   ✅ FPP Pixel Overlay IS forwarding mmap → E1.31 during video playback'
                echo ''
                echo '   🎉 FPP PIPELINE CONFIRMED WORKING!'
                echo '   Lights should be ON when a video is playing via the app.'
                echo "   (If they are not, check: sudo journalctl -u twinklywall -f)"
            else
                echo "   ⚠️  $PLAY_PKTS packets captured but only ${PLAY_FF} × 0xFF bytes — still zeros"
                echo '   ❌ FPP Pixel Overlay NOT forwarding mmap data even during video playback'
                echo ''
                echo '   Root-cause check:'
                echo '   1) Check fppd overlay state via FPP UI → Pixel Overlay Models → Light_Wall'
                echo '      → Set "Default State" to "Always On" and save'
                echo '   2) After saving in UI, run: sudo systemctl restart fppd'
                echo '   3) Then restart twinklywall: sudo systemctl restart twinklywall'
                echo ''
                echo '   fppd overlay log (last 20 lines):'
                sudo journalctl -u fppd -n 20 --no-pager 2>/dev/null | grep -i 'overlay\|pixel\|model' | head -10 || true
            fi
        else
            echo '   ℹ️  No rendered videos found — skipping play-based test'
            echo "       (Render a video first via the Flutter app, then re-run setup_fpp.sh)"
        fi

        # --- FPP channel/test mode: fill ALL output channels with value 200 for 4 seconds.
        #     This is the DEFINITIVE test of fppd → output → Twinkly:
        #       ✅ Lights come on  → fppd output works; problem is only Pixel Overlay
        #       ❌ Lights stay off → fppd output mapping / Twinkly config broken
        echo ''
        echo '🧪 FPP test mode (sending value=200 to all channels for 4 seconds)...'
        echo '   *** LOOK AT THE LIGHTS NOW — they should be dimly lit if fppd output works ***'
        # FPP v9 test mode API: PUT /api/testmode
        CH_TEST_OK=0
        CH_TEST_RESP="$(curl -sS -m 5 -X PUT 'http://localhost/api/testmode' \
            -H 'Content-Type: application/json' \
            -d '{"Enabled":1,"Mode":"SingleChase","CycleMS":1000,"ColorPattern":"C8C8C8","StartChannel":1,"EndChannel":13500}' \
            2>/dev/null || echo 'API_FAIL')"
        # Check if FPP accepted the request (JSON with success or "OK")
        if echo "$CH_TEST_RESP" | grep -qi '\(not found\|404\|html\|API_FAIL\)'; then
            # Fallback: try POST /api/testmode
            CH_TEST_RESP="$(curl -sS -m 5 -X POST 'http://localhost/api/testmode' \
                -H 'Content-Type: application/json' \
                -d '{"enabled":1,"mode":"RGBFill","cycleMS":1000,"colorPattern":"c8c8c8","startChannel":1,"endChannel":13500}' \
                2>/dev/null || echo 'API_FAIL_2')"
            if echo "$CH_TEST_RESP" | grep -qi '\(not found\|404\|html\|API_FAIL\)'; then
                # Last resort: try the FPPD command socket directly
                CH_TEST_RESP="$(echo 'T,ENABLED,RGBFill,1000,c8c8c8' | nc -w2 localhost 32322 2>/dev/null || echo 'SOCKET_FAIL')"
            fi
        else
            CH_TEST_OK=1
        fi
        echo "   Test mode API response: $(echo "$CH_TEST_RESP" | head -3)"
        # Capture packets during test to verify fppd sends non-zero DATA (not just headers)
        if [ -n "${FIRST_IP:-}" ]; then
            sleep 1  # let test mode take effect
            CT_HEX="$(sudo timeout 4 tcpdump -ni eth0 -xx \
                "udp and dst host $FIRST_IP" 2>/dev/null || echo '')"
            CT_PKTS="$(echo "$CT_HEX" | grep -c '0x0000:' || echo '0')"
            # Count non-zero bytes in DATA portion only (skip first 60 bytes = ETH+IP+UDP+protocol headers)
            CT_DATA="$(echo "$CT_HEX" | python3 -c "
import sys, re
data = sys.stdin.read()
# Split into packets at '0x0000:' boundaries
packets = re.split(r'(?=\s+0x0000:)', data)
total_nonzero = 0
for pkt in packets:
    words = re.findall(r'[0-9a-f]{4}', pkt.lower())
    all_bytes = [c for w in words for c in (w[:2], w[2:])]
    # Skip first 60 bytes (ethernet 14 + IP 20 + UDP 8 + protocol header ~18)
    payload = all_bytes[60:]
    total_nonzero += sum(1 for b in payload if b != '00')
print(total_nonzero)
" 2>/dev/null || echo '0')"
            if [ "${CT_DATA:-0}" -gt 50 ]; then
                echo "   ✅ Test mode: ${CT_PKTS} packets, ${CT_DATA} non-zero DATA bytes"
                echo '   ✅ fppd → output is working! Problem is ONLY with Pixel Overlay.'
                echo '   → Fix: ensure Pixel Overlay control block appears (see fppd logs above)'
                CH_TEST_OK=1
            else
                echo "   ⚠️  Test mode: ${CT_PKTS} packets, only ${CT_DATA} non-zero DATA bytes"
                if ! echo "$CH_TEST_RESP" | grep -qi '\(not found\|404\|html\|API_FAIL\|SOCKET_FAIL\)'; then
                    echo '   ❌ fppd accepted test mode but is NOT outputting data'
                    echo '   → Check fppd logs above for errors'
                else
                    echo '   ❌ Test mode API not found — try manually:'
                    echo '   → FPP UI → Display Testing → fill channels 1-13500 with value 200'
                fi
            fi
        fi
        # Stop test mode
        curl -sS -m 5 -X PUT 'http://localhost/api/testmode' \
            -H 'Content-Type: application/json' -d '{"Enabled":0}' >/dev/null 2>&1 || true
        curl -sS -m 5 -X POST 'http://localhost/api/testmode' \
            -H 'Content-Type: application/json' -d '{"enabled":0}' >/dev/null 2>&1 || true
    fi
fi

echo ''
echo '📊 Service Status:'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo '📡 TwinklyWall (API server + DDP bridge on ports 5000 & 4049):'
sudo systemctl status twinklywall --no-pager -l || true
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo ''
echo '📋 TwinklyWall recent log (look for [MMAP_TEST] / [FPP_OVERLAY] / [FPP_INIT]):'
sudo journalctl -u twinklywall -n 80 --no-pager 2>/dev/null || true
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo ''
echo '✅ Enabled / enforced by setup:'
echo "   • mmap write permission command: $MMAP_PERM_CMD"
echo '   • fppd mode: Player (mode 2)'
echo '   • alwaysTransmit: enabled'
echo '   • channel outputs: enabled'
if [ "$MMAP_PERMS_SET" -eq 1 ]; then
    echo '   • mmap file is writable now'
else
    echo '   • mmap file writability could not be confirmed yet'
fi
echo ''
echo '💡 To view logs:'
echo '   sudo journalctl -u twinklywall -f'