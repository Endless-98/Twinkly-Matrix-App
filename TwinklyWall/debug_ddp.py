#!/usr/bin/env python3
import argparse
import os
import sys
import time

# Ensure local imports work when launched directly
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from ddp_bridge import DdpBridge  # noqa: E402


def parse_args():
    p = argparse.ArgumentParser(description="TwinklyWall DDP Debug Runner")
    p.add_argument("--host", default="0.0.0.0", help="Listen address")
    p.add_argument("--port", type=int, default=4049, help="Listen UDP port")
    p.add_argument("--width", type=int, default=90, help="Matrix width")
    p.add_argument("--height", type=int, default=50, help="Matrix height")
    p.add_argument(
        "--model",
        default=os.environ.get("FPP_MODEL_NAME", "Light Wall"),
        help="Overlay model name (spaces allowed)",
    )
    p.add_argument("--max-fps", type=float, default=float(os.environ.get("DDP_MAX_FPS", 20)), help="Maximum write FPS to FPP (0 disables pacing)")
    p.add_argument("--verbose", action="store_true", help="Enable verbose logging")
    return p.parse_args()


def main():
    # Unbuffered stdout for live logs
    os.environ.setdefault("PYTHONUNBUFFERED", "1")

    args = parse_args()

    print("==================== TwinklyWall DDP Debug ====================", flush=True)
    print(f"Target: {args.width}x{args.height} model='{args.model}' on {args.host}:{args.port}", flush=True)
    if args.verbose:
        print("Verbose logging enabled. Press CTRL+C to exit.", flush=True)
    print("===============================================================", flush=True)

    # Bridge uses underscores in mmap filename internally; allow spaces here
    try:
        bridge = DdpBridge(args.host, args.port, args.width, args.height, args.model, max_fps=args.max_fps, verbose=args.verbose or True)
        bridge.run()
    except KeyboardInterrupt:
        print("\nDebug runner exiting.", flush=True)
        sys.exit(0)


if __name__ == "__main__":
    main()
