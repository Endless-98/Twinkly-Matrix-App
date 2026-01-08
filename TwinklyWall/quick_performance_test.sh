#!/bin/bash
# Quick DDP Performance Test Script
# Runs enhanced logging for 30 seconds and analyzes results

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         DDP Bridge Performance Quick Test                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "This will:"
echo "  1. Stop existing DDP bridge"
echo "  2. Run with enhanced logging for 30 seconds"
echo "  3. Analyze performance and show bottlenecks"
echo ""
read -p "Press Enter to start..."

# Generate log filename with timestamp
LOG_FILE="ddp_test_$(date +%Y%m%d_%H%M%S).log"

echo ""
echo "Stopping existing DDP bridge service..."
sudo systemctl stop ddp_bridge.service 2>/dev/null

echo ""
echo "Starting DDP bridge with enhanced logging..."
echo "Log file: $LOG_FILE"
echo ""
echo "Let your screen mirroring application send data to this device."
echo "Testing for 30 seconds..."
echo ""

# Run for 30 seconds
cd /home/endless/Portfolio/TwinklyWall_Project/TwinklyWall
timeout 30s python3 debug_ddp.py --verbose 2>&1 | tee "$LOG_FILE"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     ANALYZING RESULTS                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Analyze the logs
python3 analyze_ddp_logs.py "$LOG_FILE"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    TEST COMPLETE                               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Log saved to: $LOG_FILE"
echo ""
echo "To view detailed logs again:"
echo "  cat $LOG_FILE"
echo ""
echo "To re-analyze:"
echo "  python3 analyze_ddp_logs.py $LOG_FILE"
echo ""
echo "To restart normal service:"
echo "  sudo systemctl start ddp_bridge.service"
echo ""
