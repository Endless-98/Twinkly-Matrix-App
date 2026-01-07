#!/bin/bash
set -e

echo '🚀 Setting up TwinklyWall on FPP...'

# Clone repository
cd ~
git clone https://github.com/Endless-98/Twinkly-Matrix-App.git TwinklyWall_Project
cd TwinklyWall_Project

# Setup Python environment
cd TwinklyWall
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
deactivate

# Install systemd service
sudo cp twinklywall.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable twinklywall
sudo systemctl start twinklywall

echo '✅ Setup complete!'
echo '📊 Service status:'
sudo systemctl status twinklywall --no-pager