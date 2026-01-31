"""
DDP (Distributed Display Protocol) network output for sending frames to FPP over UDP.
Used when running the app remotely (e.g., on Windows) instead of directly on the FPP device.
"""

import socket
import struct
import time


class DDPOutput:
    """Send LED matrix frames to FPP via DDP protocol over UDP."""
    
    # DDP v1 header format:
    # Flags (1 byte) | Timecode (3 bytes) | DataLen (2 bytes BE) | OffsetX (2 bytes BE) | OffsetY (2 bytes BE) | Data
    DDP_HEADER_SIZE = 10
    DDP_FLAG_VER1 = 0x40  # Version 1
    DDP_FLAG_PUSH = 0x01  # Push frame to display
    
    def __init__(self, host, port=4048, width=90, height=50, max_packet_size=1400):
        """
        Initialize DDP output.
        
        Args:
            host: IP address of FPP device (e.g., "192.168.1.68")
            port: DDP port (default 4048 for FPP)
            width: Matrix width in pixels
            height: Matrix height in pixels
            max_packet_size: Maximum UDP packet size (default 1400 to stay under MTU)
        """
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.frame_size = width * height * 3  # RGB
        self.max_packet_size = max_packet_size
        self.max_payload = max_packet_size - self.DDP_HEADER_SIZE
        
        # Create UDP socket
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # Don't block on send
        self.sock.setblocking(False)
        
        # Statistics
        self.frames_sent = 0
        self.bytes_sent = 0
        self.errors = 0
        
        print(f"[DDP_OUTPUT] Initialized: {host}:{port} ({width}x{height})")
        print(f"[DDP_OUTPUT] Frame size: {self.frame_size} bytes")
        print(f"[DDP_OUTPUT] Max payload per packet: {self.max_payload} bytes")
        
    def write(self, dot_colors):
        """
        Write a frame to FPP via DDP.
        
        Args:
            dot_colors: height x width x 3 array of RGB values (0-255)
        
        Returns:
            Write time in milliseconds
        """
        start = time.perf_counter()
        
        try:
            # Flatten the frame data to bytes
            frame_data = self._flatten_frame(dot_colors)
            
            # Split into DDP packets if needed
            packets_sent = self._send_frame_chunked(frame_data)
            
            self.frames_sent += 1
            self.bytes_sent += len(frame_data)
            
        except Exception as e:
            self.errors += 1
            if self.errors < 10:  # Only log first few errors
                print(f"[DDP_OUTPUT] Error sending frame: {e}")
        
        return (time.perf_counter() - start) * 1000
    
    def _flatten_frame(self, dot_colors):
        """Convert dot_colors array to flat bytes."""
        try:
            # Try numpy fast path first
            import numpy as np
            if isinstance(dot_colors, np.ndarray):
                if dot_colors.dtype == np.uint8:
                    return dot_colors.tobytes()
                else:
                    return dot_colors.astype(np.uint8).tobytes()
        except (ImportError, AttributeError):
            pass
        
        # Fallback: manual flattening
        frame_bytes = bytearray(self.frame_size)
        idx = 0
        for row in dot_colors:
            for col in row:
                if isinstance(col, (list, tuple)):
                    frame_bytes[idx] = col[0]
                    frame_bytes[idx + 1] = col[1]
                    frame_bytes[idx + 2] = col[2]
                else:
                    # Assume it's a numpy array or similar
                    frame_bytes[idx] = int(col[0])
                    frame_bytes[idx + 1] = int(col[1])
                    frame_bytes[idx + 2] = int(col[2])
                idx += 3
        
        return bytes(frame_bytes)
    
    def _send_frame_chunked(self, frame_data):
        """Send frame data in one or more DDP packets."""
        total_len = len(frame_data)
        offset = 0
        seq = 0
        packets_sent = 0
        
        while offset < total_len:
            # Calculate chunk size for this packet
            remaining = total_len - offset
            chunk_size = min(remaining, self.max_payload)
            
            # Determine flags
            flags = self.DDP_FLAG_VER1
            if offset + chunk_size >= total_len:
                # Last packet in frame - set PUSH flag
                flags |= self.DDP_FLAG_PUSH
            
            # Build DDP header
            # Flags | Timecode (unused, set to 0) | DataLen (BE) | Offset (BE, pixel index * 3)
            header = struct.pack(
                '>B 3x H H H',  # Flags, 3 unused bytes, DataLen, OffsetX, OffsetY
                flags,
                chunk_size,
                offset // 3,  # Pixel offset (DDP uses pixel addressing)
                0             # OffsetY (unused for 1D strips)
            )
            
            # Send packet
            packet = header + frame_data[offset:offset + chunk_size]
            try:
                self.sock.sendto(packet, (self.host, self.port))
                packets_sent += 1
            except BlockingIOError:
                # Socket buffer full, frame dropped
                pass
            
            offset += chunk_size
            seq += 1
        
        return packets_sent
    
    def close(self):
        """Close the UDP socket."""
        if self.sock:
            self.sock.close()
            print(f"[DDP_OUTPUT] Closed. Stats: {self.frames_sent} frames, {self.bytes_sent} bytes, {self.errors} errors")
    
    def get_stats(self):
        """Get statistics."""
        return {
            'frames_sent': self.frames_sent,
            'bytes_sent': self.bytes_sent,
            'errors': self.errors,
        }
