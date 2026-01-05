#!/usr/bin/env python3
import time
from dotmatrix import FPPOutput

def main():
    fpp = FPPOutput(width=87, height=50)
    
    print("Starting FPP color wash test...")
    print("Verifying FPP shared memory write access...")
    
    if not fpp.verify_write():
        print("\nTroubleshooting:")
        print("1. Check if /dev/shm/FPP-Model-Data-Light_Wall exists")
        print("2. Check file permissions: ls -la /dev/shm/FPP-Model-Data-Light_Wall")
        print("3. Ensure FPP is running and configured correctly")
        print("4. Try: sudo chmod 666 /dev/shm/FPP-Model-Data-Light_Wall")
        return
    
    print("\nPress Ctrl+C to stop")
    
    fpp.test_color_wash(fps=40)
    fpp.close()

if __name__ == "__main__":
    main()
