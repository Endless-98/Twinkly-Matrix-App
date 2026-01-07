#!/bin/bash
set -e

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

echo '🚀 Setting up/updating TwinklyWall on FPP...'

# Sync repository
cd ~
if [ ! -d "TwinklyWall_Project" ]; then
    echo '📥 Cloning repository...'
    git clone https://github.com/Endless-98/Twinkly-Matrix-App.git TwinklyWall_Project
else
    echo '🔄 Updating repository...'
    cd TwinklyWall_Project
    git pull
    cd ~
fi

cd TwinklyWall_Project

# Setup Python environment
cd TwinklyWall
if [ ! -d ".venv" ]; then
    echo '🐍 Creating Python virtual environment...'
    python3 -m venv .venv
else
    echo '✅ Python virtual environment already exists'
fi

echo '📦 Activating virtual environment and checking dependencies...'
source .venv/bin/activate

# Check if requirements are installed and up to date
if pip check > /dev/null 2>&1; then
    echo '✅ Python dependencies are satisfied'
else
    echo '🔄 Installing/updating Python dependencies...'
    pip install -r requirements.txt
fi

deactivate

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

# Ensure services are running
if [ $DEBUG_MODE -eq 0 ]; then
    # Always reload units in case they changed outside this script
    sudo systemctl daemon-reload || true
    if ! sudo systemctl is-active --quiet twinklywall; then
    echo '▶️ Starting twinklywall service...'
    sudo systemctl start twinklywall
    else
        echo '✅ Twinklywall service is running'
    fi
fi

if [ $DEBUG_MODE -eq 0 ]; then
    # Reload again before starting bridge to clear any change warnings
    sudo systemctl daemon-reload || true
    if ! sudo systemctl is-active --quiet ddp_bridge; then
    echo '▶️ Starting DDP bridge service...'
    sudo systemctl start ddp_bridge
    else
        echo '✅ DDP bridge service is running'
    fi
fi

if [ $DEBUG_MODE -eq 1 ]; then
    echo '🧪 Debug mode: stopping any running services to avoid conflicts.'
    sudo systemctl stop twinklywall || true
    sudo systemctl stop ddp_bridge || true
    echo '▶️ Launching DDP debug runner (Ctrl+C to exit)...'
    /home/fpp/TwinklyWall_Project/TwinklyWall/.venv/bin/python /home/fpp/TwinklyWall_Project/TwinklyWall/debug_ddp.py --port 4049 --width "$WIDTH" --height "$HEIGHT" --model "$MODEL"
    exit 0
fi

echo '✅ Setup/update complete!'
echo '📊 Service status:'
sudo systemctl status twinklywall --no-pager -l || true
echo ''
sudo systemctl status ddp_bridge --no-pager -l || true