# DDP Bridge Performance Debugging Guide

## Overview

The DDP Bridge now includes comprehensive logging to track all aspects of DDP communication and identify performance bottlenecks in screen mirroring.

## Enhanced Logging Features

The enhanced logging tracks:

1. **Packet Reception** - Time spent receiving UDP packets from the network
2. **Packet Parsing** - Time parsing DDP protocol headers
3. **Frame Assembly** - Time assembling multi-packet frames into complete buffers
4. **FPS Pacing** - Time spent in throttling/sleeping to match target FPS
5. **NumPy Conversion** - Time converting buffers to NumPy arrays
6. **Memory-Map Writes** - Time writing to FPP shared memory
7. **Network Statistics** - Bandwidth, packet sizes, fragmentation
8. **Frame Statistics** - Completion rates, dropped/incomplete frames

## Quick Start - Monitor Performance

### 1. Start the Enhanced Logger

```bash
cd TwinklyWall
./monitor_ddp.sh
```

This will:
- Stop any running DDP bridge service
- Start the bridge with verbose logging enabled
- Display detailed real-time performance metrics

### 2. Capture Logs for Analysis

To save logs for later analysis:

```bash
./monitor_ddp.sh 2>&1 | tee ddp_performance.log
```

Press Ctrl+C when you have enough data (30-60 seconds recommended).

### 3. Analyze the Logs

```bash
python3 analyze_ddp_logs.py ddp_performance.log
```

This will generate:
- Performance summary with statistics
- Bottleneck analysis showing where time is spent
- Specific recommendations for optimization
- Frame completion analysis

## Understanding the Output

### Real-time Logging Format

Every second, you'll see three log lines:

#### 1. Frame Statistics
```
[1s STATS] in=20 fps | out=20 fps | drop=0 | incomplete=0 | pkts=40
```
- `in` - Frames received per second
- `out` - Frames written to FPP per second
- `drop` - Frames dropped (should be 0)
- `incomplete` - Incomplete frames discarded
- `pkts` - Total DDP packets received

#### 2. Timing Breakdown
```
[TIMING] recv=0.015ms parse=0.008ms assembly=0.012ms | pacing=0.00ms numpy=2.15ms mmap=3.45ms | write_avg=5.60ms write_min=4.20ms write_max=8.10ms
```
- `recv` - Average time per packet reception
- `parse` - Average time per packet parsing
- `assembly` - Average time per frame assembly operation
- `pacing` - Average pacing sleep time per frame
- `numpy` - Average NumPy conversion time per frame
- `mmap` - Average memory-map write time per frame
- `write_avg/min/max` - Total write statistics

#### 3. Network Statistics
```
[NETWORK] bandwidth=5.76 Mbps | bytes/sec=720,000 | avg_pkt_size=450.0 | avg_chunks/frame=2.0
```
- `bandwidth` - Network throughput in Mbps
- `bytes/sec` - Bytes received per second
- `avg_pkt_size` - Average packet size (optimal: close to 1472 bytes)
- `avg_chunks/frame` - Packets per frame (lower is better)

### Per-Packet Events

When verbose logging is enabled, you'll also see detailed events:

```
[FRAME START] New frame from ('192.168.1.100', 54321), seq=42
[CHUNK] off=0 len=1440 bytes_so_far=1440/13500 chunks=1 eof=False
[CHUNK] off=1440 len=1440 bytes_so_far=2880/13500 chunks=2 eof=False
...
[FRAME COMPLETE] Ready to write: 13500 bytes in 10 chunks
[WRITE NUMPY] numpy_convert=2.15ms mmap_write=3.45ms total=5.60ms
```

## Common Bottlenecks and Solutions

### High Memory-Map Write Time (>10ms)

**Symptoms:**
- `mmap` time is >30% of total write time
- FPS output is lower than input

**Likely causes:**
1. FPP is not reading data fast enough
2. Too many channels/pixels configured in FPP
3. FPP output drivers are slow

**Solutions:**
- Check FPP output configuration (Settings → Channel Outputs)
- Verify universe count matches actual LED count
- Reduce FPP output refresh rate if too high
- Check FPP system load: `top` on FPP device
- Enable FPP performance mode if available

### High Pacing Time

**Symptoms:**
- `pacing` time is very high (>20ms)
- Output FPS matches `--max-fps` setting exactly

**This is NORMAL if:**
- You have `--max-fps` set (default 20)
- Pacing time ≈ (1000ms / max_fps) - write_time

**This means the bridge is throttling to avoid overloading FPP.**

**Solutions:**
- If FPP can handle more, increase `--max-fps`:
  ```bash
  # Edit ddp_bridge.service and add:
  --max-fps 30
  ```
- To remove throttling entirely: `--max-fps 0` (not recommended)

### High NumPy Conversion Time (>5ms)

**Symptoms:**
- `numpy` time is >20% of total time
- Large variance in conversion times

**Solutions:**
- Verify NumPy is using optimized BLAS:
  ```bash
  python3 -c "import numpy as np; np.__config__.show()"
  ```
- Install optimized NumPy if needed:
  ```bash
  pip3 install numpy[blas]
  ```
- Check if system is swapping: `free -h`

