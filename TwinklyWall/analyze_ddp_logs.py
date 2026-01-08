#!/usr/bin/env python3
"""
DDP Bridge Log Analyzer - Identifies performance bottlenecks from enhanced logs
"""

import re
import sys
from collections import defaultdict
from statistics import mean, median, stdev


def parse_log_file(filepath):
    """Parse DDP bridge log file and extract timing metrics."""
    
    stats = {
        'fps_in': [],
        'fps_out': [],
        'incomplete': [],
        'dropped': [],
        'packets': [],
        'recv_time': [],
        'parse_time': [],
        'assembly_time': [],
        'pacing_time': [],
        'numpy_time': [],
        'mmap_time': [],
        'write_avg': [],
        'write_min': [],
        'write_max': [],
        'bandwidth_mbps': [],
        'bytes_per_sec': [],
        'avg_packet_size': [],
        'avg_chunks_per_frame': [],
    }
    
    chunk_info = []
    frame_events = []
    
    with open(filepath, 'r') as f:
        for line in f:
            # Parse 1-second stats
            if '[1s STATS]' in line:
                m = re.search(r'in=(\d+) fps.*out=(\d+) fps.*drop=(\d+).*incomplete=(\d+).*pkts=(\d+)', line)
                if m:
                    stats['fps_in'].append(int(m.group(1)))
                    stats['fps_out'].append(int(m.group(2)))
                    stats['dropped'].append(int(m.group(3)))
                    stats['incomplete'].append(int(m.group(4)))
                    stats['packets'].append(int(m.group(5)))
            
            # Parse timing breakdown
            elif '[TIMING]' in line:
                m = re.search(r'recv=([\d.]+)ms.*parse=([\d.]+)ms.*assembly=([\d.]+)ms.*pacing=([\d.]+)ms.*numpy=([\d.]+)ms.*mmap=([\d.]+)ms.*write_avg=([\d.]+)ms.*write_min=([\d.]+)ms.*write_max=([\d.]+)ms', line)
                if m:
                    stats['recv_time'].append(float(m.group(1)))
                    stats['parse_time'].append(float(m.group(2)))
                    stats['assembly_time'].append(float(m.group(3)))
                    stats['pacing_time'].append(float(m.group(4)))
                    stats['numpy_time'].append(float(m.group(5)))
                    stats['mmap_time'].append(float(m.group(6)))
                    stats['write_avg'].append(float(m.group(7)))
                    stats['write_min'].append(float(m.group(8)))
                    stats['write_max'].append(float(m.group(9)))
            
            # Parse network stats
            elif '[NETWORK]' in line:
                m = re.search(r'bandwidth=([\d.]+) Mbps.*bytes/sec=([\d,]+).*avg_pkt_size=([\d.]+).*avg_chunks/frame=([\d.]+)', line)
                if m:
                    stats['bandwidth_mbps'].append(float(m.group(1)))
                    stats['bytes_per_sec'].append(int(m.group(2).replace(',', '')))
                    stats['avg_packet_size'].append(float(m.group(3)))
                    stats['avg_chunks_per_frame'].append(float(m.group(4)))
            
            # Track frame events
            elif '[FRAME START]' in line or '[FRAME COMPLETE]' in line or '[INCOMPLETE]' in line:
                frame_events.append(line.strip())
            
            # Track chunks
            elif '[CHUNK]' in line:
                m = re.search(r'off=(\d+).*len=(\d+).*bytes_so_far=(\d+)/(\d+).*chunks=(\d+)', line)
                if m:
                    chunk_info.append({
                        'offset': int(m.group(1)),
                        'length': int(m.group(2)),
                        'bytes_so_far': int(m.group(3)),
                        'total': int(m.group(4)),
                        'chunk_count': int(m.group(5))
                    })
    
    return stats, frame_events, chunk_info


def calculate_statistics(values, name):
    """Calculate and print statistics for a metric."""
    if not values:
        return None
    
    return {
        'name': name,
        'count': len(values),
        'mean': mean(values),
        'median': median(values),
        'min': min(values),
        'max': max(values),
        'stdev': stdev(values) if len(values) > 1 else 0
    }


def analyze_bottlenecks(stats):
    """Identify performance bottlenecks from timing data."""
    print("\n" + "="*80)
    print("BOTTLENECK ANALYSIS")
    print("="*80)
    
    if not stats['write_avg']:
        print("No timing data found in logs.")
        return
    
    # Calculate average time spent in each stage
    stages = {
        'Packet Reception': mean(stats['recv_time']) if stats['recv_time'] else 0,
        'Packet Parsing': mean(stats['parse_time']) if stats['parse_time'] else 0,
        'Frame Assembly': mean(stats['assembly_time']) if stats['assembly_time'] else 0,
        'FPS Pacing/Sleep': mean(stats['pacing_time']) if stats['pacing_time'] else 0,
        'NumPy Conversion': mean(stats['numpy_time']) if stats['numpy_time'] else 0,
        'Memory-Map Write': mean(stats['mmap_time']) if stats['mmap_time'] else 0,
    }
    
    total_time = sum(stages.values())
    
    print("\nTime spent per stage (average per operation):")
    print(f"{'Stage':<25} {'Time (ms)':<12} {'% of Total':<12}")
    print("-" * 50)
    
    # Sort by time descending
    sorted_stages = sorted(stages.items(), key=lambda x: x[1], reverse=True)
    
    for stage, time_ms in sorted_stages:
        pct = (time_ms / total_time * 100) if total_time > 0 else 0
        indicator = "🔴" if pct > 30 else "🟡" if pct > 15 else "🟢"
        print(f"{indicator} {stage:<23} {time_ms:>10.3f}ms  {pct:>10.1f}%")
    
    print("-" * 50)
    print(f"{'Total':<25} {total_time:>10.3f}ms  {100.0:>10.1f}%")
    
    # Identify bottlenecks
    print("\n" + "="*80)
    print("RECOMMENDATIONS")
    print("="*80)
    
    for stage, time_ms in sorted_stages[:3]:  # Top 3 slowest
        pct = (time_ms / total_time * 100) if total_time > 0 else 0
        if pct > 30:
            print(f"\n🔴 MAJOR BOTTLENECK: {stage} ({pct:.1f}% of time)")
            provide_recommendation(stage, stats)
        elif pct > 15:
            print(f"\n🟡 MINOR BOTTLENECK: {stage} ({pct:.1f}% of time)")
            provide_recommendation(stage, stats)


