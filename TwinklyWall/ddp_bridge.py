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

    def _log(self, msg):
        if self.verbose:
            print(msg, flush=True)

    def run(self):
        pacing = f"pacing at <= {self.max_fps:.1f} FPS" if self.max_fps > 0.0 else "no pacing"
        self._log(f"DDP bridge listening on {self.addr[0]}:{self.addr[1]} for {self.width}x{self.height} ({pacing})")
        self._log(f"Enhanced logging enabled - tracking packet recv, parsing, assembly, pacing, conversion, and mmap writes")
        current_sender = None
        
        while True:
            loop_start = time.perf_counter()
            
            # Batch-process all available packets
            packets_this_loop = 0
            while packets_this_loop < 200:  # Process up to 200 packets per batch (increased for burst handling)
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

                # If new sequence start
                if off == 0:
                    if self.bytes_written > 0:
                        # Incomplete previous frame; reset counters and unlock sender
                        self._log(f"[FRAME RESET] Incomplete frame discarded: {self.bytes_written}/{self.frame_size} bytes, {self.chunks_in_frame} chunks")
                        self.bytes_written = 0
                        current_sender = None
                    self.chunks_in_frame = 0
                    self.frame_start_ts = time.time()
                    # Lock to sender for this frame
                    current_sender = sender
                    self._log(f"[FRAME START] New frame from {sender}, seq={seq}")
                
                # Timeout check: if frame has been assembling for too long, reset it
                if self.frame_start_ts > 0:
                    frame_age_ms = (time.time() - self.frame_start_ts) * 1000.0
                    if frame_age_ms > self.frame_timeout_ms and self.bytes_written > 0:
                        self._log(f"[TIMEOUT] Frame timeout after {frame_age_ms:.1f}ms with {self.bytes_written} bytes, {self.chunks_in_frame} chunks")
                        self.bytes_written = 0
                        self.chunks_in_frame = 0
                        current_sender = None
                        self._sec_incomplete += 1

                # Ignore packets from other senders mid-frame
                if current_sender is not None and sender != current_sender:
                    self._log(f"[REJECT] Packet from {sender} rejected (locked to {current_sender})")
                    continue

                end_of_frame = (flags & 0x01) != 0

                # Bounds check
                end = off + ln
                if end > self.frame_size:
                    self._log(f"[ERROR] Packet overflow: offset={off} len={ln} end={end} > frame_size={self.frame_size}")
                    continue

                self.buf[off:end] = payload
                self.bytes_written = max(self.bytes_written, end)
                self.chunks_in_frame += 1
                
                assembly_elapsed = time.perf_counter() - assembly_start
                self._frame_assembly_time_acc += assembly_elapsed
                
                self._log(f"[CHUNK] off={off} len={ln} bytes_so_far={self.bytes_written}/{self.frame_size} chunks={self.chunks_in_frame} eof={end_of_frame}")

                if end_of_frame:
                    # Check if frame is complete
                    is_complete = self.bytes_written >= self.frame_size
                    if not is_complete:
                        self._sec_incomplete += 1
                        self._log(f"[INCOMPLETE] Frame incomplete: {self.bytes_written}/{self.frame_size} bytes, {self.chunks_in_frame} chunks")
                        self.bytes_written = 0
                        self.chunks_in_frame = 0
                        continue
                    
                    self._log(f"[FRAME COMPLETE] Ready to write: {self.bytes_written} bytes in {self.chunks_in_frame} chunks")
                    self._frame_chunk_counts.append(self.chunks_in_frame)
                        
                    # Optional pacing to avoid overrunning FPP; sleep instead of dropping frames
                    pacing_start = time.perf_counter()
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
                                self._log(f"[PACING] Sleeping {remaining_s*1000:.2f}ms (since_last={since_last_s*1000:.2f}ms, min_interval={min_interval_s*1000:.2f}ms)")
                                time.sleep(remaining_s)
                    pacing_elapsed = time.perf_counter() - pacing_start
                    self._pacing_sleep_time_acc += pacing_elapsed

                    # Write to overlay using numpy fast path when available
                    try:
                        numpy_start = time.perf_counter()
                        if HAS_NUMPY:
                            arr = np.frombuffer(self.buf, dtype=np.uint8).reshape(self.height, self.width, 3)
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
                                    (self.buf[(r*cols + c)*3 + 0],
                                     self.buf[(r*cols + c)*3 + 1],
                                     self.buf[(r*cols + c)*3 + 2])
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
                        # Update last write using perf clock for accuracy
                        self.last_write_ts = self._clock()
                    except Exception as e:
                        self._log(f"[WRITE ERROR] {e}")
                    finally:
                        self.bytes_written = 0
                        current_sender = None

                    # Per-second logging
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
            
            loop_elapsed = time.perf_counter() - loop_start
            self._total_loop_time_acc += loop_elapsed
            
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
