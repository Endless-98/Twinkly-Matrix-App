#!/usr/bin/env python3
"""Benchmark FPP write performance with numpy arrays."""

import os
import sys
import time
import numpy as np

# Setup headless mode
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['SDL_AUDIODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

from dotmatrix import DotMatrix, FPPOutput

def benchmark_fpp_write():
    """Test FPP write performance with numpy arrays."""
    print("FPP Write Performance Benchmark")
    print("=" * 60)
    
    # Create a fake FPP output for testing
    width, height = 90, 50
    fpp = FPPOutput(width, height, "/dev/shm/FPP-Model-Data-Light_Wall-test")
    
    # Create test data as numpy array (what render_frame passes)
    dot_colors_numpy = np.random.randint(0, 256, (height, width, 3), dtype=np.uint8)
    
    # Create test data as nested list (legacy format)
    dot_colors_tuple = [
        [(r, g, b) for r, g, b in dot_colors_numpy[row]]
        for row in range(height)
    ]
    
    # Warmup
    print("\nWarming up...")
    for _ in range(10):
        fpp.write(dot_colors_numpy)
    
    # Benchmark numpy arrays (should be fast now)
    print("\nBenchmarking numpy array write (direct access)...")
    times_numpy = []
    for i in range(100):
        t = fpp.write(dot_colors_numpy)
        times_numpy.append(t)
    
    avg_numpy = np.mean(times_numpy)
    min_numpy = np.min(times_numpy)
    max_numpy = np.max(times_numpy)
    
    print(f"  Average: {avg_numpy:.2f}ms")
    print(f"  Min:     {min_numpy:.2f}ms")
    print(f"  Max:     {max_numpy:.2f}ms")
    
    # Benchmark nested list (legacy, slower)
    print("\nBenchmarking tuple/list write (legacy)...")
    times_tuple = []
    for i in range(100):
        t = fpp.write(dot_colors_tuple)
        times_tuple.append(t)
    
    avg_tuple = np.mean(times_tuple)
    min_tuple = np.min(times_tuple)
    max_tuple = np.max(times_tuple)
    
    print(f"  Average: {avg_tuple:.2f}ms")
    print(f"  Min:     {min_tuple:.2f}ms")
    print(f"  Max:     {max_tuple:.2f}ms")
    
    # Cleanup
    fpp.close()
    if os.path.exists("/dev/shm/FPP-Model-Data-Light_Wall-test"):
        os.remove("/dev/shm/FPP-Model-Data-Light_Wall-test")
    
    print("\n" + "=" * 60)
    print(f"Numpy is {avg_tuple/avg_numpy:.1f}x faster than tuple format")
    print(f"For 40 FPS target (25ms/frame): FPP write should be <3ms")
    print(f"Current numpy: {avg_numpy:.2f}ms {'✓ OK' if avg_numpy < 3 else '✗ TOO SLOW'}")
    print("=" * 60)


if __name__ == "__main__":
    benchmark_fpp_write()
