#!/usr/bin/env python3
"""
Compare DDP Bridge performance between two log files
"""

import sys
from analyze_ddp_logs import parse_log_file, calculate_statistics
from statistics import mean


def print_comparison(name, before, after, unit="", lower_is_better=False):
    """Print a comparison line with color coding."""
    before_val = mean(before) if before else 0
    after_val = mean(after) if after else 0
    
    if before_val == 0:
        change_pct = 0
        change_str = "N/A"
    else:
        change_pct = ((after_val - before_val) / before_val) * 100
        change_str = f"{change_pct:+.1f}%"
    
    # Determine if change is good or bad
    if change_pct == 0:
        indicator = "="
    elif lower_is_better:
        indicator = "✓" if change_pct < 0 else "✗"
    else:
        indicator = "✓" if change_pct > 0 else "✗"
    
    print(f"{indicator} {name:<30} {before_val:>10.2f}{unit}  →  {after_val:>10.2f}{unit}  ({change_str})")


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 compare_ddp_performance.py <before_log> <after_log>")
        print("\nCompares DDP bridge performance between two test runs.")
        sys.exit(1)
    
    before_file = sys.argv[1]
    after_file = sys.argv[2]
    
    print("="*80)
    print("DDP BRIDGE PERFORMANCE COMPARISON")
    print("="*80)
    print(f"\nBefore: {before_file}")
    print(f"After:  {after_file}")
    
    before_stats, _, _ = parse_log_file(before_file)
    after_stats, _, _ = parse_log_file(after_file)
    
    print("\n" + "="*80)
    print("THROUGHPUT METRICS (higher is better)")
    print("="*80)
    print(f"\n{'Metric':<30} {'Before':<15} {'After':<15} {'Change'}")
    print("-" * 80)
    
    print_comparison("FPS Output", before_stats['fps_out'], after_stats['fps_out'], " fps")
    print_comparison("FPS Input", before_stats['fps_in'], after_stats['fps_in'], " fps")
    print_comparison("Bandwidth", before_stats['bandwidth_mbps'], after_stats['bandwidth_mbps'], " Mbps")
    print_comparison("Packets/sec", before_stats['packets'], after_stats['packets'], "")
    
    print("\n" + "="*80)
    print("TIMING METRICS (lower is better)")
    print("="*80)
    print(f"\n{'Metric':<30} {'Before':<15} {'After':<15} {'Change'}")
    print("-" * 80)
    
    print_comparison("Write Time (avg)", before_stats['write_avg'], after_stats['write_avg'], " ms", lower_is_better=True)
    print_comparison("Write Time (max)", before_stats['write_max'], after_stats['write_max'], " ms", lower_is_better=True)
    print_comparison("NumPy Conversion", before_stats['numpy_time'], after_stats['numpy_time'], " ms", lower_is_better=True)
    print_comparison("Memory-Map Write", before_stats['mmap_time'], after_stats['mmap_time'], " ms", lower_is_better=True)
    print_comparison("Packet Reception", before_stats['recv_time'], after_stats['recv_time'], " ms", lower_is_better=True)
    print_comparison("Packet Parsing", before_stats['parse_time'], after_stats['parse_time'], " ms", lower_is_better=True)
    print_comparison("Frame Assembly", before_stats['assembly_time'], after_stats['assembly_time'], " ms", lower_is_better=True)
    
    print("\n" + "="*80)
    print("ERROR METRICS (lower is better)")
    print("="*80)
    print(f"\n{'Metric':<30} {'Before':<15} {'After':<15} {'Change'}")
    print("-" * 80)
    
    print_comparison("Incomplete Frames/sec", before_stats['incomplete'], after_stats['incomplete'], "", lower_is_better=True)
    print_comparison("Dropped Frames/sec", before_stats['dropped'], after_stats['dropped'], "", lower_is_better=True)
    
    print("\n" + "="*80)
    print("NETWORK EFFICIENCY")
    print("="*80)
    print(f"\n{'Metric':<30} {'Before':<15} {'After':<15} {'Change'}")
    print("-" * 80)
    
    print_comparison("Avg Packet Size", before_stats['avg_packet_size'], after_stats['avg_packet_size'], " bytes")
    print_comparison("Chunks per Frame", before_stats['avg_chunks_per_frame'], after_stats['avg_chunks_per_frame'], "", lower_is_better=True)
    
    # Overall assessment
    print("\n" + "="*80)
    print("OVERALL ASSESSMENT")
    print("="*80)
    
    before_fps = mean(before_stats['fps_out']) if before_stats['fps_out'] else 0
    after_fps = mean(after_stats['fps_out']) if after_stats['fps_out'] else 0
    
    before_write = mean(before_stats['write_avg']) if before_stats['write_avg'] else 0
    after_write = mean(after_stats['write_avg']) if after_stats['write_avg'] else 0
    
    before_incomplete = mean(before_stats['incomplete']) if before_stats['incomplete'] else 0
    after_incomplete = mean(after_stats['incomplete']) if after_stats['incomplete'] else 0
    
    improvements = []
    regressions = []
    
    if after_fps > before_fps:
        improvements.append(f"FPS increased by {((after_fps - before_fps) / before_fps * 100):.1f}%")
    elif after_fps < before_fps:
        regressions.append(f"FPS decreased by {((before_fps - after_fps) / before_fps * 100):.1f}%")
    
    if before_write > 0 and after_write < before_write:
        improvements.append(f"Write time improved by {((before_write - after_write) / before_write * 100):.1f}%")
    elif before_write > 0 and after_write > before_write:
        regressions.append(f"Write time regressed by {((after_write - before_write) / before_write * 100):.1f}%")
    
    if before_incomplete > 0 and after_incomplete < before_incomplete:
        improvements.append(f"Incomplete frames reduced by {((before_incomplete - after_incomplete) / before_incomplete * 100):.1f}%")
    elif after_incomplete > before_incomplete and after_incomplete > 0:
        regressions.append(f"Incomplete frames increased by {((after_incomplete - before_incomplete) / max(before_incomplete, 1) * 100):.1f}%")
    
    if improvements:
        print("\n✓ IMPROVEMENTS:")
        for imp in improvements:
            print(f"  • {imp}")
    
    if regressions:
        print("\n✗ REGRESSIONS:")
        for reg in regressions:
            print(f"  • {reg}")
    
    if not improvements and not regressions:
        print("\n= NO SIGNIFICANT CHANGE")
    
    print("\n" + "="*80 + "\n")


if __name__ == "__main__":
    main()
