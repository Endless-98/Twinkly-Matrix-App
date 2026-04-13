#!/bin/bash
set -e

# Script to build and install the latest Flutter app on Android device
# Usage:
#   ./install_app.sh [port]
#   ./install_app.sh <pair_ip> <pair_port> <connect_port>
#   ./install_app.sh <pairing_code> <pair_ip> <pair_port> <connect_port>

PAIRING_CODE=""
PAIR_IP="192.168.1.36"
PAIR_PORT="36583"
CONNECT_PORT="36583"

if [ "$#" -eq 1 ]; then
  PAIR_PORT="$1"
  CONNECT_PORT="$1"
elif [ "$#" -eq 3 ]; then
  PAIR_IP="$1"
  PAIR_PORT="$2"
  CONNECT_PORT="$3"
elif [ "$#" -eq 4 ]; then
  PAIRING_CODE="$1"
  PAIR_IP="$2"
  PAIR_PORT="$3"
  CONNECT_PORT="$4"
fi

echo "🚀 Installing latest app version on Android device..."
echo "📱 Pairing to device at: $PAIR_IP:$PAIR_PORT"
echo "📱 Connecting to device on port: $CONNECT_PORT"

# Pair with device if pairing code is provided and the device is not already connected
if [ -n "$PAIRING_CODE" ]; then
  if adb devices | grep -q "$PAIR_IP:$CONNECT_PORT"; then
    echo "✅ Device already connected at $PAIR_IP:$CONNECT_PORT, skipping pair step."
  else
    printf '%s\n' "$PAIRING_CODE" | adb pair "$PAIR_IP:$PAIR_PORT"
    echo "✅ Pairing attempted with code $PAIRING_CODE"
    sleep 1
  fi
fi

# Connect to device
adb connect "$PAIR_IP:$CONNECT_PORT"

# Wait a moment for connection
sleep 1

# Check if device is connected
if ! adb devices | grep -q "$PAIR_IP:$CONNECT_PORT"; then
    echo "❌ Failed to connect to device at $PAIR_IP:$CONNECT_PORT"
    echo "💡 Make sure:"
    echo "   - Wireless debugging is enabled on your phone"
    echo "   - The correct ports are provided (pair port and connect port)"
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