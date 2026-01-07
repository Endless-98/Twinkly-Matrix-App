#!/usr/bin/env python3
import argparse
import socket
import struct
import sys
import time
from collections import deque

try:
    import numpy as np
    HAS_NUMPY = True
except Exception:
    HAS_NUMPY = False

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
        # Increase receive buffer to reduce packet drops
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)  # 1MB
        except Exception:
            pass
        self.sock.bind(self.addr)
        # Use FPPOutput to target overlay mmap
        mmap_path = f"/dev/shm/FPP-Model-Data-{model_name.replace(' ', '_')}"
        self.out = FPPOutput(width, height, mapping_file=mmap_path)

        # Frame assembly
        self.buf = bytearray(self.frame_size)
        self.bytes_written = 0
        self.last_seq = None
        self.frames = 0
        self.frames_written = 0
        self.frames_dropped = 0
        self.chunks_in_frame = 0
        self.frame_start_ts = 0.0
        self.last_write_ts = 0.0
        self.write_ms_acc = 0.0
        self._sec_start = time.time()
        self._sec_frames_in = 0
        self._sec_frames_out = 0
        self._sec_dropped = 0

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

            # If new sequence start
            if off == 0:
                if self.bytes_written > 0:
                    # Incomplete previous frame; reset counters
                    self.bytes_written = 0
                self.chunks_in_frame = 0
                self.frame_start_ts = time.time()

            end_of_frame = (flags & 0x01) != 0

            # Bounds check
            end = off + ln
            if end > self.frame_size:
                continue

            self.buf[off:end] = payload
            self.bytes_written = max(self.bytes_written, end)
            self.chunks_in_frame += 1

            if end_of_frame and self.bytes_written >= self.frame_size:
                # Rate gate: do not write faster than 20 FPS
                now = time.time()
                since_last = (now - self.last_write_ts) * 1000.0
                if since_last < 50.0:
                    # Drop this frame to keep FPP pacing
                    self.frames_dropped += 1
                    self._sec_dropped += 1
                    self.bytes_written = 0
                    continue

                # Write to overlay using numpy fast path when available
                try:
                    write_start = time.perf_counter()
                    if HAS_NUMPY:
                        arr = np.frombuffer(self.buf, dtype=np.uint8).reshape(self.height, self.width, 3)
                        ms = self.out.write(arr)
                    else:
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
                        ms = self.out.write(view)
                    write_elapsed = (time.perf_counter() - write_start) * 1000.0
                    self.write_ms_acc += write_elapsed
                    self.frames_written += 1
                    self._sec_frames_out += 1
                    self.last_write_ts = now
                except Exception as e:
                    self._log(f"Write error: {e}")
                finally:
                    self.bytes_written = 0

                # Per-second logging
                self._sec_frames_in += 1
                sec_elapsed = time.time() - self._sec_start
                if sec_elapsed >= 1.0:
                    avg_write_ms = (self.write_ms_acc / max(1, self._sec_frames_out))
                    self._log(
                        f"[FPP] 1s stats: in={self._sec_frames_in} fps | out={self._sec_frames_out} fps | drop={self._sec_dropped} | write {avg_write_ms:.2f}ms | chunks/frame={self.chunks_in_frame}"
                    )
                    self._sec_start = time.time()
                    self._sec_frames_in = 0
                    self._sec_frames_out = 0
                    self._sec_dropped = 0
                    self.write_ms_acc = 0.0


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
