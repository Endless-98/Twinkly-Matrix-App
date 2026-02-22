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
    echo '🔧 Ensuring "Always Transmit Channel Data" is enabled...'
    AT_FILE="/home/fpp/media/settings/alwaysTransmit"
    ALWAYS_TX_API="$(curl -sS -m 5 'http://localhost/api/settings/alwaysTransmit' 2>/dev/null | tr -d '[:space:][]"' || echo '')"
    ALWAYS_TX_FILE=""
    if [ -f "$AT_FILE" ]; then
        ALWAYS_TX_FILE="$(tr -d '[:space:][]"' < "$AT_FILE" 2>/dev/null || echo '')"
    fi
    ALWAYS_TX="$ALWAYS_TX_API"
    if [ -z "$ALWAYS_TX" ]; then
        ALWAYS_TX="$ALWAYS_TX_FILE"
    fi

    if [ "$ALWAYS_TX" = "1" ] || [ "$ALWAYS_TX" = "true" ]; then
        echo '✅ Always Transmit is already enabled'
    else
        echo '⚠️  Always Transmit is OFF — enabling now...'
        curl -sS -m 5 -X PUT 'http://localhost/api/settings/alwaysTransmit' \
            -H 'Content-Type: application/json' -d '{"value":"1"}' >/dev/null 2>&1 || true
        # Verify API first
        AT_VERIFY="$(curl -sS -m 5 'http://localhost/api/settings/alwaysTransmit' 2>/dev/null | tr -d '[:space:][]"' || echo '')"
        if [ "$AT_VERIFY" = "1" ] || [ "$AT_VERIFY" = "true" ]; then
            echo '✅ Always Transmit enabled successfully (API)'
            NEEDS_FPPD_RESTART=1
        else
            echo '⚠️  API did not persist alwaysTransmit, using settings-file fallback...'
            mkdir -p /home/fpp/media/settings >/dev/null 2>&1 || true
            if echo '1' > "$AT_FILE" 2>/dev/null || sudo sh -c "echo 1 > '$AT_FILE'" 2>/dev/null; then
                AT_FILE_VERIFY="$(tr -d '[:space:][]"' < "$AT_FILE" 2>/dev/null || echo '')"
                if [ "$AT_FILE_VERIFY" = "1" ]; then
                    echo '✅ Always Transmit enabled successfully (settings file)'
                    NEEDS_FPPD_RESTART=1
                else
                    echo '❌ WARNING: Could not verify alwaysTransmit settings file value'
                    echo '   Enable manually in FPP UI → Input/Output Setup → Channel Outputs → Always Transmit'
                fi
            else
                echo '❌ WARNING: Could not write /home/fpp/media/settings/alwaysTransmit'
                echo '   Enable manually in FPP UI → Input/Output Setup → Channel Outputs → Always Transmit'
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
echo '🔍 Checking FPP frame buffer permissions...'
if [ ! -e "$FPP_MMAP_FILE" ]; then
    echo "⚠️  Frame buffer file does not exist yet: $FPP_MMAP_FILE"
    echo "   (This is normal; FPP will create it when the model is activated)"
else
    if [ -w "$FPP_MMAP_FILE" ]; then
        echo "✅ Frame buffer exists and is writable: $FPP_MMAP_FILE"
    else
        echo "⚠️  Frame buffer exists but is NOT writable, fixing permissions..."
        sudo chmod 666 "$FPP_MMAP_FILE" || {
            echo "❌ Failed to set permissions on $FPP_MMAP_FILE"
            echo "   Try running: sudo chmod 666 $FPP_MMAP_FILE"
            exit 1
        }
        echo "✅ Frame buffer permissions fixed"
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
echo '📊 Service Status:'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo '📡 TwinklyWall (API server + DDP bridge on ports 5000 & 4049):'
sudo systemctl status twinklywall --no-pager -l || true
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo ''
echo '💡 To view logs:'
echo '   sudo journalctl -u twinklywall -f'