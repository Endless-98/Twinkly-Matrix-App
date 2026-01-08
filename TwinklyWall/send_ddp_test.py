#!/usr/bin/env python3
import argparse
import os
import socket
import time
import struct
import random

try:
    import numpy as np
    HAS_NUMPY = True
except Exception:
    HAS_NUMPY = False


def make_frame(width, height, seq):
    size = width * height * 3
    buf = bytearray(size)
    # Simple moving gradient based on seq
    for i in range(0, size, 3):
        x = (i // 3) % width
        y = (i // 3) // width
        r = (x * 5 + seq * 3) % 256
        g = (y * 5 + seq * 5) % 256
        b = (x + y + seq * 7) % 256
        buf[i] = r
        buf[i+1] = g
        buf[i+2] = b
    return buf


def parse_args():
    p = argparse.ArgumentParser(description="Send synthetic DDP v1 frames for testing")
    p.add_argument("--dest", default=os.environ.get("DDP_DEST", "127.0.0.1"), help="Destination IP")
    p.add_argument("--port", type=int, default=int(os.environ.get("DDP_PORT", 4049)), help="Destination UDP port")
    p.add_argument("--width", type=int, default=int(os.environ.get("DDP_WIDTH", 90)), help="Matrix width")
    p.add_argument("--height", type=int, default=int(os.environ.get("DDP_HEIGHT", 50)), help="Matrix height")
    p.add_argument("--fps", type=float, default=float(os.environ.get("DDP_FPS", 20)), help="Send FPS")
    p.add_argument("--duration", type=float, default=float(os.environ.get("DDP_SEND_DURATION", 10)), help="Send duration seconds")
    p.add_argument("--chunk", type=int, default=int(os.environ.get("DDP_CHUNK", 1050)), help="Payload bytes per packet (<= 1460 recommended)")
    return p.parse_args()


def send_frame(sock, addr, frame_buf, seq, chunk):
    size = len(frame_buf)
    off = 0
    while off < size:
        ln = min(chunk, size - off)
        end_of_frame = (off + ln) >= size
        flags = 0x01 if end_of_frame else 0x00
        # Build DDP header (10 bytes)
        hdr = bytearray(10)
        hdr[0] = 0x41  # 'A'
        hdr[1] = flags
        hdr[2] = seq & 0xFF
        hdr[3] = (off >> 16) & 0xFF
        hdr[4] = (off >> 8) & 0xFF
        hdr[5] = off & 0xFF
        hdr[6] = (ln >> 8) & 0xFF
        hdr[7] = ln & 0xFF
        hdr[8] = 0
        hdr[9] = 0
        payload = memoryview(frame_buf)[off:off+ln]
        sock.sendto(hdr + payload.tobytes(), addr)
        off += ln


def main():
    args = parse_args()
    addr = (args.dest, args.port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)  # 1MB

    print(f"Sending DDP to {addr} at {args.fps} fps for {args.duration}s ({args.width}x{args.height}, chunk={args.chunk})")

    start = time.time()
    seq = 0
    min_interval = 1.0 / max(1e-6, args.fps)
    next_ts = time.perf_counter()

    while (time.time() - start) < args.duration:
        frame_buf = make_frame(args.width, args.height, seq)
        send_frame(sock, addr, frame_buf, seq, args.chunk)
        seq = (seq + 1) & 0xFF
        # Pace
        next_ts += min_interval
        now = time.perf_counter()
        sleep_s = next_ts - now
        if sleep_s > 0:
            time.sleep(sleep_s)
        else:
            next_ts = now

    print("Done.")


if __name__ == "__main__":
    main()
