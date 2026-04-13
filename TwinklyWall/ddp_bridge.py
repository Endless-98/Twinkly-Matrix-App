#!/usr/bin/env python3
"""DDP v1 -> FPP Pixel Overlay bridge.

Listens for DDP (Distributed Display Protocol) packets on UDP, assembles
multi-packet frames, and writes completed frames to the FPP memory-mapped
Pixel Overlay buffer.  Can run standalone or as a background thread from
the main TwinklyWall service.
"""

import argparse
import os
import socket
import sys
import time
from collections import deque

try:
    import numpy as np
    HAS_NUMPY = True
except Exception:
    HAS_NUMPY = False

from dotmatrix.fpp_output import FPPOutput


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="DDP v1 -> FPP Pixel Overlay bridge")
    p.add_argument("--host", default="0.0.0.0", help="Listen address")
    p.add_argument("--port", type=int, default=4049, help="Listen UDP port")
    p.add_argument("--width", type=int, default=90, help="Matrix width")
    p.add_argument("--height", type=int, default=50, help="Matrix height")
    p.add_argument(
        "--model",
        default=os.environ.get("FPP_MODEL_NAME", "Light_Wall"),
        help="Overlay model name (for mmap file)",
    )
    p.add_argument(
        "--max-fps", type=float,
        default=float(os.environ.get("DDP_MAX_FPS", 20)),
        help="Maximum write FPS to FPP (0 disables pacing)",
    )
    p.add_argument(
        "--frame-timeout-ms", type=float,
        default=float(os.environ.get("DDP_FRAME_TIMEOUT_MS", 100.0)),
        help="Timeout before discarding incomplete frames (ms)",
    )
    p.add_argument(
        "--batch-limit", type=int,
        default=int(os.environ.get("DDP_BATCH_LIMIT", 200)),
        help="Max packets to process per loop iteration",
    )
    p.add_argument(
        "--duration-sec", type=float,
        default=float(os.environ.get("DDP_DURATION_SEC", 0)),
        help="Run duration in seconds (0 = unlimited)",
    )
    p.add_argument("--verbose", action="store_true", help="Verbose logging")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Frame assembly helper
# ---------------------------------------------------------------------------

class _FrameState:
    """Tracks partial assembly of a single DDP frame from multiple packets."""

    __slots__ = ("buf", "received", "missing", "chunks", "sender", "seq",
                 "saw_eof", "start_ts")

    def __init__(self, frame_size, sender, seq):
        self.buf = bytearray(frame_size)
        self.received = bytearray(frame_size)
        self.missing = frame_size
        self.chunks = 0
        self.sender = sender
        self.seq = seq
        self.saw_eof = False
        self.start_ts = time.time()

    def add_chunk(self, offset, payload):
        end = offset + len(payload)
        self.buf[offset:end] = payload
        segment = memoryview(self.received)[offset:end]
        newly_covered = len(segment) - sum(segment)
        segment[:] = b"\x01" * len(segment)
        self.missing -= newly_covered
        self.chunks += 1

    @property
    def complete(self):
        return self.missing == 0 and self.saw_eof


# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------