def provide_recommendation(stage, stats):
    """Provide optimization recommendations based on bottleneck."""
    
    recommendations = {
        'Packet Reception': [
            "- Increase socket receive buffer (SO_RCVBUF) beyond current 4MB",
            "- Check network interface MTU settings",
            "- Verify no packet loss with: netstat -su | grep 'packet receive errors'",
            "- Consider using SO_TIMESTAMPNS for better timing accuracy"
        ],
        'Packet Parsing': [
            "- Parsing is very lightweight; high % suggests excessive packet fragmentation",
            "- Check if sender is using optimal packet sizes (close to MTU)",
            "- Consider batching parsing operations"
        ],
        'Frame Assembly': [
            "- Reduce memory copies during assembly",
            "- Pre-allocate buffers to avoid reallocation",
            "- Consider using memoryview for zero-copy slicing"
        ],
        'FPS Pacing/Sleep': [
            "- High pacing time is EXPECTED if max_fps is set",
            "- Current setting is throttling to prevent overwhelming FPP",
            "- If FPP can handle more, increase --max-fps parameter",
            "- If pacing is 0 but still slow, bottleneck is elsewhere"
        ],
        'NumPy Conversion': [
            "- Ensure numpy is installed and using fast BLAS/LAPACK",
            "- Check if reshape is causing memory copies (use reshape(-1,3) when possible)",
            "- Consider using numpy views instead of copies",
            "- Profile with: python -m cProfile to find exact hotspot"
        ],
        'Memory-Map Write': [
            "- CRITICAL: This is the actual write to FPP shared memory",
            "- Check if FPP is reading fast enough (may be FPP-side bottleneck)",
            "- Verify memory-mapped file is on tmpfs (/dev/shm)",
            "- Check FPP output settings (channel count, universe settings)",
            "- Reduce write frequency with higher --max-fps throttling",
            "- Check disk I/O with: iostat -x 1"
        ],
    }
    
    if stage in recommendations:
        for rec in recommendations[stage]:
            print(f"  {rec}")


def print_summary(stats):
    """Print summary statistics."""
    print("\n" + "="*80)
    print("PERFORMANCE SUMMARY")
    print("="*80)
    
    metrics = [
        ('FPS Input', stats['fps_in']),
        ('FPS Output', stats['fps_out']),
        ('Packets/sec', stats['packets']),
        ('Bandwidth (Mbps)', stats['bandwidth_mbps']),
        ('Avg Packet Size (bytes)', stats['avg_packet_size']),
        ('Avg Chunks/Frame', stats['avg_chunks_per_frame']),
        ('Incomplete Frames', stats['incomplete']),
        ('Dropped Frames', stats['dropped']),
    ]
    
    print(f"\n{'Metric':<30} {'Mean':<12} {'Min':<12} {'Max':<12} {'StdDev':<12}")
    print("-" * 78)
    
    for name, values in metrics:
        if values:
            stat = calculate_statistics(values, name)
            print(f"{name:<30} {stat['mean']:>10.2f}  {stat['min']:>10.2f}  {stat['max']:>10.2f}  {stat['stdev']:>10.2f}")
    
    # Frame completion rate
    if stats['fps_in'] and stats['fps_out']:
        avg_in = mean(stats['fps_in'])
        avg_out = mean(stats['fps_out'])
        completion_rate = (avg_out / avg_in * 100) if avg_in > 0 else 0
        print(f"\nFrame Completion Rate: {completion_rate:.1f}%")
        
        if completion_rate < 90:
            print("⚠️  WARNING: Low frame completion rate - frames are being dropped or incomplete!")
        elif completion_rate < 100:
            print("⚠️  NOTICE: Some frames incomplete - check packet fragmentation")
        else:
            print("✓ Good frame completion rate")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_ddp_logs.py <log_file>")
        print("\nTo capture logs:")
        print("  ./monitor_ddp.sh 2>&1 | tee ddp_debug.log")
        sys.exit(1)
    
    log_file = sys.argv[1]
    
    print(f"Analyzing DDP Bridge logs from: {log_file}")
    
    stats, frame_events, chunk_info = parse_log_file(log_file)
    
    print_summary(stats)
    analyze_bottlenecks(stats)
    
    # Frame analysis
    if stats['incomplete']:
        print("\n" + "="*80)
        print("INCOMPLETE FRAME ANALYSIS")
        print("="*80)
        print(f"Total incomplete frames: {sum(stats['incomplete'])}")
        if stats['avg_chunks_per_frame']:
            avg_chunks = mean(stats['avg_chunks_per_frame'])
            print(f"Average chunks per frame: {avg_chunks:.1f}")
            print("\nPossible causes:")
            print("  - Packet loss on network")
            print("  - Sender not completing frames")
            print("  - Frame timeout too aggressive (currently 50ms)")
            print("  - Multiple senders interfering")
    
    print("\n" + "="*80)
    print("END OF ANALYSIS")
    print("="*80 + "\n")


if __name__ == "__main__":
    main()
