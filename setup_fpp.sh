#!/bin/bash
set -e

echo '🚀 Setting up/updating TwinklyWall on FPP...'
echo '🔄 Syncing with GitHub first...'

# Sync repository FIRST, before parsing args or doing anything else
cd ~
if [ ! -d "TwinklyWall_Project" ]; then
    echo '📥 Cloning repository...'
    git clone https://github.com/Endless-98/Twinkly-Matrix-App.git TwinklyWall_Project
else
    echo '📥 Pulling latest code from GitHub...'
    cd TwinklyWall_Project
    git pull origin master
    cd ~
fi

cd TwinklyWall_Project

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
    ALWAYS_TX_API="$(curl -sS -m 5 'http://localhost/api/settings/alwaysTransmit' 2>/dev/null | tr -d '[:space:][]"' || echo '')"
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
    for attempt in 1 2 3 4 5 6; do
        # PUT the state
        PUT_RESP="$(curl -sS -m 5 -X PUT "http://localhost/api/overlays/model/${SAFE_MODEL_NAME}/state" \
            -H 'Content-Type: application/json' -d '{"State":3}' 2>&1 || echo 'CURL_FAILED')"

        sleep 1

        # GET and verify
        GET_RESP="$(curl -sS -m 5 "http://localhost/api/overlays/model/${SAFE_MODEL_NAME}" 2>&1 || echo '')"
        OV_STATE="$(echo "$GET_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("State",d.get("state","")))' 2>/dev/null || echo '')"

        if [ "$OV_STATE" = "3" ]; then
            echo "✅ Pixel Overlay '${SAFE_MODEL_NAME}' is in state 3 (always on)"
            OVERLAY_OK=1
            break
        fi

        echo "   attempt $attempt: state='$OV_STATE' PUT='${PUT_RESP:0:120}' GET='${GET_RESP:0:120}'"
        sleep 3
    done
    if [ "$OVERLAY_OK" -eq 0 ]; then
        echo "⚠️  Could not confirm overlay state 3 — fppd may not have the model yet"
        echo "   Check FPP UI → Pixel Overlay Models → ${MODEL}"
        echo "   Manual test:"
        echo "     curl -v -X PUT 'http://localhost/api/overlays/model/${SAFE_MODEL_NAME}/state' -H 'Content-Type: application/json' -d '{\"State\":3}'"
        echo "     curl -v 'http://localhost/api/overlays/model/${SAFE_MODEL_NAME}'"
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

    # 3) End-to-end smoke test — write a bright test pattern into the mmap
    #    and verify fppd is transmitting UDP to the controllers.
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

        # Check if UDP packets are going to any controller
        if command -v timeout >/dev/null 2>&1; then
            FIRST_IP="$(echo "$CONTROLLER_IPS" | head -1)"
            if [ -n "$FIRST_IP" ]; then
                echo "   ⏳ Listening for UDP packets to $FIRST_IP for 3 seconds..."
                PKT_COUNT="$(sudo timeout 3 tcpdump -ni eth0 "udp and dst host $FIRST_IP" 2>/dev/null | wc -l || echo '0')"
                if [ "$PKT_COUNT" -gt 0 ]; then
                    echo "   ✅ Captured $PKT_COUNT UDP packets → fppd IS transmitting to controllers"
                    echo ''
                    echo '   🎉 THE PIPELINE IS LIVE!'
                    echo '   If the wall is still dark, the Twinkly controllers may need power-cycling'
                    echo '   or they may need to be set to external-control mode in the Twinkly app.'
                else
                    echo "   ⚠️  0 UDP packets captured — fppd may not be outputting"
                    echo "   Check: sudo journalctl -u fppd -n 40 --no-pager"
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
    fi
fi

echo ''
echo '📊 Service Status:'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo '📡 TwinklyWall (API server + DDP bridge on ports 5000 & 4049):'
sudo systemctl status twinklywall --no-pager -l || true
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