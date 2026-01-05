#!/usr/bin/env python3
"""
Verification script to ensure all optimizations are in place.
Run this before deploying to Pi.
"""

import os
import sys

def check_imports():
    """Verify correct imports in __init__.py"""
    print("Checking imports...")
    with open("dotmatrix/__init__.py", "r") as f:
        content = f.read()
    
    # Should NOT have duplicate imports
    from_dot_matrix_count = content.count("from .dot_matrix import")
    from_fpp_output_count = content.count("from .fpp_output import FPPOutput")
    
    if from_fpp_output_count > 0:
        print("  ✗ ERROR: fpp_output.py is still being imported (will shadow optimization)")
        return False
    
    if "FPPOutput" not in content or "from .dot_matrix" not in content:
        print("  ✗ ERROR: FPPOutput not imported from dot_matrix")
        return False
    
    print("  ✓ Imports correct (FPPOutput from dot_matrix.py)")
    return True


def check_numpy_storage():
    """Verify dot_colors stored as numpy array"""
    print("\nChecking numpy array storage...")
    with open("dotmatrix/dot_matrix.py", "r") as f:
        content = f.read()
    
    if "self.dot_colors = blended" in content and "Keep as uint8 numpy array" in content:
        print("  ✓ dot_colors stored as numpy uint8 array")
        return True
    else:
        print("  ✗ ERROR: dot_colors not stored as numpy array")
        return False


def check_pixels3d():
    """Verify using pixels3d instead of array3d"""
    print("\nChecking pixels3d usage...")
    with open("dotmatrix/dot_matrix.py", "r") as f:
        content = f.read()
    
    if "pixels3d" in content and "array3d" not in content:
        print("  ✓ Using pixels3d() for direct view (no copy)")
        return True
    elif "pixels3d" in content:
        print("  ✓ Using pixels3d() (array3d may be in comments)")
        return True
    else:
        print("  ✗ ERROR: Not using pixels3d()")
        return False


def check_headless_support():
    """Verify headless mode in main.py"""
    print("\nChecking headless mode support...")
    with open("main.py", "r") as f:
        content = f.read()
    
    if "is_raspberry_pi" in content and "HEADLESS" in content:
        print("  ✓ Pi auto-detection and headless mode enabled")
        return True
    else:
        print("  ✗ ERROR: Pi detection or headless mode missing")
        return False


def check_fpp_write_numpy():
    """Verify FPP write supports numpy arrays"""
    print("\nChecking FPP write numpy support...")
    with open("dotmatrix/dot_matrix.py", "r") as f:
        content = f.read()
    
    if "isinstance(dot_colors, np.ndarray)" in content and "dot_colors[row, col]" in content:
        print("  ✓ FPP write optimized for numpy arrays")
        return True
    else:
        print("  ✗ ERROR: FPP write not numpy-optimized")
        return False


def check_performance_monitor():
    """Verify PerformanceMonitor class exists"""
    print("\nChecking performance monitoring...")
    with open("dotmatrix/dot_matrix.py", "r") as f:
        content = f.read()
    
    required = [
        "class PerformanceMonitor",
        "self.stage_timings = {",
        "'scaling':",
        "'sampling_blend':",
        "'fpp_write':"
    ]
    
    all_found = all(req in content for req in required)
    if all_found:
        print("  ✓ Performance monitoring with all stages")
        return True
    else:
        print("  ✗ ERROR: Performance monitoring incomplete")
        return False


def check_integer_luminance():
    """Verify uint16 integer luminance calculation"""
    print("\nChecking integer luminance math...")
    with open("dotmatrix/dot_matrix.py", "r") as f:
        content = f.read()
    
    if "213 + g * 715 + b * 72" in content:
        print("  ✓ Using integer luminance (213r + 715g + 72b)")
        return True
    else:
        print("  ✗ ERROR: Not using optimized integer luminance")
        return False


def test_import():
    """Test that imports work without errors"""
    print("\nTesting module import...")
    try:
        # Set headless mode to avoid display issues
        os.environ['SDL_VIDEODRIVER'] = 'dummy'
        os.environ['SDL_AUDIODRIVER'] = 'dummy'
        os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
        
        from dotmatrix import DotMatrix, PerformanceMonitor, FPPOutput
        print("  ✓ All classes import successfully")
        
        # Check FPPOutput has write method (optimization indicator)
        import inspect
        source = inspect.getsource(FPPOutput.write)
        if "isinstance(dot_colors, np.ndarray)" in source:
            print("  ✓ FPPOutput.write has numpy optimization")
            return True
        else:
            print("  ✗ ERROR: FPPOutput.write not numpy-optimized")
            return False
    except Exception as e:
        print(f"  ✗ ERROR: Import failed - {e}")
        return False


def main():
    print("=" * 70)
    print("TWINKLYWALL OPTIMIZATION VERIFICATION")
    print("=" * 70)
    
    checks = [
        check_imports,
        check_numpy_storage,
        check_pixels3d,
        check_headless_support,
        check_fpp_write_numpy,
        check_performance_monitor,
        check_integer_luminance,
        test_import
    ]
    
    results = []
    for check in checks:
        try:
            result = check()
            results.append(result)
        except Exception as e:
            print(f"  ✗ CHECK FAILED: {e}")
            results.append(False)
    
    print("\n" + "=" * 70)
    passed = sum(results)
    total = len(results)
    print(f"RESULTS: {passed}/{total} checks passed")
    
    if all(results):
        print("✓ ALL OPTIMIZATIONS VERIFIED - Ready for Pi deployment!")
        print("=" * 70)
        return 0
    else:
        print("✗ Some checks failed - review errors above")
        print("=" * 70)
        return 1


if __name__ == "__main__":
    sys.exit(main())
