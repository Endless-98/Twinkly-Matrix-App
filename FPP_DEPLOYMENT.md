# Deploying to FPP - Git Pull Workflow

## Initial Setup on FPP

### 1. Clone the Repository

```bash
cd ~
git clone https://github.com/Endless-98/Twinkly-Matrix-App.git TwinklyWall_Project
cd TwinklyWall_Project
```

### 2. Set Up Python Environment

```bash
cd TwinklyWall
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
deactivate
```

### 3. Install Systemd Service

```bash
# Copy service file
sudo cp TwinklyWall/twinklywall.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable twinklywall

# Start the service
sudo systemctl start twinklywall

# Check status
sudo systemctl status twinklywall
```

## Updating the Application

Whenever you push changes to GitHub, update the FPP with:

```bash
# Navigate to the project directory
cd ~/TwinklyWall_Project

# Pull latest changes
git pull origin master

# If Python dependencies changed, update them
cd TwinklyWall
source .venv/bin/activate
pip install -r requirements.txt
deactivate

# Restart the service
sudo systemctl restart twinklywall

# Verify it's running
sudo systemctl status twinklywall
```

### Quick Update Script

Create a script for easy updates:

```bash
cat > ~/update_twinklywall.sh << 'EOF'
#!/bin/bash
set -e

echo "🔄 Updating TwinklyWall..."

cd ~/TwinklyWall_Project
echo "📥 Pulling latest changes from GitHub..."
git pull origin master

cd TwinklyWall
echo "📦 Updating Python dependencies..."
source .venv/bin/activate
pip install -r requirements.txt --quiet
deactivate

echo "🔄 Restarting service..."
sudo systemctl restart twinklywall

echo "✅ Update complete!"
echo "📊 Service status:"
sudo systemctl status twinklywall --no-pager
EOF

chmod +x ~/update_twinklywall.sh
```

Then update with just:
```bash
~/update_twinklywall.sh
```

## Viewing Logs

```bash
# View live logs
sudo journalctl -u twinklywall -f

# View recent logs
sudo journalctl -u twinklywall -n 100

# View logs since boot
sudo journalctl -u twinklywall -b
```

## Troubleshooting

### Service won't start
```bash
# Check service status
sudo systemctl status twinklywall

# Check logs
sudo journalctl -u twinklywall -n 50

# Manually test the app
cd ~/TwinklyWall_Project/TwinklyWall
source .venv/bin/activate
python main.py --mode api
```

### Git conflicts
```bash
cd ~/TwinklyWall_Project

# Stash local changes
git stash

# Pull updates
git pull origin master

# If you want your changes back
git stash pop
```

### Reset to remote version
```bash
cd ~/TwinklyWall_Project

# WARNING: This discards ALL local changes
git fetch origin
git reset --hard origin/master

# Restart service
sudo systemctl restart twinklywall
```

## Directory Structure on FPP

```
~/TwinklyWall_Project/
├── TwinklyWall/              # Python backend
│   ├── .venv/                # Virtual environment (not in git)
│   ├── main.py               # Entry point
│   ├── api_server.py         # REST API
│   ├── requirements.txt      # Python dependencies
│   ├── twinklywall.service   # Systemd service file
│   └── dotmatrix/            # LED control modules
│       └── rendered_videos/  # Pre-rendered video cache
│
├── led_matrix_controller/    # Flutter app (not used on FPP)
└── Documentation files
```

## API Endpoints (for testing)

Once running, test the API:

```bash
# Health check
curl http://192.168.1.68:5000/api/health

# List videos
curl http://192.168.1.68:5000/api/videos

# Play a video
curl -X POST http://192.168.1.68:5000/api/play \
  -H "Content-Type: application/json" \
  -d '{"filename": "Shireworks - Trim_90x50_20fps.npz", "fps": 20, "brightness": 80, "loop": true}'

# Stop playback
curl -X POST http://192.168.1.68:5000/api/stop

# Get status
curl http://192.168.1.68:5000/api/status
```

## Backup Configuration

### Before major updates, backup your config:

```bash
# Backup rendered videos
cp -r ~/TwinklyWall_Project/TwinklyWall/dotmatrix/rendered_videos ~/twinklywall_backup_$(date +%Y%m%d)

# Backup systemd service
sudo cp /etc/systemd/system/twinklywall.service ~/twinklywall_service_backup_$(date +%Y%m%d).service
```

## Development Workflow

1. **On your laptop**: Make changes, test with Flutter app
2. **Commit and push**: `git commit -am "Description" && git push`
3. **On FPP**: Run `~/update_twinklywall.sh`
4. **Test**: Use Flutter app to verify changes work

## Notes

- The `.gitignore` excludes build files, virtual environments, and large video files
- Video files in `source_videos/` are NOT synced to git (too large)
- Rendered videos ARE synced (compressed .npz format)
- All configuration changes should be committed to git
- The systemd service runs as user `fpp` by default
