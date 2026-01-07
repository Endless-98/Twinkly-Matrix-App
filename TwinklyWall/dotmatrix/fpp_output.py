"""FPP (Falcon Player Protocol) output handling with numpy-optimized path."""

import mmap
import os
import time

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

from .light_wall_mapping import load_light_wall_mapping


class FPPOutput:
    """Handles FPP memory-mapped output with optional numpy fast path."""

    def __init__(self, width, height, mapping_file="/dev/shm/FPP-Model-Data-Light_Wall", color_order="RGB", gamma=None, channel_gains=(1.0, 1.0, 1.0)):
        self.width = width
        self.height = height
        self.buffer_size = width * height * 3
        self.buffer = bytearray(self.buffer_size)
        self.memory_map = None
        self.file_handle = None
        self.routing_table = {}
        self._fast_dest = None  # numpy-optimized destination indices
        self._fast_src = None   # numpy-optimized source indices (flattened)
        self._buffer_view = None  # numpy view over self.buffer for vectorized writes
        # Output color correction and channel order
        self.color_order = (color_order or "RGB").upper()
        self.gamma = float(gamma) if (gamma is not None) else None
        self.channel_gains = channel_gains if channel_gains else (1.0, 1.0, 1.0)
        # Precompute channel order indices
        self._channel_idx = self._make_channel_indices(self.color_order)

        # Load mapping and initialize
        self.mapping = load_light_wall_mapping()
        self._initialize_memory_map(mapping_file)
        self._build_routing_table()

    def _make_channel_indices(self, order):
        lookup = {
            'RGB': (0, 1, 2),
            'RBG': (0, 2, 1),
            'GRB': (1, 0, 2),
            'GBR': (1, 2, 0),
            'BRG': (2, 0, 1),
            'BGR': (2, 1, 0),
        }
        return lookup.get(order, (0, 1, 2))

    def _apply_correction_numpy(self, arr_uint8):
        # arr_uint8: N x 3 uint8
        if self.gamma is None and self.channel_gains == (1.0, 1.0, 1.0) and self._channel_idx == (0, 1, 2):
            return arr_uint8
        arr = arr_uint8.astype(np.float32, copy=False)
        if self.channel_gains != (1.0, 1.0, 1.0):
            gains = np.array(self.channel_gains, dtype=np.float32)
            arr = arr * gains
        if self.gamma is not None and abs(self.gamma - 1.0) > 1e-3:
            arr = np.power(np.clip(arr, 0, 255) / 255.0, self.gamma) * 255.0
        arr = np.clip(arr, 0, 255)
        arr = arr.astype(np.uint8)
        i0, i1, i2 = self._channel_idx
        if (i0, i1, i2) != (0, 1, 2):
            arr = arr[:, [i0, i1, i2]]
        return arr

    def _apply_correction_tuple(self, r, g, b):
        # Lightweight path for non-numpy writers
        if self._channel_idx != (0,1,2):
            order = [r, g, b]
            r, g, b = order[self._channel_idx[0]], order[self._channel_idx[1]], order[self._channel_idx[2]]
        if self.channel_gains != (1.0, 1.0, 1.0) or (self.gamma is not None and abs(self.gamma - 1.0) > 1e-3):
            rf = r * self.channel_gains[0]
            gf = g * self.channel_gains[1]
            bf = b * self.channel_gains[2]
            if self.gamma is not None and abs(self.gamma - 1.0) > 1e-3:
                rf = (max(0.0, min(255.0, rf)) / 255.0) ** self.gamma * 255.0
                gf = (max(0.0, min(255.0, gf)) / 255.0) ** self.gamma * 255.0
                bf = (max(0.0, min(255.0, bf)) / 255.0) ** self.gamma * 255.0
            r, g, b = int(max(0, min(255, round(rf)))), int(max(0, min(255, round(gf)))), int(max(0, min(255, round(bf))))
        return r, g, b

    def _initialize_memory_map(self, fpp_file):
        """Initialize memory-mapped file for FPP output."""
        try:
            if not os.path.exists(fpp_file) or os.path.getsize(fpp_file) != self.buffer_size:
                with open(fpp_file, 'wb') as f:
                    f.write(b'\x00' * self.buffer_size)

            self.file_handle = open(fpp_file, 'r+b')
            self.memory_map = mmap.mmap(self.file_handle.fileno(), self.buffer_size)
        except PermissionError:
            print(f"FPP Error: Permission denied accessing {fpp_file}")
            print(f"Fix: sudo chmod 666 {fpp_file}")
            self._cleanup()
        except Exception as e:
            print(f"FPP Error: {e}")
            self._cleanup()

    def _build_routing_table(self):
        """Pre-compute routing from visual grid to FPP buffer positions."""
        if not self.mapping:
            return

        dest_indices = []
        src_indices = []
        for visual_row in range(self.height):
            for visual_col in range(self.width):
                byte_indices = []

                for row_offset in range(2):  # Each visual cell maps to 2 physical LED rows
                    physical_row = visual_row * 2 + row_offset
                    physical_col = visual_col

                    if (physical_row, physical_col) in self.mapping:
                        pixel_idx = self.mapping[(physical_row, physical_col)]
                        if 0 <= pixel_idx < 4500:
                            byte_indices.append(pixel_idx * 3)
                            dest_indices.append(pixel_idx)
                            src_indices.append(visual_row * self.width + visual_col)

                if byte_indices:
                    self.routing_table[(visual_row, visual_col)] = byte_indices

        if HAS_NUMPY and dest_indices:
            self._fast_dest = np.array(dest_indices, dtype=np.int32)
            self._fast_src = np.array(src_indices, dtype=np.int32)
            self._buffer_view = np.frombuffer(self.buffer, dtype=np.uint8).reshape(-1, 3)
            try:
                print(f"FPPOutput mapping entries: {len(self._fast_dest)}")
            except Exception:
                pass
        elif HAS_NUMPY:
            # Fallback to linear mapping when CSV mapping yields no entries
            total = self.width * self.height
            self._fast_dest = np.arange(total, dtype=np.int32)
            self._fast_src = np.arange(total, dtype=np.int32)
            self._buffer_view = np.frombuffer(self.buffer, dtype=np.uint8).reshape(-1, 3)
            try:
                print("FPPOutput mapping empty; using linear fallback mapping")
            except Exception:
                pass

    def write(self, dot_colors):
        """Write color data to FPP buffer and flush to memory map."""
        if not self.memory_map:
            return 0.0

        start = time.perf_counter()

        if HAS_NUMPY and isinstance(dot_colors, np.ndarray) and self._fast_dest is not None:
            colors_flat = dot_colors.reshape(-1, 3)
            selected = colors_flat[self._fast_src]
            corrected = self._apply_correction_numpy(selected)
            self._buffer_view[self._fast_dest] = corrected
        elif HAS_NUMPY and isinstance(dot_colors, np.ndarray):
            for (row, col), byte_indices in self.routing_table.items():
                pixel = dot_colors[row, col]
                r, g, b = int(pixel[0]), int(pixel[1]), int(pixel[2])
                r, g, b = self._apply_correction_tuple(r, g, b)
                for byte_idx in byte_indices:
                    self.buffer[byte_idx] = r
                    self.buffer[byte_idx + 1] = g
                    self.buffer[byte_idx + 2] = b
        else:
            for (row, col), byte_indices in self.routing_table.items():
                r, g, b = dot_colors[row][col]
                r, g, b = self._apply_correction_tuple(r, g, b)
                for byte_idx in byte_indices:
                    self.buffer[byte_idx] = r
                    self.buffer[byte_idx + 1] = g
                    self.buffer[byte_idx + 2] = b

        self.memory_map.seek(0)
        self.memory_map.write(self.buffer)
        return (time.perf_counter() - start) * 1000

    def write_solid(self, r, g, b):
        """Write a solid color directly to the FPP buffer (bypasses mapping)."""
        if not self.memory_map:
            return 0.0
        start = time.perf_counter()
        rr, gg, bb = self._apply_correction_tuple(int(r), int(g), int(b))
        for i in range(0, self.buffer_size, 3):
            self.buffer[i] = rr
            self.buffer[i + 1] = gg
            self.buffer[i + 2] = bb
        self.memory_map.seek(0)
        self.memory_map.write(self.buffer)
        return (time.perf_counter() - start) * 1000

    def close(self):
        """Clean up resources."""
        self._cleanup()

    def _cleanup(self):
        if self.memory_map:
            self.memory_map.close()
            self.memory_map = None
        if self.file_handle:
            self.file_handle.close()
            self.file_handle = None
