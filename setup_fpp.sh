#!/bin/bash
set -e

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

# Install/update systemd service
cd ~/TwinklyWall_Project/TwinklyWall
SERVICE_FILE="/etc/systemd/system/twinklywall.service"
if [ ! -f "$SERVICE_FILE" ]; then
    echo '⚙️ Installing systemd service...'
    sudo cp twinklywall.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable twinklywall
elif ! cmp -s twinklywall.service "$SERVICE_FILE"; then
    echo '🔄 Updating systemd service...'
    sudo cp twinklywall.service /etc/systemd/system/
    sudo systemctl daemon-reload
else
    echo '✅ Systemd service is up to date'
fi

# Ensure service is running
if ! sudo systemctl is-active --quiet twinklywall; then
    echo '▶️ Starting twinklywall service...'
    sudo systemctl start twinklywall
else
    echo '✅ Twinklywall service is running'
fi

echo '✅ Setup/update complete!'
echo '📊 Service status:'
sudo systemctl status twinklywall --no-pager