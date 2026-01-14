#!/bin/bash
# Deploy TwinklyWall changes to FPP device

set -e

# Configuration - set these environment variables or edit the script
FPP_HOST="${FPP_HOST:-YOUR_FPP_IP_OR_HOSTNAME}"
FPP_PORT="${FPP_PORT:-35099}"
FPP_USER="${FPP_USER:-fpp}"

if [ "$FPP_HOST" = "YOUR_FPP_IP_OR_HOSTNAME" ]; then
    echo "❌ Please set the FPP_HOST environment variable or edit this script"
    echo ""
    echo "Usage:"
    echo "  export FPP_HOST=192.168.1.100  # Your FPP device's IP address"
    echo "  ./deploy_to_fpp.sh"
    echo ""
    echo "Or edit the FPP_HOST variable in this script directly."
    echo ""
    echo "To find your FPP IP:"
    echo "  - Check your router's DHCP client list"
    echo "  - Look for a device named 'FPP' or similar"
    echo "  - FPP web interface is usually at http://[IP]:80"
    exit 1
fi

echo "🚀 Deploying TwinklyWall changes to FPP device..."
echo "Host: $FPP_HOST:$FPP_PORT"
echo "User: $FPP_USER"

# Check if we can connect
echo "Testing SSH connection..."
ssh -p "$FPP_PORT" -o ConnectTimeout=5 "$FPP_USER@$FPP_HOST" "echo 'SSH connection successful'" || {
    echo "❌ Cannot connect to FPP device at $FPP_HOST:$FPP_PORT"
    echo "Make sure:"
    echo "  - FPP device is powered on and connected to network"
    echo "  - SSH is enabled on FPP (Settings -> Network -> SSH)"
    echo "  - Port forwarding is set up if connecting remotely"
    exit 1
}

# Sync the repository
echo "📥 Syncing repository..."
ssh -p "$FPP_PORT" "$FPP_USER@$FPP_HOST" "
    cd ~
    if [ ! -d 'TwinklyWall_Project' ]; then
        echo 'Cloning repository...'
        git clone https://github.com/Endless-98/Twinkly-Matrix-App.git TwinklyWall_Project
    else
        echo 'Updating repository...'
        cd TwinklyWall_Project
        git pull
    fi
"

# Create symlink for game_over image if it doesn't exist
echo "🔗 Creating game_over.png symlink..."
ssh -p "$FPP_PORT" "$FPP_USER@$FPP_HOST" "
    cd ~/TwinklyWall_Project/TwinklyWall/games
    if [ ! -e game_over.png ]; then
        ln -sf game_over_screen.png game_over.png
        echo 'Created symlink: game_over.png -> game_over_screen.png'
    else
        echo 'Symlink already exists'
    fi
"

# Run the setup script in debug mode
echo "🧪 Running setup script with debug logging..."
ssh -p "$FPP_PORT" "$FPP_USER@$FPP_HOST" "
    cd ~/TwinklyWall_Project
    chmod +x setup_fpp.sh
    ./setup_fpp.sh --debug
"

echo "✅ Deployment complete!"
echo "Debug logs should now be visible in the terminal above."
echo "Test joining Tetris from your phone to see the join logs."