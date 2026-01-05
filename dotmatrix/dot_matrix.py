"""
DotMatrix: Core rendering engine for LED matrix displays.

Converts pygame surfaces to a dot matrix representation with luminance-based blending.
Supports both visual preview (pygame window) and FPP memory-mapped output for LED hardware.
"""

import pygame
import time
import mmap
import os
try:
    import numpy as np
    import pygame.surfarray as surfarray
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

from .source_canvas import CanvasSource, SourcePreview
from .light_wall_mapping import load_light_wall_mapping


class PerformanceMonitor:
    """Tracks and reports rendering performance metrics."""
    
    def __init__(self, enabled=True):
        self.enabled = enabled
        self.frame_count = 0
        self.last_log_time = time.time()
        self.stage_timings = {
            'scaling': [],
            'sampling_blend': [],
            'visualization': [],
            'fpp_write': [],
            'total': []
        }
    
    def record(self, stage, duration_ms):
        """Record timing for a stage."""
        if self.enabled:
            self.stage_timings[stage].append(duration_ms)
    
    def frame_complete(self):
        """Mark frame as complete and log if needed."""
        if not self.enabled:
            return
            
        self.frame_count += 1
        current_time = time.time()
        elapsed = current_time - self.last_log_time
        
        if elapsed >= 1.0:
            self._log_performance(elapsed)
            self._reset()
            self.last_log_time = current_time
    
    def _log_performance(self, elapsed):
        """Print performance report."""
        if self.frame_count == 0:
            return
            
        fps = self.frame_count / elapsed
        print(f"\n{'='*60}")
        print(f"Performance Report (Last {elapsed:.2f}s)")
        print(f"Average FPS: {fps:.2f} | Frame Count: {self.frame_count}")
        print(f"\nStage Latencies (average):")
        
        for stage, times in self.stage_timings.items():
            if times:
                avg = sum(times) / len(times)
                min_t = min(times)
                max_t = max(times)
                print(f"  {stage:20s}: {avg:6.2f}ms (min: {min_t:5.2f}ms, max: {max_t:5.2f}ms)")
        
        if self.stage_timings['total']:
            avg_total = sum(self.stage_timings['total']) / len(self.stage_timings['total'])
            print(f"\nFrame budget: 25.00ms (40 FPS target)")
            print(f"Headroom: {25.0 - avg_total:6.2f}ms")
        print(f"{'='*60}\n")
    
    def _reset(self):
        """Reset counters for next period."""
        self.frame_count = 0
        for stage in self.stage_timings:
            self.stage_timings[stage].clear()


class FPPOutput:
    """Handles FPP (Falcon Player Protocol) memory-mapped output."""
    
    def __init__(self, width, height, mapping_file="/dev/shm/FPP-Model-Data-Light_Wall"):
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
        
        # Load mapping and initialize
        self.mapping = load_light_wall_mapping()
        self._initialize_memory_map(mapping_file)
        self._build_routing_table()
    
    def _initialize_memory_map(self, fpp_file):
        """Initialize memory-mapped file for FPP output."""
        try:
            # Create or resize file if needed
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
            
        # Keep legacy dict for fallback path
        dest_indices = []
        src_indices = []
        for visual_row in range(self.height):
            for visual_col in range(self.width):
                byte_indices = []
                
                # Each visual cell maps to 2 physical LED rows
                for row_offset in range(2):
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

        # Build fast numpy paths if numpy is available
        if HAS_NUMPY and dest_indices:
            self._fast_dest = np.array(dest_indices, dtype=np.int32)
            self._fast_src = np.array(src_indices, dtype=np.int32)
            # View over buffer as (pixels,3)
            self._buffer_view = np.frombuffer(self.buffer, dtype=np.uint8).reshape(-1, 3)
    
    def write(self, dot_colors):
        """Write color data to FPP buffer and flush to memory map.
        
        This is optimized for numpy array input (no tuple conversion needed).
        For legacy tuple input, falls back to slower method.
        """
        if not self.memory_map:
            return 0.0
        
        start = time.perf_counter()
        
        # Fast path: numpy arrays with precomputed indices (fully vectorized)
        if isinstance(dot_colors, np.ndarray) and self._fast_dest is not None:
            colors_flat = dot_colors.reshape(-1, 3)
            # Vectorized scatter into buffer view
            self._buffer_view[self._fast_dest] = colors_flat[self._fast_src]
        elif isinstance(dot_colors, np.ndarray):
            # Fallback numpy path using routing table
            for (row, col), byte_indices in self.routing_table.items():
                pixel = dot_colors[row, col]
                r, g, b = int(pixel[0]), int(pixel[1]), int(pixel[2])
                for byte_idx in byte_indices:
                    self.buffer[byte_idx] = r
                    self.buffer[byte_idx + 1] = g
                    self.buffer[byte_idx + 2] = b
        else:
            # Slow path: legacy tuple format
            for (row, col), byte_indices in self.routing_table.items():
                r, g, b = dot_colors[row][col]
                for byte_idx in byte_indices:
                    self.buffer[byte_idx] = r
                    self.buffer[byte_idx + 1] = g
                    self.buffer[byte_idx + 2] = b
        
        # Single write operation
        self.memory_map.seek(0)
        self.memory_map.write(self.buffer)
        
        return (time.perf_counter() - start) * 1000
    
    def close(self):
        """Clean up resources."""
        self._cleanup()
    
    def _cleanup(self):
        """Internal cleanup."""
        if self.memory_map:
            self.memory_map.close()
            self.memory_map = None
        if self.file_handle:
            self.file_handle.close()
            self.file_handle = None


