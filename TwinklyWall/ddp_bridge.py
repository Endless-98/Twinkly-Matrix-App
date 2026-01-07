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
    p.add_argument("--max-fps", type=float, default=float(os.environ.get("DDP_MAX_FPS", 20)), help="Maximum write FPS to FPP (0 disables pacing)")
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
        # Increase receive buffer to reduce packet drops (4MB)
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)  # 4MB
        except Exception:
            pass
        self.sock.bind(self.addr)
        # Make non-blocking to batch-process packets
        self.sock.setblocking(False)
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
        self.frame_timeout_ms = 50.0  # Reset incomplete frames after 50ms (tightened for faster stale frame drop)
        self.last_write_ts = 0.0
        self.write_ms_acc = 0.0
        self._sec_start = time.time()
        self._sec_frames_in = 0
        self._sec_frames_out = 0
        self._sec_dropped = 0
        self._sec_incomplete = 0
        self._sec_packets = 0

    def _log(self, msg):
        if self.verbose:
            print(msg, flush=True)

    def run(self):
        pacing = f"pacing at <= {self.max_fps:.1f} FPS" if self.max_fps > 0.0 else "no pacing"
        self._log(f"DDP bridge listening on {self.addr[0]}:{self.addr[1]} for {self.width}x{self.height} ({pacing})")
        current_sender = None
        
        while True:
            # Batch-process all available packets
            packets_this_loop = 0
            while packets_this_loop < 200:  # Process up to 200 packets per batch (increased for burst handling)
                try:
                    data, sender = self.sock.recvfrom(1500)
                    packets_this_loop += 1
                    self._sec_packets += 1
                except BlockingIOError:
                    # No more packets available right now
                    break
                except Exception as e:
                    self._log(f"Socket error: {e}")
                    continue
                
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
                        # Incomplete previous frame; reset counters and unlock sender
                        self.bytes_written = 0
                        current_sender = None
                    self.chunks_in_frame = 0
                    self.frame_start_ts = time.time()
                    # Lock to sender for this frame
                    current_sender = sender
                
                # Timeout check: if frame has been assembling for too long, reset it
                if self.frame_start_ts > 0:
                    frame_age_ms = (time.time() - self.frame_start_ts) * 1000.0
                    if frame_age_ms > self.frame_timeout_ms and self.bytes_written > 0:
                        if self.verbose:
                            self._log(f"Frame timeout after {frame_age_ms:.1f}ms with {self.bytes_written} bytes")
                        self.bytes_written = 0
                        self.chunks_in_frame = 0
                        current_sender = None
                        self._sec_incomplete += 1

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

                if end_of_frame:
                    # Check if frame is complete
                    is_complete = self.bytes_written >= self.frame_size
                    if not is_complete:
                        self._sec_incomplete += 1
                        if self.verbose:
                            self._log(f"Incomplete frame: {self.bytes_written}/{self.frame_size} bytes, {self.chunks_in_frame} chunks")
                        self.bytes_written = 0
                        self.chunks_in_frame = 0
                        continue
                        
                    # Optional pacing to avoid overrunning FPP; sleep instead of dropping frames
                    if self.max_fps > 0.0:
                        min_interval_s = 1.0 / self.max_fps
                        now_perf = self._clock()
                        # Convert last_write_ts to perf clock domain when first used
                        if self.last_write_ts == 0.0:
                            self.last_write_ts = now_perf - min_interval_s
                        since_last_s = now_perf - self.last_write_ts
                        if since_last_s < min_interval_s:
                            remaining_s = min_interval_s - since_last_s
                            # Only sleep if remaining time is significant (>0.5ms)
                            if remaining_s > 0.0005:
                                time.sleep(remaining_s)

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
                            f"[FPP] 1s stats: in={self._sec_frames_in} fps | out={self._sec_frames_out} fps | drop={self._sec_dropped} | incomplete={self._sec_incomplete} | pkts={self._sec_packets} | write {avg_write_ms:.2f}ms"
                        )
                        self._sec_start = time.time()
                        self._sec_frames_in = 0
                        self._sec_frames_out = 0
                        self._sec_dropped = 0
                        self._sec_incomplete = 0
                        self._sec_packets = 0
                        self.write_ms_acc = 0.0
            
            # Sleep briefly when no packets to avoid CPU spinning
            if packets_this_loop == 0:
                time.sleep(0.0001)  # 0.1ms


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
