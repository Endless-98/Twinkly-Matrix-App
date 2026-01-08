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
    p.add_argument("--frame-timeout-ms", type=float, default=float(os.environ.get("DDP_FRAME_TIMEOUT_MS", 100.0)), help="Timeout for assembling a frame before discarding (ms)")
    p.add_argument("--batch-limit", type=int, default=int(os.environ.get("DDP_BATCH_LIMIT", 200)), help="Max packets to process per loop iteration")
    p.add_argument("--duration-sec", type=float, default=float(os.environ.get("DDP_DURATION_SEC", 10)), help="Run duration in seconds (auto-exit and print summary)")
    p.add_argument("--compact", action="store_true", help="Compact logs: print only per-second stats and final summary")
    p.add_argument("--verbose", action="store_true", help="Verbose logging")
    return p.parse_args()


class DdpBridge:
    def __init__(self, host, port, width, height, model_name, max_fps=30.0, frame_timeout_ms=50.0, batch_limit=200, duration_sec=None, compact=False, verbose=False):
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

        # Multi-sequence frame assembly
        self.frames_map = {}  # key: (sender, seq) -> FrameState
        self.completed_frames = deque(maxlen=50)  # queue of completed frames ready to write
        self.max_active_frames = 12
        self.frames_written = 0
        self.frames_dropped = 0
        self.frame_timeout_ms = float(frame_timeout_ms)
        self.batch_limit = int(batch_limit)
        self.duration_sec = float(duration_sec or 0) if duration_sec else None
        self.compact = bool(compact)
        self.last_write_ts = 0.0
        self.write_ms_acc = 0.0
        self._sec_start = time.time()
        self._sec_frames_in = 0
        self._sec_frames_out = 0
        self._sec_dropped = 0
        self._sec_incomplete = 0
        self._sec_packets = 0
        
        # Enhanced logging metrics
        self._packet_recv_time_acc = 0.0
        self._packet_parse_time_acc = 0.0
        self._frame_assembly_time_acc = 0.0
        self._pacing_sleep_time_acc = 0.0
        self._numpy_convert_time_acc = 0.0
        self._mmap_write_time_acc = 0.0
        self._total_loop_time_acc = 0.0
        self._timing_samples = 0
        self._bytes_received = 0
        self._bytes_per_sec = 0
        self._packet_sizes = deque(maxlen=100)  # Track recent packet sizes
        self._frame_chunk_counts = deque(maxlen=100)  # Track chunks per frame
        self._write_times = deque(maxlen=100)  # Track recent write times

        # Totals across the whole run for final summary
        self._tot_frames_in = 0
        self._tot_frames_out = 0
        self._tot_dropped = 0
        self._tot_incomplete = 0
        self._tot_packets = 0
        self._tot_bytes_received = 0
        self._tot_write_ms = 0.0
        self._tot_packet_recv_time = 0.0
        self._tot_packet_parse_time = 0.0
        self._tot_frame_assembly_time = 0.0
        self._tot_pacing_sleep_time = 0.0
        self._tot_numpy_convert_time = 0.0
        self._tot_mmap_write_time = 0.0
        self._tot_loop_time = 0.0

    class FrameState:
        def __init__(self, frame_size, sender, seq):
            self.buf = bytearray(frame_size)
            self.received = bytearray(frame_size)  # 0/1 per byte
            self.missing = frame_size
            self.chunks = 0
            self.sender = sender
            self.seq = seq
            self.saw_eof = False
            self.start_ts = time.time()
            self.last_update_ts = self.start_ts

        def add_chunk(self, off, payload):
            end = off + len(payload)
            # Copy payload into buffer
            mv_buf = memoryview(self.buf)
            mv_buf[off:end] = payload
            # Mark newly received bytes and update missing count
            mv_recv = memoryview(self.received)
            segment = mv_recv[off:end]
            newly_covered = len(segment) - sum(segment)  # count zeros
            segment[:] = b"\x01" * len(segment)
            self.missing -= newly_covered
            self.chunks += 1
            self.last_update_ts = time.time()

        def complete(self):
            return self.missing == 0 and self.saw_eof

    def _log(self, msg):
        if not self.verbose:
            return
        if self.compact:
            if msg.startswith("[1s STATS]") or msg.startswith("[TIMING]") or msg.startswith("[NETWORK]") or msg.startswith("=") or msg.startswith("[ERROR]") or msg.startswith("[WRITE ERROR]"):
                print(msg, flush=True)
            return
        print(msg, flush=True)

    def run(self):
        run_start = time.time()
        pacing = f"pacing at <= {self.max_fps:.1f} FPS" if self.max_fps > 0.0 else "no pacing"
        self._log(f"DDP bridge listening on {self.addr[0]}:{self.addr[1]} for {self.width}x{self.height} ({pacing})")
        self._log(f"Enhanced logging enabled - tracking packet recv, parsing, assembly, pacing, conversion, and mmap writes")
        current_sender = None
        
        while True:
            loop_start = time.perf_counter()
            
            # Batch-process all available packets
            packets_this_loop = 0
            while packets_this_loop < self.batch_limit:  # Tunable packet batch size
                try:
                    recv_start = time.perf_counter()
                    data, sender = self.sock.recvfrom(1500)
                    recv_elapsed = time.perf_counter() - recv_start
                    self._packet_recv_time_acc += recv_elapsed
                    
                    packets_this_loop += 1
                    self._sec_packets += 1
                    self._bytes_received += len(data)
                    self._packet_sizes.append(len(data))
                except BlockingIOError:
                    # No more packets available right now
                    break
                except Exception as e:
                    self._log(f"Socket error: {e}")
                    continue
                
                parse_start = time.perf_counter()
                if not data or data[0] != 0x41:
                    continue

                parse_start = time.perf_counter()
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
                
                parse_elapsed = time.perf_counter() - parse_start
                self._packet_parse_time_acc += parse_elapsed
                
                assembly_start = time.perf_counter()

                # Multi-frame assembly by (sender, seq)
                key = (sender, seq)
                if key not in self.frames_map:
                    # Limit number of active frames to avoid memory growth
                    if len(self.frames_map) >= self.max_active_frames:
                        # Drop the oldest incomplete frame
                        oldest_key = min(self.frames_map.items(), key=lambda kv: kv[1].start_ts)[0]
                        of = self.frames_map.pop(oldest_key)
                        self._log(f"[FRAME RESET] Dropped oldest incomplete frame seq={of.seq} from {of.sender}")
                        self._sec_incomplete += 1
                    self.frames_map[key] = self.FrameState(self.frame_size, sender, seq)
                    if off == 0:
                        self._log(f"[FRAME START] New frame from {sender}, seq={seq}")

                frame = self.frames_map[key]

                # Bounds check
                end = off + ln
                if end > self.frame_size:
                    self._log(f"[ERROR] Packet overflow: offset={off} len={ln} end={end} > frame_size={self.frame_size}")
                    continue

                frame.add_chunk(off, payload)
                end_of_frame = (flags & 0x01) != 0
                if end_of_frame:
                    frame.saw_eof = True
                
                assembly_elapsed = time.perf_counter() - assembly_start
                self._frame_assembly_time_acc += assembly_elapsed
                
                self._log(f"[CHUNK] off={off} len={ln} bytes_so_far={self.frame_size - frame.missing}/{self.frame_size} chunks={frame.chunks} eof={end_of_frame}")

                # If complete, enqueue for writing and remove from active map
                if frame.complete():
                    self._log(f"[FRAME COMPLETE] Ready to write: {self.frame_size} bytes in {frame.chunks} chunks")
                    self._frame_chunk_counts.append(frame.chunks)
                    self.completed_frames.append(frame)
                    self.frames_map.pop(key, None)
                    self._sec_frames_in += 1
                    sec_elapsed = time.time() - self._sec_start
                    if sec_elapsed >= 1.0:
                        avg_write_ms = (self.write_ms_acc / max(1, self._sec_frames_out))
                        
                        # Calculate detailed timing breakdown
                        avg_recv_ms = (self._packet_recv_time_acc / max(1, self._sec_packets)) * 1000.0
                        avg_parse_ms = (self._packet_parse_time_acc / max(1, self._sec_packets)) * 1000.0
                        avg_assembly_ms = (self._frame_assembly_time_acc / max(1, self._sec_packets)) * 1000.0
                        avg_pacing_ms = (self._pacing_sleep_time_acc / max(1, self._sec_frames_out)) * 1000.0
                        avg_numpy_ms = (self._numpy_convert_time_acc / max(1, self._sec_frames_out)) * 1000.0
                        avg_mmap_ms = (self._mmap_write_time_acc / max(1, self._sec_frames_out)) * 1000.0
                        avg_loop_ms = (self._total_loop_time_acc / max(1, self._timing_samples)) * 1000.0
                        
                        # Bandwidth calculation
                        bandwidth_mbps = (self._bytes_received * 8 / (1024 * 1024)) / sec_elapsed
                        self._bytes_per_sec = int(self._bytes_received / sec_elapsed)
                        
                        # Packet and chunk statistics
                        avg_packet_size = sum(self._packet_sizes) / max(1, len(self._packet_sizes))
                        avg_chunks_per_frame = sum(self._frame_chunk_counts) / max(1, len(self._frame_chunk_counts))
                        
                        # Min/max write times
                        min_write = min(self._write_times) if self._write_times else 0
                        max_write = max(self._write_times) if self._write_times else 0
                        
                        self._log(
                            f"[1s STATS] in={self._sec_frames_in} fps | out={self._sec_frames_out} fps | "
                            f"drop={self._sec_dropped} | incomplete={self._sec_incomplete} | pkts={self._sec_packets}"
                        )
                        self._log(
                            f"[TIMING] recv={avg_recv_ms:.3f}ms parse={avg_parse_ms:.3f}ms assembly={avg_assembly_ms:.3f}ms | "
                            f"pacing={avg_pacing_ms:.2f}ms numpy={avg_numpy_ms:.2f}ms mmap={avg_mmap_ms:.2f}ms | "
                            f"write_avg={avg_write_ms:.2f}ms write_min={min_write:.2f}ms write_max={max_write:.2f}ms"
                        )
                        self._log(
                            f"[NETWORK] bandwidth={bandwidth_mbps:.2f} Mbps | bytes/sec={self._bytes_per_sec:,} | "
                            f"avg_pkt_size={avg_packet_size:.1f} | avg_chunks/frame={avg_chunks_per_frame:.1f}"
                        )
                        self._log("="*100)

                        # Accumulate totals for final summary
                        self._tot_frames_in += self._sec_frames_in
                        self._tot_frames_out += self._sec_frames_out
                        self._tot_dropped += self._sec_dropped
                        self._tot_incomplete += self._sec_incomplete
                        self._tot_packets += self._sec_packets
                        self._tot_bytes_received += self._bytes_received
                        self._tot_write_ms += self.write_ms_acc
                        self._tot_packet_recv_time += self._packet_recv_time_acc
                        self._tot_packet_parse_time += self._packet_parse_time_acc
                        self._tot_frame_assembly_time += self._frame_assembly_time_acc
                        self._tot_pacing_sleep_time += self._pacing_sleep_time_acc
                        self._tot_numpy_convert_time += self._numpy_convert_time_acc
                        self._tot_mmap_write_time += self._mmap_write_time_acc
                        self._tot_loop_time += self._total_loop_time_acc
                        
                        # Reset counters
                        self._sec_start = time.time()
                        self._sec_frames_in = 0
                        self._sec_frames_out = 0
                        self._sec_dropped = 0
                        self._sec_incomplete = 0
                        self._sec_packets = 0
                        self.write_ms_acc = 0.0
                        self._packet_recv_time_acc = 0.0
                        self._packet_parse_time_acc = 0.0
                        self._frame_assembly_time_acc = 0.0
                        self._pacing_sleep_time_acc = 0.0
                        self._numpy_convert_time_acc = 0.0
                        self._mmap_write_time_acc = 0.0
                        self._total_loop_time_acc = 0.0
                        self._timing_samples = 0
                        self._bytes_received = 0
            
            # Drop timed-out incomplete frames
            now = time.time()
            to_remove = []
            for k, fr in self.frames_map.items():
                age_ms = (now - fr.start_ts) * 1000.0
                if age_ms > self.frame_timeout_ms:
                    self._log(f"[TIMEOUT] Frame timeout seq={fr.seq} after {age_ms:.1f}ms with {self.frame_size - fr.missing}/{self.frame_size} bytes, {fr.chunks} chunks")
                    to_remove.append(k)
                    self._sec_incomplete += 1
            for k in to_remove:
                self.frames_map.pop(k, None)

            # Pacing and write latest completed frame at target FPS
            pacing_start = time.perf_counter()
            wrote = False
            if self.max_fps > 0.0:
                min_interval_s = 1.0 / self.max_fps
                now_perf = self._clock()
                if self.last_write_ts == 0.0:
                    self.last_write_ts = now_perf - min_interval_s
                since_last_s = now_perf - self.last_write_ts
                if since_last_s < min_interval_s:
                    remaining_s = min_interval_s - since_last_s
                    if remaining_s > 0.0005:
                        self._log(f"[PACING] Sleeping {remaining_s*1000:.2f}ms (since_last={since_last_s*1000:.2f}ms, min_interval={min_interval_s*1000:.2f}ms)")
                        time.sleep(remaining_s)

            if self.completed_frames:
                # Prefer the latest frame to minimize latency
                latest = self.completed_frames.pop()
                # Drop older queued frames silently
                if self.completed_frames:
                    self.frames_dropped += len(self.completed_frames)
                    self._sec_dropped += len(self.completed_frames)
                    self.completed_frames.clear()

                try:
                    numpy_start = time.perf_counter()
                    if HAS_NUMPY:
                        arr = np.frombuffer(latest.buf, dtype=np.uint8).reshape(self.height, self.width, 3)
                        numpy_elapsed = time.perf_counter() - numpy_start
                        self._numpy_convert_time_acc += numpy_elapsed

                        mmap_start = time.perf_counter()
                        ms = self.out.write(arr)
                        mmap_elapsed = time.perf_counter() - mmap_start
                        self._mmap_write_time_acc += mmap_elapsed

                        self._log(f"[WRITE NUMPY] numpy_convert={numpy_elapsed*1000:.2f}ms mmap_write={mmap_elapsed*1000:.2f}ms total={ms:.2f}ms")
                    else:
                        rows = self.height
                        cols = self.width
                        view = [
                            [
                                (latest.buf[(r*cols + c)*3 + 0],
                                 latest.buf[(r*cols + c)*3 + 1],
                                 latest.buf[(r*cols + c)*3 + 2])
                                for c in range(cols)
                            ]
                            for r in range(rows)
                        ]
                        numpy_elapsed = time.perf_counter() - numpy_start
                        self._numpy_convert_time_acc += numpy_elapsed

                        mmap_start = time.perf_counter()
                        ms = self.out.write(view)
                        mmap_elapsed = time.perf_counter() - mmap_start
                        self._mmap_write_time_acc += mmap_elapsed

                        self._log(f"[WRITE FALLBACK] list_convert={numpy_elapsed*1000:.2f}ms mmap_write={mmap_elapsed*1000:.2f}ms total={ms:.2f}ms")

                    write_elapsed = (time.perf_counter() - numpy_start)
                    self.write_ms_acc += write_elapsed * 1000.0
                    self._write_times.append(write_elapsed * 1000.0)
                    self._timing_samples += 1
                    self.frames_written += 1
                    self._sec_frames_out += 1
                    self.last_write_ts = self._clock()
                    wrote = True
                except Exception as e:
                    self._log(f"[WRITE ERROR] {e}")

            pacing_elapsed = time.perf_counter() - pacing_start
            self._pacing_sleep_time_acc += pacing_elapsed

            loop_elapsed = time.perf_counter() - loop_start
            self._total_loop_time_acc += loop_elapsed
            
            # Sleep briefly when no packets to avoid CPU spinning
            if packets_this_loop == 0 and not wrote:
                time.sleep(0.0001)  # 0.1ms

            # Duration check: exit after requested seconds
            if self.duration_sec and (time.time() - run_start) >= self.duration_sec:
                break

        # Final summary
        total_secs = max(1.0, time.time() - run_start)
        avg_in_fps = self._tot_frames_in / total_secs
        avg_out_fps = self._tot_frames_out / total_secs
        avg_recv_ms = (self._tot_packet_recv_time / max(1, self._tot_packets)) * 1000.0
        avg_parse_ms = (self._tot_packet_parse_time / max(1, self._tot_packets)) * 1000.0
        avg_assembly_ms = (self._tot_frame_assembly_time / max(1, self._tot_packets)) * 1000.0
        avg_pacing_ms = (self._tot_pacing_sleep_time / max(1, self._tot_frames_out)) * 1000.0
        avg_numpy_ms = (self._tot_numpy_convert_time / max(1, self._tot_frames_out)) * 1000.0
        avg_mmap_ms = (self._tot_mmap_write_time / max(1, self._tot_frames_out)) * 1000.0
        avg_write_ms = (self._tot_write_ms / max(1, self._tot_frames_out))
        bandwidth_mbps = (self._tot_bytes_received * 8 / (1024 * 1024)) / total_secs

        print("==================== 10s SUMMARY ====================", flush=True)
        print(f"avg_in_fps={avg_in_fps:.1f} avg_out_fps={avg_out_fps:.1f} drop={self._tot_dropped} incomplete={self._tot_incomplete} packets={self._tot_packets}", flush=True)
        print(f"timing recv={avg_recv_ms:.3f}ms parse={avg_parse_ms:.3f}ms assembly={avg_assembly_ms:.3f}ms | pacing={avg_pacing_ms:.2f}ms numpy={avg_numpy_ms:.2f}ms mmap={avg_mmap_ms:.2f}ms | write_avg={avg_write_ms:.2f}ms", flush=True)
        print(f"network bandwidth={bandwidth_mbps:.2f} Mbps bytes={self._tot_bytes_received} duration={total_secs:.2f}s", flush=True)
        print("=====================================================", flush=True)


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
            compact=args.compact,
            verbose=args.verbose,
        )
        bridge.run()
    except KeyboardInterrupt:
        print("Exiting.")
        sys.exit(0)


if __name__ == "__main__":
    main()
