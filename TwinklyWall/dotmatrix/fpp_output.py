"""FPP (Falcon Player Protocol) output handling with numpy-optimized path."""

import mmap
import os
import time
import urllib.request
import json

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
            print(f"[FPP_INIT] ========================================", flush=True)
            print(f"[FPP_INIT] Initializing memory map for: {fpp_file}", flush=True)
            print(f"[FPP_INIT] Buffer size: {self.buffer_size} bytes ({self.width}x{self.height}x3)", flush=True)
            
            if not os.path.exists(fpp_file):
                print(f"[FPP_INIT] WARNING: mmap file does not exist, creating it", flush=True)
                print(f"[FPP_INIT] NOTE: FPP Pixel Overlay may need to be configured!", flush=True)
                with open(fpp_file, 'wb') as f:
                    f.write(b'\x00' * self.buffer_size)
            elif os.path.getsize(fpp_file) != self.buffer_size:
                print(f"[FPP_INIT] WARNING: mmap file size mismatch, resizing", flush=True)
                with open(fpp_file, 'wb') as f:
                    f.write(b'\x00' * self.buffer_size)
            else:
                print(f"[FPP_INIT] mmap file exists with correct size", flush=True)

            self.file_handle = open(fpp_file, 'r+b')
            self.memory_map = mmap.mmap(self.file_handle.fileno(), self.buffer_size)
            print(f"[FPP_INIT] Memory map created successfully", flush=True)
            print(f"[FPP_INIT] ========================================", flush=True)
            # Enable overlay to always transmit (state 3)
            self._enable_overlay_state()
        except PermissionError:
            print(f"FPP Error: Permission denied accessing {fpp_file}")
            print(f"Fix: sudo chmod 666 {fpp_file}")
            self._cleanup()
        except Exception as e:
            print(f"FPP Error: {e}")
            self._cleanup()

    def _enable_overlay_state(self, model_name="Light_Wall", state=3):
        """Enable the Pixel Overlay Model to always transmit (state 3).
        
        State values:
        - 0 = Disabled
        - 1 = Enabled (transparent)
        - 2 = Enabled (transparent RGB)
        - 3 = Enabled (always on - sends buffer data to outputs)
        
        Retries up to 3 times with readback verification.
        """
        url_set = f"http://localhost/api/overlays/model/{model_name}/state"
        url_get = f"http://localhost/api/overlays/model/{model_name}"
        max_attempts = 3

        for attempt in range(1, max_attempts + 1):
            try:
                data = json.dumps({"State": state}).encode('utf-8')
                req = urllib.request.Request(url_set, data=data, method='PUT')
                req.add_header('Content-Type', 'application/json')
                with urllib.request.urlopen(req, timeout=5) as resp:
                    resp.read()
            except Exception as e:
                print(f"[FPP_OVERLAY] attempt {attempt}/{max_attempts}: PUT failed: {e}", flush=True)
                if attempt < max_attempts:
                    import time as _t; _t.sleep(1)
                continue

            # Readback verification
            try:
                with urllib.request.urlopen(url_get, timeout=5) as resp:
                    body = json.loads(resp.read().decode('utf-8'))
                    current = body.get("State", body.get("state", None))
                    if current == state:
                        print(f"[FPP_OVERLAY] SUCCESS: Overlay '{model_name}' confirmed state {state}", flush=True)
                        return True
                    else:
                        print(f"[FPP_OVERLAY] attempt {attempt}/{max_attempts}: readback state={current}, expected {state}", flush=True)
            except Exception as e:
                print(f"[FPP_OVERLAY] attempt {attempt}/{max_attempts}: readback failed: {e}", flush=True)

            if attempt < max_attempts:
                import time as _t; _t.sleep(1)

        print(f"[FPP_OVERLAY] WARNING: Could not confirm overlay state {state} after {max_attempts} attempts", flush=True)
        print(f"[FPP_OVERLAY] Overlay may need manual activation via FPP UI", flush=True)
        return False

    def _build_routing_table(self):
        """Pre-compute routing from visual grid to FPP buffer positions.
        
        Maps visual canvas (50×90) to physical LED wall (99×90 with staggering).
        
        Stagger pattern (hexagonal):
        - Even columns (0,2,4...): physical_row = visual_row * 2
        - Odd columns (1,3,5...): physical_row = visual_row * 2 + 1
        
        This creates the staggered visual layout where odd columns are offset by 0.5 units.
        With 50 visual rows, this produces rows 0-98 (99 total) in the physical layout.
        The last visual row (49) for odd columns (row 99) wraps to row 97 to fit within bounds.
        """
        if not self.mapping:
            return

        dest_indices = []
        src_indices = []
        for visual_row in range(self.height):
            for visual_col in range(self.width):
                # Determine physical row based on column stagger
                if visual_col % 2 == 0:
                    # Even column (0, 2, 4...): maps to even physical rows
                    physical_row = visual_row * 2
                else:
                    # Odd column (1, 3, 5...): maps to odd physical rows (staggered)
                    physical_row = visual_row * 2 + 1
                
                # Clamp to valid range: last visual row for odd cols (row 99) → row 97
                if physical_row > 98:
                    physical_row = 97  # Last odd row
                
                physical_col = visual_col
                
                if (physical_row, physical_col) in self.mapping:
                    pixel_idx = self.mapping[(physical_row, physical_col)]
                    if 0 <= pixel_idx < 4500:
                        dest_indices.append(pixel_idx)
                        src_indices.append(visual_row * self.width + visual_col)
                        self.routing_table[(visual_row, visual_col)] = [pixel_idx * 3]

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
            import sys
            print(f"[FPP_WRITE] ERROR: No memory map, cannot write to FPP buffer", flush=True, file=sys.stderr)
            return 0.0

        start = time.perf_counter()
        
        # Track timing for different stages
        select_start = time.perf_counter()

        if HAS_NUMPY and isinstance(dot_colors, np.ndarray) and self._fast_dest is not None:
            colors_flat = dot_colors.reshape(-1, 3)
            selected = colors_flat[self._fast_src]
            select_elapsed = time.perf_counter() - select_start
            
            correct_start = time.perf_counter()
            corrected = self._apply_correction_numpy(selected)
            correct_elapsed = time.perf_counter() - correct_start
            
            assign_start = time.perf_counter()
            self._buffer_view[self._fast_dest] = corrected
            assign_elapsed = time.perf_counter() - assign_start
            
            # Optional: verbose logging for each write (disabled by default to reduce overhead)
            # print(f"[FPP_WRITE] select={select_elapsed*1000:.3f}ms correct={correct_elapsed*1000:.3f}ms assign={assign_elapsed*1000:.3f}ms", flush=True)
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

        flush_start = time.perf_counter()
        self.memory_map.seek(0)
        self.memory_map.write(self.buffer)
        self.memory_map.flush()  # Force sync to shared memory
        flush_elapsed = time.perf_counter() - flush_start
        
        total_elapsed = time.perf_counter() - start
        
        # Debug: Log write activity periodically
        if not hasattr(self, '_write_count'):
            self._write_count = 0
        self._write_count += 1
        if self._write_count <= 5 or self._write_count % 100 == 0:
            # Sample some pixel values to verify data is being written
            sample = bytes(self.buffer[:12])  # First 4 pixels (12 bytes)
            print(f"[FPP_WRITE] Frame #{self._write_count}: wrote {len(self.buffer)} bytes, first 12: {sample.hex()}", flush=True)
        
        return total_elapsed * 1000

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