class DdpBridge:
    """Receives DDP v1 UDP frames and writes them to the FPP Pixel Overlay."""

    # DDP v1 header layout (10 bytes):
    #   [0] 0x41 ('A')   [1] flags   [2] sequence
    #   [3..5] 24-bit data offset   [6..7] 16-bit data length
    #   [8..9] 16-bit data ID
    _DDP_MAGIC = 0x41
    _DDP_FLAG_PUSH = 0x01
    _HEADER_SIZE = 10

    def __init__(self, host="0.0.0.0", port=4049, width=90, height=50,
                 model_name="Light_Wall", *, max_fps=20.0,
                 frame_timeout_ms=100.0, batch_limit=200,
                 duration_sec=None, verbose=False):
        self.addr = (host, port)
        self.width = width
        self.height = height
        self.frame_size = width * height * 3
        self.verbose = verbose
        self.max_fps = max(0.0, float(max_fps or 0))
        self.frame_timeout_ms = float(frame_timeout_ms)
        self.batch_limit = int(batch_limit)
        self.duration_sec = float(duration_sec) if duration_sec else None
        self._running = False

        # UDP socket
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        except OSError:
            pass
        self.sock.bind(self.addr)
        self.sock.setblocking(False)

        # FPP output (mmap)
        mmap_path = f"/dev/shm/FPP-Model-Data-{model_name.replace(' ', '_')}"
        self.out = FPPOutput(width, height, mapping_file=mmap_path, gamma=2.2)

        # Frame assembly state
        self._active_frames: dict = {}   # (sender, seq) -> _FrameState
        self._completed: deque = deque(maxlen=50)
        self._max_active = 12

        # Pacing
        self._last_write_ts = 0.0

        # Per-interval (1 s) counters
        self._interval_start = time.time()
        self._iv_frames_in = 0
        self._iv_frames_out = 0
        self._iv_packets = 0
        self._iv_dropped = 0
        self._iv_incomplete = 0
        self._iv_write_ms = 0.0

        # Lifetime totals
        self._tot_frames_in = 0
        self._tot_frames_out = 0
        self._tot_packets = 0
        self._tot_dropped = 0
        self._tot_incomplete = 0

    # -- logging helpers ----------------------------------------------------

    def _log(self, msg):
        if self.verbose:
            print(msg, flush=True)

    @staticmethod
    def _log_always(msg):
        print(msg, flush=True)

    def _reset_interval(self):
        """Accumulate interval counters into totals and reset."""
        self._tot_frames_in += self._iv_frames_in
        self._tot_frames_out += self._iv_frames_out
        self._tot_packets += self._iv_packets
        self._tot_dropped += self._iv_dropped
        self._tot_incomplete += self._iv_incomplete
        self._iv_frames_in = 0
        self._iv_frames_out = 0
        self._iv_packets = 0
        self._iv_dropped = 0
        self._iv_incomplete = 0
        self._iv_write_ms = 0.0
        self._interval_start = time.time()

    def _maybe_log_interval(self):
        """Print a 1-second stats line if the interval has elapsed."""
        elapsed = time.time() - self._interval_start
        if elapsed < 1.0:
            return
        if self._iv_packets > 0 or self._iv_frames_out > 0:
            avg_write = self._iv_write_ms / max(1, self._iv_frames_out)
            self._log_always(
                f"[DDP_BRIDGE] in={self._iv_frames_in} out={self._iv_frames_out} "
                f"pkts={self._iv_packets} drop={self._iv_dropped} "
                f"incomplete={self._iv_incomplete} "
                f"write_avg={avg_write:.2f}ms"
            )
        self._reset_interval()

    # -- main loop ----------------------------------------------------------

    def run(self):
        """Block and process DDP packets until stopped or duration expires."""
        self._running = True
        run_start = time.time()

        pacing_desc = (f"pacing <= {self.max_fps:.0f} FPS"
                       if self.max_fps > 0 else "no pacing")
        self._log_always(f"[DDP_BRIDGE] ========================================")
        self._log_always(
            f"[DDP_BRIDGE] Listening {self.addr[0]}:{self.addr[1]} "
            f"for {self.width}x{self.height} ({pacing_desc})"
        )
        self._log_always(f"[DDP_BRIDGE] Waiting for DDP packets...")
        self._log_always(f"[DDP_BRIDGE] ========================================")

        first_packet = False
        first_frame_written = False
        last_status = time.time()

        while self._running:
            # -- batch-receive packets ------------------------------------
            packets_this_loop = 0
            while packets_this_loop < self.batch_limit:
                try:
                    data, sender = self.sock.recvfrom(65536)
                    packets_this_loop += 1
                    self._iv_packets += 1
                except BlockingIOError:
                    break
                except OSError:
                    continue

                # Validate DDP magic byte
                if not data or data[0] != self._DDP_MAGIC:
                    continue

                if not first_packet:
                    first_packet = True
                    self._log_always(
                        f"[DDP_BRIDGE] First packet: {len(data)} bytes "
                        f"from {sender}"
                    )

                # Parse header
                if len(data) < self._HEADER_SIZE:
                    continue
                flags = data[1]
                seq = data[2]
                offset = (data[3] << 16) | (data[4] << 8) | data[5]
                length = (data[6] << 8) | data[7]
                payload = data[self._HEADER_SIZE:self._HEADER_SIZE + length]
                if len(payload) != length:
                    continue

                # Assemble frame
                key = (sender, seq)
                if key not in self._active_frames:
                    if len(self._active_frames) >= self._max_active:
                        oldest_key = min(
                            self._active_frames,
                            key=lambda k: self._active_frames[k].start_ts,
                        )
                        self._active_frames.pop(oldest_key)
                        self._iv_incomplete += 1
                    self._active_frames[key] = _FrameState(
                        self.frame_size, sender, seq
                    )

                frame = self._active_frames[key]
                if offset + length > self.frame_size:
                    continue
                frame.add_chunk(offset, payload)
                if flags & self._DDP_FLAG_PUSH:
                    frame.saw_eof = True
                if frame.complete:
                    self._completed.append(frame)
                    self._active_frames.pop(key, None)
                    self._iv_frames_in += 1

            # -- expire incomplete frames ---------------------------------
            now = time.time()
            expired = [
                k for k, f in self._active_frames.items()
                if (now - f.start_ts) * 1000 > self.frame_timeout_ms
            ]
            for k in expired:
                self._active_frames.pop(k)
                self._iv_incomplete += 1

            # -- pacing ---------------------------------------------------
            wrote = False
            if self.max_fps > 0:
                min_interval = 1.0 / self.max_fps
                now_perf = time.perf_counter()
                if self._last_write_ts == 0:
                    self._last_write_ts = now_perf - min_interval
                wait = min_interval - (now_perf - self._last_write_ts)
                if wait > 0.0005:
                    time.sleep(wait)

            # -- write latest completed frame -----------------------------
            if self._completed:
                latest = self._completed.pop()
                # Drop older queued frames to minimize latency
                if self._completed:
                    self._iv_dropped += len(self._completed)
                    self._completed.clear()

                try:
                    if HAS_NUMPY:
                        arr = np.frombuffer(
                            latest.buf, dtype=np.uint8
                        ).reshape(self.height, self.width, 3)
                        write_ms = self.out.write(arr)
                    else:
                        view = [
                            [
                                (latest.buf[(r * self.width + c) * 3],
                                 latest.buf[(r * self.width + c) * 3 + 1],
                                 latest.buf[(r * self.width + c) * 3 + 2])
                                for c in range(self.width)
                            ]
                            for r in range(self.height)
                        ]
                        write_ms = self.out.write(view)

                    self._iv_write_ms += write_ms
                    self._iv_frames_out += 1
                    self._last_write_ts = time.perf_counter()
                    wrote = True

                    if not first_frame_written:
                        first_frame_written = True
                        sample = bytes(latest.buf[:12]).hex()
                        self._log_always(
                            f"[DDP_BRIDGE] First frame written! "
                            f"{self.frame_size}B, {latest.chunks} chunks, "
                            f"pixels={sample}"
                        )
                except Exception as e:
                    self._log(f"[DDP_BRIDGE] Write error: {e}")

            # -- stats / idle sleep ---------------------------------------
            self._maybe_log_interval()

            if packets_this_loop == 0 and not wrote:
                time.sleep(0.0001)

            # Periodic "waiting" message when idle
            now = time.time()
            if now - last_status >= 5.0:
                if not first_packet:
                    self._log_always(
                        f"[DDP_BRIDGE] Waiting for packets on "
                        f"UDP {self.addr[1]}..."
                    )
                last_status = now

            # Duration limit
            if self.duration_sec and (now - run_start) >= self.duration_sec:
                break

        # -- final summary ------------------------------------------------
        self._reset_interval()  # flush last partial interval into totals
        total_secs = max(1.0, time.time() - run_start)
        self._log_always("=" * 60)
        self._log_always(
            f"[DDP_BRIDGE] Summary ({total_secs:.1f}s): "
            f"in={self._tot_frames_in} out={self._tot_frames_out} "
            f"pkts={self._tot_packets} drop={self._tot_dropped} "
            f"incomplete={self._tot_incomplete}"
        )
        if self._tot_packets == 0:
            self._log_always(
                "[DDP_BRIDGE] No packets received. "
                "Check sender IP/port and firewall."
            )
        self._log_always("=" * 60)

    def stop(self):
        """Signal the bridge to exit its run loop."""
        self._running = False


# ---------------------------------------------------------------------------
# Thread helper (used by main.py to embed bridge in the API service)
# ---------------------------------------------------------------------------

def start_bridge_thread(port=4049, width=90, height=50,
                        model_name="Light_Wall", max_fps=20, verbose=False):
    """Launch the DDP bridge in a daemon thread.  Returns the bridge instance."""
    import threading

    bridge = DdpBridge(
        port=port, width=width, height=height,
        model_name=model_name, max_fps=max_fps, verbose=verbose,
    )
    t = threading.Thread(target=bridge.run, name="ddp-bridge", daemon=True)
    t.start()
    return bridge


# ---------------------------------------------------------------------------
# Standalone entry point
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    try:
        bridge = DdpBridge(
            host=args.host,
            port=args.port,
            width=args.width,
            height=args.height,
            model_name=args.model,
            max_fps=args.max_fps,
            frame_timeout_ms=args.frame_timeout_ms,
            batch_limit=args.batch_limit,
            duration_sec=args.duration_sec,
            verbose=args.verbose,
        )
        bridge.run()
    except KeyboardInterrupt:
        print("Exiting.")
        sys.exit(0)


if __name__ == "__main__":
    main()
