#!/bin/bash
# Monitor DDP Bridge with enhanced logging

echo "=========================================="
echo "DDP Bridge Performance Monitor"
echo "=========================================="
echo ""
echo "This will show detailed timing for:"
echo "  - Packet reception & parsing"
echo "  - Frame assembly"
echo "  - Pacing/throttling"
echo "  - NumPy conversion"
echo "  - Memory-mapped writes"
echo "  - Network bandwidth"
echo ""
echo "Press Ctrl+C to stop"
echo "=========================================="
echo ""

# Stop existing service if running
sudo systemctl stop ddp_bridge.service 2>/dev/null

# Run with enhanced logging
cd /home/endless/Portfolio/TwinklyWall_Project/TwinklyWall
python3 debug_ddp.py --verbose
