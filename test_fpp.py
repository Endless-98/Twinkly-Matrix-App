#!/usr/bin/env python3
import time
from dotmatrix import FPPOutput

def main():
    fpp = FPPOutput(width=87, height=50)
    
    print("Starting FPP color wash test...")
    print("Press Ctrl+C to stop")
    
    fpp.test_color_wash(fps=40)
    fpp.close()

if __name__ == "__main__":
    main()
