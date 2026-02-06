"""DDP (Distributed Display Protocol) network output for sending frames to FPP over UDP.

Used when running the app remotely (e.g., on Windows) instead of directly
on the FPP device.
"""

import socket
import time

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


class DDPOutput:
    """Send LED matrix frames to FPP via DDP protocol over UDP.

    DDP v1 header (10 bytes, big-endian):
        [0]   0x41 ('A' magic)
        [1]   flags  (bit 6 = v1, bit 0 = push/end-of-frame)
        [2]   sequence number (0-255, constant per frame)
        [3-5] 24-bit data offset in bytes
        [6-7] 16-bit data length
        [8-9] 16-bit data ID (0 = default)
    """

    _DDP_MAGIC = 0x41
    _FLAG_VER1 = 0x40
    _FLAG_PUSH = 0x01
    _HEADER_SIZE = 10
    _MAX_CHUNK = 1400 - 10  # keep total UDP packet under typical MTU

    def __init__(self, host, port=4048, width=90, height=50):
        """
        Args:
            host: IP address of FPP device (e.g., "192.168.1.68")
            port: DDP port (default 4048 for FPP)
            width: Matrix width in pixels
            height: Matrix height in pixels
        """
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.frame_size = width * height * 3  # RGB
        self._seq = 0

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)

        # Statistics
        self.frames_sent = 0
        self.bytes_sent = 0
        self.errors = 0

        print(f"[DDP_OUTPUT] Initialized: {host}:{port} "
              f"({width}x{height}, {self.frame_size} bytes/frame)")

    # -- public API ---------------------------------------------------------

    def write(self, dot_colors):
        """Write a frame to FPP via DDP.

        Args:
            dot_colors: height x width x 3 array of RGB values (0-255).

        Returns:
            Write time in milliseconds.
        """
        start = time.perf_counter()
        try:
            frame_data = self._flatten(dot_colors)
            self._send_chunked(frame_data)
            self.frames_sent += 1
            self.bytes_sent += len(frame_data)
        except Exception as e:
            self.errors += 1
            if self.errors <= 10:
                print(f"[DDP_OUTPUT] Send error: {e}")
        return (time.perf_counter() - start) * 1000

    def close(self):
        """Close the UDP socket."""
        if self.sock:
            self.sock.close()
            self.sock = None
            print(f"[DDP_OUTPUT] Closed. "
                  f"{self.frames_sent} frames, {self.errors} errors")

    def get_stats(self):
        return {
            "frames_sent": self.frames_sent,
            "bytes_sent": self.bytes_sent,
            "errors": self.errors,
        }

    # -- internals ----------------------------------------------------------

    @staticmethod
    def _flatten(dot_colors):
        """Convert an H x W x 3 color array to flat RGB bytes."""
        if HAS_NUMPY and isinstance(dot_colors, np.ndarray):
            arr = (dot_colors if dot_colors.dtype == np.uint8
                   else dot_colors.astype(np.uint8))
            return arr.tobytes()

        # Fallback for plain lists / tuples
        out = bytearray()
        for row in dot_colors:
            for pixel in row:
                out.append(int(pixel[0]))
                out.append(int(pixel[1]))
                out.append(int(pixel[2]))
        return bytes(out)

    def _send_chunked(self, data):
        """Split *data* into DDP v1 packets and send over UDP."""
        offset = 0
        total = len(data)
        seq = self._seq

        while offset < total:
            chunk_len = min(total - offset, self._MAX_CHUNK)
            is_last = (offset + chunk_len >= total)

            flags = self._FLAG_VER1 | (self._FLAG_PUSH if is_last else 0)

            header = bytearray(self._HEADER_SIZE)
            header[0] = self._DDP_MAGIC
            header[1] = flags
            header[2] = seq & 0xFF
            header[3] = (offset >> 16) & 0xFF
            header[4] = (offset >> 8) & 0xFF
            header[5] = offset & 0xFF
            header[6] = (chunk_len >> 8) & 0xFF
            header[7] = chunk_len & 0xFF
            # header[8:10] remain 0 (default data ID)

            try:
                self.sock.sendto(
                    bytes(header) + data[offset:offset + chunk_len],
                    (self.host, self.port),
                )
            except BlockingIOError:
                pass  # socket buffer full — drop this chunk

            offset += chunk_len

        self._seq = (self._seq + 1) & 0xFF
