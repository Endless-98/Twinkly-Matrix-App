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

# DDP Bridge service
DDP_SERVICE_FILE="/etc/systemd/system/ddp_bridge.service"
if [ $DEBUG_MODE -eq 0 ]; then
    if [ ! -f "$DDP_SERVICE_FILE" ]; then
    echo '⚙️ Installing DDP bridge service...'
    sudo cp ddp_bridge.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable ddp_bridge
    elif ! cmp -s ddp_bridge.service "$DDP_SERVICE_FILE"; then
    echo '🔄 Updating DDP bridge service...'
    sudo cp ddp_bridge.service /etc/systemd/system/
    sudo systemctl daemon-reload
    echo '♻️ Restarting ddp_bridge to apply unit changes...'
    sudo systemctl restart ddp_bridge || true
    else
        echo '✅ DDP bridge service is up to date'
    fi
fi

# Ensure services are running (and no duplicate manual processes)
if [ $DEBUG_MODE -eq 0 ]; then
    # Always reload units in case they changed outside this script
    sudo systemctl daemon-reload || true

    echo '🧹 Ensuring a single clean instance is running...'
    echo '   - Stopping services if active'
    sudo systemctl stop twinklywall ddp_bridge || true

    echo '   - Killing any stray manual Python processes'
    # Kill any manually launched processes for safety (do not fail the script if none)
    pkill -u fpp -f '/home/fpp/TwinklyWall_Project/TwinklyWall/main.py' 2>/dev/null || true
    pkill -u fpp -f '/home/fpp/TwinklyWall_Project/TwinklyWall/api_server.py' 2>/dev/null || true
    pkill -u fpp -f '/home/fpp/TwinklyWall_Project/TwinklyWall/ddp_bridge.py' 2>/dev/null || true

    sleep 0.5

    echo '▶️ Restarting services with latest code...'
    sudo systemctl restart twinklywall || sudo systemctl start twinklywall
    sudo systemctl restart ddp_bridge || sudo systemctl start ddp_bridge
fi

if [ $DEBUG_MODE -eq 1 ]; then
    echo '🧪 Debug mode: stopping any running services to avoid conflicts.'
    sudo systemctl stop twinklywall || true
    sudo systemctl stop ddp_bridge || true
    echo '▶️ Launching DDP debug runner (Ctrl+C to exit)...'
    export TWINKLYWALL_DEBUG=1
    "$PYTHON_BIN" /home/fpp/TwinklyWall_Project/TwinklyWall/debug_ddp.py --port 4049 --width "$WIDTH" --height "$HEIGHT" --model "$MODEL"
    exit 0
fi

echo '✅ Setup/update complete!'
echo ''
echo '📊 Service Status:'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo '📡 TwinklyWall API Server (listens on port 5000):'
sudo systemctl status twinklywall --no-pager -l || true
echo ''
echo '📡 DDP Bridge (listens on port 4049):'
sudo systemctl status ddp_bridge --no-pager -l || true
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo ''
echo '💡 To view logs:'
echo '   API Server:  sudo journalctl -u twinklywall -f'
echo '   DDP Bridge:  sudo journalctl -u ddp_bridge -f'