#!/usr/bin/env python3
import argparse
import os
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
    # Default model name comes from environment if available
    p.add_argument("--model", default=os.environ.get("FPP_MODEL_NAME", "Light_Wall"), help="Overlay model name (for mmap file)")
    p.add_argument("--max-fps", type=float, default=float(os.environ.get("DDP_MAX_FPS", 30)), help="Maximum write FPS to FPP (0 disables pacing)")
    p.add_argument("--verbose", action="store_true", help="Verbose logging")
    return p.parse_args()


class DdpBridge:
    def __init__(self, host, port, width, height, model_name, max_fps=30.0, verbose=False):
        self.addr = (host, port)
        self.width = width
        self.height = height
        self.frame_size = width * height * 3
        self.verbose = verbose
        self.max_fps = float(max(0.0, max_fps or 0.0))
        # Use perf_counter for scheduling precision
        self._clock = time.perf_counter
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # Bind exclusively to avoid multiple bridges competing
        # (Do not enable SO_REUSEADDR for this UDP port)
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
        pacing = f"pacing at <= {self.max_fps:.1f} FPS" if self.max_fps > 0.0 else "no pacing"
        self._log(f"DDP bridge listening on {self.addr[0]}:{self.addr[1]} for {self.width}x{self.height} ({pacing})")
        current_sender = None
        while True:
            data, sender = self.sock.recvfrom(1500)
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
                # Lock to sender for this frame
                current_sender = sender

            # Ignore packets from other senders mid-frame
            if current_sender is not None and sender != current_sender:
                if self.verbose:
                    print(f"Ignoring packet from {sender} (current {current_sender})", flush=True)
                continue

            end_of_frame = (flags & 0x01) != 0

            # Bounds check
            end = off + ln
            if end > self.frame_size:
                continue

            self.buf[off:end] = payload
            self.bytes_written = max(self.bytes_written, end)
            self.chunks_in_frame += 1

            if end_of_frame and self.bytes_written >= self.frame_size:
                # Optional pacing to avoid overrunning FPP; sleep instead of dropping frames
                if self.max_fps > 0.0:
                    min_interval_ms = 1000.0 / self.max_fps
                    now_perf = self._clock()
                    # Convert last_write_ts to perf clock domain when first used
                    if self.last_write_ts == 0.0:
                        self.last_write_ts = now_perf - (min_interval_ms / 1000.0)
                    since_last_ms = (now_perf - self.last_write_ts) * 1000.0
                    if since_last_ms < min_interval_ms:
                        remaining_ms = min_interval_ms - since_last_ms
                        # Sleep the remainder to hit target interval
                        time.sleep(remaining_ms / 1000.0)

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
                    # Update last write using perf clock for accuracy
                    self.last_write_ts = self._clock()
                except Exception as e:
                    self._log(f"Write error: {e}")
                finally:
                    self.bytes_written = 0
                    current_sender = None

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
        bridge = DdpBridge(args.host, args.port, args.width, args.height, args.model, max_fps=args.max_fps, verbose=args.verbose)
        bridge.run()
    except KeyboardInterrupt:
        print("Exiting.")
        sys.exit(0)


if __name__ == "__main__":
    main()