class DotMatrix:
    """
    LED dot matrix renderer with luminance-based blending.
    
    Converts pygame surfaces to a grid of colored dots, with optional
    visualization window and FPP hardware output.
    """
    
    def __init__(
        self,
        width=90,
        height=50,
        dot_size=6,
        spacing=15,
        should_stagger=True,
        blend_power=0.2,
        supersample=3,
        headless=False,
        show_source_preview=False,
        fpp_output=False,
        fpp_memory_buffer_file="/dev/shm/FPP-Model-Data-Light_Wall",
        enable_performance_monitor=True,
        max_fps=40
    ):
        """
        Initialize DotMatrix renderer.
        
        Args:
            width, height: Matrix dimensions in dots
            dot_size: Radius of each dot in pygame visualization
            spacing: Pixels between dots in visualization
            should_stagger: Offset alternating columns (hexagonal pattern)
            blend_power: Exponent for luminance blending (0.0-1.0)
            supersample: Antialiasing factor for source scaling
            headless: Skip pygame window creation
            show_source_preview: Show separate preview window of source
            fpp_output: Enable FPP memory-mapped output
            fpp_memory_buffer_file: Path to FPP memory buffer
            enable_performance_monitor: Track and log performance
        """
        self.width = width
        self.height = height
        self.dot_size = dot_size
        self.spacing = spacing
        self.should_stagger = should_stagger
        self.blend_power = max(0.001, blend_power)
        self.supersample = max(1, int(supersample))
        self.headless = headless
        self.max_fps = max_fps if max_fps and max_fps > 0 else None
        
        # Visual appearance
        self.bg_color = (0, 0, 0)
        self.off_color = (10, 10, 10)
        
        # Current frame state
        self.dot_colors = [[self.off_color for _ in range(width)] for _ in range(height)]
        
        # Pre-allocate tuple cache for faster updates (huge speedup!)
        if HAS_NUMPY:
            # Create a list of pre-allocated tuples to reuse
            self._color_tuples = {}  # Cache for (r,g,b) -> (r,g,b) to avoid recreation
        
        # Optional components
        self.monitor = PerformanceMonitor(enabled=enable_performance_monitor)
        self.fpp = FPPOutput(width, height, fpp_memory_buffer_file) if fpp_output else None
        self.preview = SourcePreview(width, height, enabled=show_source_preview)
        
        # Cache for numpy optimization
        if HAS_NUMPY:
            self._off_color_cache = np.array(self.off_color, dtype=np.uint32)
            self._use_power = abs(self.blend_power - 1.0) > 0.01  # Skip power if ~1.0
        
        # Pygame setup
        self.screen = None
        self.clock = None
        if not headless:
            pygame.init()
            window_width = width * (dot_size + spacing) + spacing
            window_height = height * (dot_size + spacing) + spacing
            self.screen = pygame.display.set_mode((window_width, window_height))
            pygame.display.set_caption("Dot Matrix Display")
            self.clock = pygame.time.Clock()
    
    def render_frame(self, source_surface):
        """
        Main rendering pipeline: converts source surface to dot matrix.
        
        Args:
            source_surface: pygame.Surface or CanvasSource to render
        
        Returns:
            Total frame time in milliseconds
        """
        frame_start = time.perf_counter()
        
        # Extract pygame surface
        t1 = time.perf_counter()
        if isinstance(source_surface, CanvasSource):
            source_surface = source_surface.surface
        
        # Update preview if enabled
        if self.preview:
            self.preview.update(source_surface)
        preview_time = (time.perf_counter() - t1) * 1000
        
        # Scale to target resolution
        t2 = time.perf_counter()
        scaled = self._scale_surface(source_surface)
        self.monitor.record('scaling', (time.perf_counter() - t2) * 1000)
        
        # Sample and blend colors
        t3 = time.perf_counter()
        self._sample_and_blend(scaled)
        self.monitor.record('sampling_blend', (time.perf_counter() - t3) * 1000)
        
        # Visualize if not headless
        t4 = time.perf_counter()
        self._visualize()
        self.monitor.record('visualization', (time.perf_counter() - t4) * 1000)
        
        # Write to FPP if enabled
        t5 = time.perf_counter()
        if self.fpp:
            # Pass numpy array directly - no conversion needed!
            fpp_time = self.fpp.write(self.dot_colors)
            self.monitor.record('fpp_write', fpp_time)
        
        # Complete frame
        total_time = (time.perf_counter() - frame_start) * 1000
        self.monitor.record('total', total_time)
        self.monitor.frame_complete()

        # Frame cap: use pygame clock when available; otherwise sleep
        if self.max_fps:
            if self.clock:
                self.clock.tick(self.max_fps)
            else:
                # Headless: simple sleep based on target frame time
                target_ms = 1000.0 / self.max_fps
                remaining_ms = target_ms - total_time
                if remaining_ms > 0:
                    time.sleep(remaining_ms / 1000.0)
        
        return total_time
    
    def _scale_surface(self, source):
        """Scale source surface to matrix dimensions with supersampling."""
        target_size = (self.width, self.height)
        current_size = source.get_size()
        
        # Skip scaling if already at target size
        if current_size == target_size:
            return source
        
        # Apply supersampling if configured
        if self.supersample > 1:
            upsampled_size = (self.width * self.supersample, self.height * self.supersample)
            if current_size != upsampled_size:
                source = pygame.transform.smoothscale(source, upsampled_size)
            return pygame.transform.smoothscale(source, target_size)
        
        return pygame.transform.smoothscale(source, target_size)
    
    def _sample_and_blend(self, surface):
        """Sample colors from surface and blend with luminance."""
        if HAS_NUMPY:
            self._sample_blend_numpy(surface)
        else:
            self._sample_blend_fallback(surface)
    
    def _sample_blend_numpy(self, surface):
        """Optimized numpy implementation - heavily optimized for Pi performance."""
        import sys
        debug = False  # Set to True to enable detailed logging
        
        # Get direct view (no copy) - shape is (width, height, 3)
        t0 = time.perf_counter() if debug else 0
        pixel_view = surfarray.pixels3d(surface)
        if debug: print(f"  pixels3d: {(time.perf_counter()-t0)*1000:.2f}ms")
        
        # Transpose directly to (height, width, 3) - stay in uint8
        t0 = time.perf_counter() if debug else 0
        rgb = np.transpose(pixel_view, (1, 0, 2))
        if debug: print(f"  transpose: {(time.perf_counter()-t0)*1000:.2f}ms")
        
        # Luminance calculation - fast integer version
        # 213r + 715g + 72b, normalize by 1000
        t0 = time.perf_counter() if debug else 0
        r = rgb[:, :, 0].astype(np.uint16)
        g = rgb[:, :, 1].astype(np.uint16)
        b = rgb[:, :, 2].astype(np.uint16)
        luminance = ((r * 213 + g * 715 + b * 72) // 1000).astype(np.uint8)
        if debug: print(f"  luminance: {(time.perf_counter()-t0)*1000:.2f}ms")
        
        # Find max and normalize
        t0 = time.perf_counter() if debug else 0
        max_lum = int(np.max(luminance))
        max_lum = max(1, max_lum)
        normalized = (luminance.astype(np.float32) * 255.0 / max_lum).astype(np.uint8)
        if debug: print(f"  normalize: {(time.perf_counter()-t0)*1000:.2f}ms")
        
        # Apply blend power only if needed
        t0 = time.perf_counter() if debug else 0
        if self._use_power:
            blend_f = np.power(normalized.astype(np.float32) / 255.0, self.blend_power)
            blend_factors = (blend_f * 255.0).astype(np.uint8)
            if debug: print(f"  power: {(time.perf_counter()-t0)*1000:.2f}ms")
        else:
            blend_factors = normalized
            if debug: print(f"  power: skipped")
        
        # Blend: very tight loop optimized
        t0 = time.perf_counter() if debug else 0
        inv_blend = 255 - blend_factors
        
        # Use einsum for ultra-fast broadcasting if possible
        try:
            t_einsum = time.perf_counter() if debug else 0
            result = np.einsum(
                'ijk,ij->ijk',
                rgb.astype(np.uint32),
                blend_factors.astype(np.uint32)
            ) + np.einsum(
                'k,ij->ijk',
                self._off_color_cache.astype(np.uint32),
                inv_blend.astype(np.uint32)
            )
            blended = (result // 255).astype(np.uint8)
            if debug: print(f"  einsum blend: {(time.perf_counter()-t_einsum)*1000:.2f}ms")
            if debug: print(f"  blend total: {(time.perf_counter()-t0)*1000:.2f}ms (einsum)")
        except Exception as e:
            if debug: print(f"  einsum failed ({e}), using fallback")
            # Fallback if einsum not available or slower
            t_fallback = time.perf_counter() if debug else 0
            blend_3d = blend_factors[:, :, np.newaxis].astype(np.uint32)
            inv_blend_3d = inv_blend[:, :, np.newaxis].astype(np.uint32)
            blended = (
                (rgb.astype(np.uint32) * blend_3d) +
                (self._off_color_cache.astype(np.uint32) * inv_blend_3d)
            ) // 255
            blended = blended.astype(np.uint8)
            if debug: print(f"  fallback blend: {(time.perf_counter()-t_fallback)*1000:.2f}ms")
            if debug: print(f"  blend total: {(time.perf_counter()-t0)*1000:.2f}ms (fallback)")
        
        # Convert to tuples - CRITICAL BOTTLENECK - use fastest method
        t0 = time.perf_counter() if debug else 0
        h, w = self.height, self.width
        
        # OPTIMIZATION: Store raw numpy array instead of tuples!
        # Convert only when needed (FPP write, visualization)
        # This eliminates the 15ms tuple conversion overhead
        self.dot_colors = blended  # Keep as uint8 numpy array
        
        if debug: print(f"  tuple conversion: skipped (stored as numpy array)")
        if debug: print()

    
    def _sample_blend_fallback(self, surface):
        """Fallback implementation using pygame.Surface.get_at()."""
        # First pass: sample and calculate max luminance
        samples = []
        max_lum = 0.0
        
        for row in range(self.height):
            for col in range(self.width):
                color = surface.get_at((col, row))[:3]
                lum = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
                samples.append((row, col, color, lum))
                max_lum = max(max_lum, lum)
        
        # Second pass: blend
        max_lum = max(1.0, max_lum)
        for row, col, color, lum in samples:
            blend_factor = (lum / max_lum) ** self.blend_power
            self.dot_colors[row][col] = tuple(
                int(self.off_color[i] * (1.0 - blend_factor) + color[i] * blend_factor)
                for i in range(3)
            )
    
    def _visualize(self):
        """Draw matrix to pygame window."""
        if not self.screen:
            return
        
        self.screen.fill(self.bg_color)
        stagger = (self.dot_size / 2 + self.spacing / 2) if self.should_stagger else 0
        
        # Handle both numpy arrays and legacy lists
        if isinstance(self.dot_colors, np.ndarray):
            # Fast path: numpy array access
            for row in range(self.height):
                for col in range(self.width):
                    x = self.spacing + col * (self.dot_size + self.spacing)
                    y = self.spacing + row * (self.dot_size + self.spacing) + (stagger * (col % 2))
                    # Convert only when drawing (minimal overhead)
                    color = tuple(self.dot_colors[row, col])
                    pygame.draw.circle(self.screen, color, (x, y), self.dot_size)
        else:
            # Legacy path: nested list of tuples
            for row in range(self.height):
                for col in range(self.width):
                    x = self.spacing + col * (self.dot_size + self.spacing)
                    y = self.spacing + row * (self.dot_size + self.spacing) + (stagger * (col % 2))
                    pygame.draw.circle(self.screen, self.dot_colors[row][col], (x, y), self.dot_size)
        
        pygame.display.flip()
    
    def clear(self):
        """Set all dots to off color."""
        if HAS_NUMPY:
            # Fast numpy fill
            self.dot_colors = np.full((self.height, self.width, 3), self.off_color, dtype=np.uint8)
        else:
            # Legacy format
            self.dot_colors = [[self.off_color for _ in range(self.width)] for _ in range(self.height)]
    
    def shutdown(self):
        """Clean shutdown: turn off lights and release resources."""
        self.clear()
        if self.fpp:
            self.fpp.write(self.dot_colors)
            self.fpp.close()
        if self.screen:
            pygame.quit()


# Backwards compatibility wrapper
def convert_canvas_to_matrix(matrix, canvas):
    """Legacy method for backward compatibility."""
    matrix.render_frame(canvas)
