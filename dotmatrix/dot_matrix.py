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
                
                if byte_indices:
                    self.routing_table[(visual_row, visual_col)] = byte_indices
    
    def write(self, dot_colors):
        """Write color data to FPP buffer and flush to memory map."""
        if not self.memory_map:
            return 0.0
        
        start = time.perf_counter()
        
        # Update buffer with current colors
        for (row, col), byte_indices in self.routing_table.items():
            r, g, b = dot_colors[row][col]
            for byte_idx in byte_indices:
                self.buffer[byte_idx:byte_idx+3] = bytes([r, g, b])
        
        # Flush to memory map
        self.memory_map.seek(0)
        self.memory_map.write(self.buffer)
        self.memory_map.flush()
        
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
        enable_fpp=False,
        fpp_device="/dev/shm/FPP-Model-Data-Light_Wall",
        enable_performance_monitor=True
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
            enable_fpp: Enable FPP memory-mapped output
            fpp_device: Path to FPP memory buffer
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
        
        # Visual appearance
        self.bg_color = (0, 0, 0)
        self.off_color = (10, 10, 10)
        
        # Current frame state
        self.dot_colors = [[self.off_color for _ in range(width)] for _ in range(height)]
        
        # Optional components
        self.monitor = PerformanceMonitor(enabled=enable_performance_monitor)
        self.fpp = FPPOutput(width, height, fpp_device) if enable_fpp else None
        self.preview = SourcePreview(width, height, enabled=show_source_preview)
        
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
        if isinstance(source_surface, CanvasSource):
            source_surface = source_surface.surface
        
        # Update preview if enabled
        if self.preview:
            self.preview.update(source_surface)
        
        # Scale to target resolution
        t1 = time.perf_counter()
        scaled = self._scale_surface(source_surface)
        self.monitor.record('scaling', (time.perf_counter() - t1) * 1000)
        
        # Sample and blend colors
        t2 = time.perf_counter()
        self._sample_and_blend(scaled)
        self.monitor.record('sampling_blend', (time.perf_counter() - t2) * 1000)
        
        # Visualize if not headless
        t3 = time.perf_counter()
        self._visualize()
        self.monitor.record('visualization', (time.perf_counter() - t3) * 1000)
        
        # Write to FPP if enabled
        if self.fpp:
            fpp_time = self.fpp.write(self.dot_colors)
            self.monitor.record('fpp_write', fpp_time)
        
        # Complete frame
        total_time = (time.perf_counter() - frame_start) * 1000
        self.monitor.record('total', total_time)
        self.monitor.frame_complete()
        
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
        """Optimized numpy implementation."""
        # Get direct view (no copy) - shape is (width, height, 3)
        pixel_view = surfarray.pixels3d(surface)
        
        # Transpose to (height, width, 3) and convert to uint16 for arithmetic
        rgb = np.transpose(pixel_view, (1, 0, 2)).astype(np.uint16)
        
        # Luminance calculation (integer math for speed)
        # Using 1000x multiplier: 0.2126≈213, 0.7152≈715, 0.0722≈72
        luminance = (rgb[:, :, 0] * 213 + rgb[:, :, 1] * 715 + rgb[:, :, 2] * 72) // 1000
        
        # Normalize luminance and apply blend power
        max_lum = max(1, np.max(luminance))
        blend_factors = np.power(
            np.clip(luminance.astype(np.float32) / max_lum, 0.0, 1.0),
            self.blend_power
        )[:, :, np.newaxis]
        
        # Blend with off_color
        off_array = np.array(self.off_color, dtype=np.float32)
        blended = (
            off_array * (1.0 - blend_factors) + 
            rgb.astype(np.float32) * blend_factors
        ).astype(np.uint8)
        
        # Convert to list of tuples
        self.dot_colors = [
            [tuple(blended[r, c]) for c in range(self.width)]
            for r in range(self.height)
        ]
    
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
        
        for row in range(self.height):
            for col in range(self.width):
                x = self.spacing + col * (self.dot_size + self.spacing)
                y = self.spacing + row * (self.dot_size + self.spacing) + (stagger * (col % 2))
                pygame.draw.circle(self.screen, self.dot_colors[row][col], (x, y), self.dot_size)
        
        pygame.display.flip()
    
    def clear(self):
        """Set all dots to off color."""
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
