#!/usr/bin/env python3
import argparse
import socket
import struct
import sys
import time

# Local module to write to FPP Pixel Overlay mmap
from dotmatrix.fpp_output import FPPOutput


def parse_args():
    p = argparse.ArgumentParser(description="DDP v1 → FPP Pixel Overlay bridge")
    p.add_argument("--host", default="0.0.0.0", help="Listen address")
    p.add_argument("--port", type=int, default=4049, help="Listen UDP port")
    p.add_argument("--width", type=int, default=90, help="Matrix width")
    p.add_argument("--height", type=int, default=50, help="Matrix height")
    p.add_argument("--model", default="Light_Wall", help="Overlay model name (for mmap file)")
    p.add_argument("--verbose", action="store_true", help="Verbose logging")
    return p.parse_args()


class DdpBridge:
    def __init__(self, host, port, width, height, model_name, verbose=False):
        self.addr = (host, port)
        self.width = width
        self.height = height
        self.frame_size = width * height * 3
        self.verbose = verbose
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(self.addr)
        # Use FPPOutput to target overlay mmap
        mmap_path = f"/dev/shm/FPP-Model-Data-{model_name.replace(' ', '_')}"
        self.out = FPPOutput(width, height, mapping_file=mmap_path)

        # Frame assembly
        self.buf = bytearray(self.frame_size)
        self.bytes_written = 0
        self.last_seq = None
        self.frames = 0

    def _log(self, msg):
        if self.verbose:
            print(msg, flush=True)

    def run(self):
        self._log(f"DDP bridge listening on {self.addr[0]}:{self.addr[1]} for {self.width}x{self.height}")
        while True:
            data, _ = self.sock.recvfrom(1500)
            if not data or data[0] != 0x41:
                continue

            # DDP v1 header (10 bytes): 'A' flags seq off24 len16 dataId16
            if len(data) < 10:
                continue
            flags = data[1]
            seq = data[2]
            off = (data[3] << 16) | (data[4] << 8) | data[5]
            ln = (data[6] << 8) | data[7]
            # dataId = data[8:10] (unused)
            payload = data[10:10+ln]

            if len(payload) != ln:
                continue

            # If new sequence and offset==0, treat as new frame
            if off == 0 and self.bytes_written > 0:
                # Incomplete previous frame; reset
                self.bytes_written = 0

            end_of_frame = (flags & 0x01) != 0

            # Bounds check
            end = off + ln
            if end > self.frame_size:
                continue

            self.buf[off:end] = payload
            self.bytes_written = max(self.bytes_written, end)

            if end_of_frame and self.bytes_written >= self.frame_size:
                # Write to overlay
                try:
                    # Interpret buffer as flat RGB rows; FPPOutput.write expects per-pixel triplets
                    # We can provide a Python list of rows to avoid numpy requirement
                    # But FPPOutput has a numpy fast path. Keep it simple: build a list-of-lists view.
                    rows = self.height
                    cols = self.width
                    view = [
                        [
                            (self.buf[(r*cols + c)*3 + 0],
                             self.buf[(r*cols + c)*3 + 1],
                             self.buf[(r*cols + c)*3 + 2])
                            for c in range(cols)
                        ]
                        for r in range(rows)
                    ]
                    self.out.write(view)
                    self.frames += 1
                    if self.frames % 60 == 0:
                        self._log(f"Frames bridged: {self.frames}")
                except Exception as e:
                    self._log(f"Write error: {e}")
                finally:
                    self.bytes_written = 0


def main():
    args = parse_args()
    try:
        bridge = DdpBridge(args.host, args.port, args.width, args.height, args.model, verbose=args.verbose)
        bridge.run()
    except KeyboardInterrupt:
        print("Exiting.")
        sys.exit(0)


if __name__ == "__main__":
    main()
