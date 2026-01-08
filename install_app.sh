#!/bin/bash
set -e

# Script to build and install the latest Flutter app on Android device
# Usage: ./install_app.sh [port]
# Default port: 36583 (or whatever was last used)

PORT="${1:-36583}"  # Default to 36583 if no port provided

echo "🚀 Installing latest app version on Android device..."
echo "📱 Connecting to device on port: $PORT"

# Connect to device
adb connect 192.168.1.36:$PORT

# Wait a moment for connection
sleep 1

# Check if device is connected
if ! adb devices | grep -q "192.168.1.36:$PORT"; then
    echo "❌ Failed to connect to device at 192.168.1.36:$PORT"
    echo "💡 Make sure:"
    echo "   - Wireless debugging is enabled on your phone"
    echo "   - The correct port is provided (check Developer Options > Wireless debugging)"
    exit 1
fi

echo "✅ Connected to device successfully"

# Navigate to Flutter project
cd led_matrix_controller

echo "🔨 Building Flutter APK..."
flutter build apk --release

echo "📦 Installing APK on device..."
flutter install

echo "✅ App installation complete!"
echo "🎮 You can now use the LED Matrix Controller app"