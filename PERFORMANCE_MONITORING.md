# DDP Performance Monitoring - Quick Start

## What Was Enhanced

The DDP bridge now includes comprehensive performance logging to identify bottlenecks in screen mirroring. All timing aspects are tracked:

### Tracked Metrics:
- **Packet Reception** - UDP socket receive time
- **Packet Parsing** - DDP protocol parsing time  
- **Frame Assembly** - Multi-packet frame assembly time
- **FPS Pacing** - Throttling/sleep time
- **NumPy Conversion** - Buffer to array conversion time
- **Memory-Map Write** - FPP shared memory write time
- **Network Stats** - Bandwidth, packet sizes, fragmentation
- **Frame Stats** - Completion rates, drops, incomplete frames

## Quick Start

### Option 1: Quick 30-Second Test (Recommended)

```bash
cd TwinklyWall
./quick_performance_test.sh
```

This will automatically:
1. Stop existing DDP bridge
2. Run enhanced logging for 30 seconds
3. Analyze results and show bottlenecks
4. Save log file for later review

### Option 2: Continuous Monitoring

```bash
cd TwinklyWall
./monitor_ddp.sh
```

Press Ctrl+C when done, then analyze with:

```bash
python3 analyze_ddp_logs.py <logfile>
```

### Option 3: Manual Logging & Analysis

```bash
cd TwinklyWall

# Capture logs
python3 debug_ddp.py --verbose 2>&1 | tee performance.log

# Analyze (in another terminal after capturing data)
python3 analyze_ddp_logs.py performance.log
```

## Reading the Analysis

The analyzer will show:

### 1. Performance Summary
- FPS rates (input vs output)
- Network bandwidth and packet stats
- Frame completion rates

### 2. Bottleneck Analysis
Shows time spent in each stage with color coding:
- 🔴 **Red (>30%)** - Major bottleneck, fix immediately
- 🟡 **Yellow (15-30%)** - Minor bottleneck, consider optimizing
- 🟢 **Green (<15%)** - Normal, no action needed

### 3. Specific Recommendations
Actionable fixes for each identified bottleneck

## Common Issues & Fixes

### Slow Rendering → High Memory-Map Write Time
**Fix:** Check FPP configuration, reduce output channels, or enable performance mode

### Throttled FPS → High Pacing Time
**Fix:** Increase `--max-fps` parameter (currently 20 FPS by default)

### Frame Loss → High Incomplete Frames
**Fix:** Check network quality, reduce packet fragmentation, or increase frame timeout

### Poor Conversion → High NumPy Time
**Fix:** Install optimized NumPy with BLAS support

## Comparing Before/After Changes

After making configuration changes, compare performance:

```bash
# Before changes
./quick_performance_test.sh  # Creates test_TIMESTAMP.log

# Make your changes...

# After changes  
./quick_performance_test.sh  # Creates another test_TIMESTAMP.log

# Compare
python3 compare_ddp_performance.py test_before.log test_after.log
```

## Files Created

| File | Purpose |
|------|---------|
| `monitor_ddp.sh` | Start DDP bridge with enhanced logging |
| `quick_performance_test.sh` | Run automated 30-second test |
| `analyze_ddp_logs.py` | Analyze log files and identify bottlenecks |
| `compare_ddp_performance.py` | Compare two test runs |
| `DDP_PERFORMANCE_DEBUG.md` | Complete reference guide |

## Next Steps

1. Run `./quick_performance_test.sh` to establish baseline
2. Review the bottleneck analysis
3. Implement top 1-2 recommendations
4. Run test again and compare results
5. Repeat until performance targets are met

## Performance Targets

For smooth 90×50 screen mirroring:
- **Output FPS:** Match input FPS (ideally 20-30 FPS)
- **Frame completion:** >98%
- **Write time:** <15ms average
- **Incomplete frames:** <1/sec

## Getting Help

See `DDP_PERFORMANCE_DEBUG.md` for:
- Detailed metric explanations
- Advanced troubleshooting
- System-level tuning
- FPP configuration tips