### Packet Fragmentation (High chunks/frame)

**Symptoms:**
- `avg_chunks/frame` is >20
- Many incomplete frames

**Solutions:**
- Sender is fragmenting frames into too many small packets
- Check sender's MTU settings
- Verify sender is using optimal DDP packet sizes (1400-1440 bytes)
- Check network for packet loss: `netstat -su | grep errors`

### Incomplete Frames

**Symptoms:**
- `incomplete` count is >0
- Output FPS < Input FPS

**Causes:**
1. Network packet loss
2. Multiple senders sending simultaneously
3. Frame timeout too aggressive (currently 50ms)

**Solutions:**
- Check network quality between sender and receiver
- Ensure only one sender is active at a time
- Increase frame timeout in [ddp_bridge.py](TwinklyWall/ddp_bridge.py#L67):
  ```python
  self.frame_timeout_ms = 100.0  # Increase from 50ms
  ```

## Performance Tuning Parameters

### DDP Bridge Command-Line Options

```bash
python3 ddp_bridge.py --help
```

Key parameters:

- `--max-fps 20` - Maximum output FPS (default: 20, 0=unlimited)
- `--host 0.0.0.0` - Listen address
- `--port 4049` - Listen port (DDP default)
- `--width 90` - Matrix width
- `--height 50` - Matrix height
- `--model "Light Wall"` - FPP model name
- `--verbose` - Enable detailed logging

### Environment Variables

```bash
export DDP_MAX_FPS=30          # Override default max FPS
export FPP_MODEL_NAME="Light Wall"  # FPP model name
```

### System-Level Tuning

#### Increase UDP Receive Buffer (if packet loss)

```bash
# Check current settings
sysctl net.core.rmem_max
sysctl net.core.rmem_default

# Increase if needed (requires root)
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.rmem_default=8388608
```

#### Optimize Network Interface

```bash
# Check for dropped packets
netstat -su | grep -i "receive errors"

# Check interface stats
ifconfig eth0  # or wlan0

# Disable power management on WiFi (if using wireless)
sudo iwconfig wlan0 power off
```

## Automated Performance Testing

### 1. Run Test Session

```bash
# Start logging
./monitor_ddp.sh 2>&1 | tee test_$(date +%Y%m%d_%H%M%S).log &

# Let it run for 60 seconds
sleep 60

# Stop
killall -INT python3
```

### 2. Compare Configurations

Test different settings:

```bash
# Test 1: Default (20 FPS)
python3 ddp_bridge.py --max-fps 20 --verbose 2>&1 | tee test_20fps.log

# Test 2: Higher FPS (30 FPS)
python3 ddp_bridge.py --max-fps 30 --verbose 2>&1 | tee test_30fps.log

# Test 3: Unlimited
python3 ddp_bridge.py --max-fps 0 --verbose 2>&1 | tee test_unlimited.log

# Analyze each
python3 analyze_ddp_logs.py test_20fps.log > analysis_20fps.txt
python3 analyze_ddp_logs.py test_30fps.log > analysis_30fps.txt
python3 analyze_ddp_logs.py test_unlimited.log > analysis_unlimited.txt
```

## Integration with Systemd Service

To enable verbose logging in the systemd service:

```bash
# Edit service file
sudo nano /etc/systemd/system/ddp_bridge.service

# Add --verbose flag to ExecStart
ExecStart=/usr/bin/python3 /path/to/ddp_bridge.py --verbose

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ddp_bridge.service

# View logs
sudo journalctl -u ddp_bridge.service -f
```

## Performance Targets

For smooth screen mirroring at 90×50 resolution:

- **Network bandwidth:** 5-10 Mbps (depending on FPS)
- **Frame completion rate:** >98%
- **Incomplete frames:** <1 per second
- **Memory-map write time:** <5ms average
- **Total write time:** <15ms for 30 FPS, <50ms for 20 FPS
- **Packet sizes:** 1000-1440 bytes (closer to MTU is better)
- **Chunks per frame:** <15 (fewer is better)

## Troubleshooting Checklist

- [ ] Verified NumPy is installed: `python3 -c "import numpy"`
- [ ] Checked FPP model name matches: Check `/dev/shm/FPP-Model-Data-*`
- [ ] Confirmed FPP is receiving data: Check FPP status page
- [ ] Network shows no packet loss: `netstat -su | grep error`
- [ ] Only one sender is active at a time
- [ ] Sender is using appropriate packet sizes
- [ ] FPP output channels are correctly configured
- [ ] System is not under heavy CPU/memory load: `top`
- [ ] Memory-mapped file is on tmpfs: `df -h /dev/shm`

## Additional Resources

- [DDP Protocol Specification](http://www.3waylabs.com/ddp/)
- [FPP Documentation](https://github.com/FalconChristmas/fpp)
- [NumPy Performance Tips](https://numpy.org/doc/stable/user/performance.html)

## Support

If performance issues persist after tuning:

1. Capture a 60-second log with `./monitor_ddp.sh`
2. Run `python3 analyze_ddp_logs.py <logfile>`
3. Note the top bottlenecks identified
4. Check system resources during capture
5. Review FPP configuration and logs
