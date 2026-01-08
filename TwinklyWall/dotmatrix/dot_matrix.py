"""
DotMatrix: Core rendering engine for LED matrix displays.

Converts pygame surfaces to a dot matrix representation with luminance-based blending.
Supports both visual preview (pygame window) and FPP memory-mapped output for LED hardware.
"""

import pygame
import time
try:
    import numpy as np
    import pygame.surfarray as surfarray
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

from .source_preview import SourcePreview
from .performance import PerformanceMonitor
from .fpp_output import FPPOutput


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
        blend_power=0,        
        disable_blending=True,        
        supersample=3,
        headless=False,
        show_source_preview=False,
        fpp_output=False,
        fpp_memory_buffer_file="/dev/shm/FPP-Model-Data-Light_Wall",
        fpp_color_order="RGB",
        fpp_gamma=None,
        fpp_channel_gains=(1.0, 1.0, 1.0),
        enable_performance_monitor=True,
        max_fps=20
    ):
        """
        Initialize DotMatrix renderer.
        
        Args:
            width, height: Matrix dimensions in dots
            dot_size: Radius of each dot in pygame visualization
            spacing: Pixels between dots in visualization
            should_stagger: Offset alternating columns (hexagonal pattern)
            blend_power: Exponent for luminance blending (0.0-1.0)
            disable_blending: If True, skip blending and use raw sampled colors for sharp rendering
            supersample: Antialiasing factor for source scaling
            headless: Skip pygame window creation
            show_source_preview: Show separate preview window of source
            fpp_output: Enable FPP memory-mapped output
            fpp_memory_buffer_file: Path to FPP memory buffer
            fpp_color_order: One of RGB/GRB/BGR/BRG/RBG/GBR for hardware wiring
            fpp_gamma: Optional gamma correction applied only to FPP output
            fpp_channel_gains: Per-channel gain tuple applied only to FPP output
            enable_performance_monitor: Track and log performance
        """
        self.width = width
        self.height = height
        self.dot_size = dot_size
        self.spacing = spacing
        self.should_stagger = should_stagger
        self.blend_power = max(0.001, blend_power)
        self.disable_blending = disable_blending
        self.supersample = max(1, int(supersample))
        self.headless = headless
        self.max_fps = max_fps if max_fps and max_fps > 0 else None
        
        # Visual appearance
        self.bg_color = (0, 0, 0)
        self.off_color = (0, 0, 0)
        
        # Current frame state
        self.dot_colors = [[self.off_color for _ in range(width)] for _ in range(height)]
        
        # Pre-allocate tuple cache for faster updates (huge speedup!)
        if HAS_NUMPY:
            # Create a list of pre-allocated tuples to reuse
            self._color_tuples = {}  # Cache for (r,g,b) -> (r,g,b) to avoid recreation
        
        # Optional components
        self.monitor = PerformanceMonitor(enabled=enable_performance_monitor, target_fps=self.max_fps)
        # FPP output: pass through color correction and channel order
        self.fpp = FPPOutput(
            width, height, fpp_memory_buffer_file,
            color_order=fpp_color_order,
            gamma=fpp_gamma,
            channel_gains=fpp_channel_gains,
        ) if fpp_output else None
        # Scale preview window 6x for better visibility
        preview_scale = 6
        self.preview = SourcePreview(
            width * preview_scale,
            height * preview_scale,
            enabled=show_source_preview,
            min_preview_color=(15, 15, 15)
        )
        
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
            source_surface: pygame.Surface to render
        
        Returns:
            Total frame time in milliseconds
        """
        frame_start = time.perf_counter()
        
        # Extract pygame surface if wrapped (backward compatibility)
        t1 = time.perf_counter()
        if hasattr(source_surface, 'surface'):
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

    def render_colors(self, dot_colors):
        """Render precomputed color data (height x width x 3) directly.

        dot_colors can be a numpy uint8 array or a nested list/tuple structure.
        Performance stages are still recorded for visibility.
        """
        frame_start = time.perf_counter()

        # No scaling for precomputed colors
        self.monitor.record('scaling', 0.0)

        # Accept numpy or list input and store in fastest form available
        t_sample = time.perf_counter()
        if HAS_NUMPY and isinstance(dot_colors, np.ndarray):
            self.dot_colors = dot_colors
        elif HAS_NUMPY:
            self.dot_colors = np.array(dot_colors, dtype=np.uint8)
        else:
            self.dot_colors = dot_colors
        self.monitor.record('sampling_blend', (time.perf_counter() - t_sample) * 1000)

        # Visualize
        t_vis = time.perf_counter()
        self._visualize()
        self.monitor.record('visualization', (time.perf_counter() - t_vis) * 1000)

        # Write to FPP if enabled
        if self.fpp:
            fpp_time = self.fpp.write(self.dot_colors)
            self.monitor.record('fpp_write', fpp_time)

        # Complete frame
        total_time = (time.perf_counter() - frame_start) * 1000
        self.monitor.record('total', total_time)
        self.monitor.frame_complete()

        # Frame cap
        if self.max_fps:
            if self.clock:
                self.clock.tick(self.max_fps)
            else:
                target_ms = 1000.0 / self.max_fps
                remaining_ms = target_ms - total_time
                if remaining_ms > 0:
                    time.sleep(remaining_ms / 1000.0)

        return total_time
    
    def _scale_surface(self, source):
        """Scale source surface to matrix dimensions with supersampling.
        
        Special case: if source is 90×100 (staggered canvas), use it as-is.
        The 100px height accounts for the stagger where odd columns sample different rows.
        """
        current_size = source.get_size()
        
        # Special case: staggered canvas (90 × height*2) should not be scaled
        # This allows proper sampling of staggered columns
        staggered_size = (self.width, self.height * 2)
        if self.should_stagger and current_size == staggered_size:
            # Canvas is already at staggered size; no scaling needed
            return source
        
        target_size = (self.width, self.height)
        
        # Skip scaling if already at target size
        if current_size == target_size:
            return source
        
        # Choose scaling filter: nearest for sharp mode; smooth otherwise
        if self.disable_blending:
            # In sharp mode avoid any filtering to preserve exact colors
            return pygame.transform.scale(source, target_size)

        # Apply supersampling if configured (smooth scaling)
        if self.supersample > 1:
            upsampled_size = (self.width * self.supersample, self.height * self.supersample)
            if current_size != upsampled_size:
                source = pygame.transform.smoothscale(source, upsampled_size)
            return pygame.transform.smoothscale(source, target_size)
        
        return pygame.transform.smoothscale(source, target_size)
    
    def _sample_and_blend(self, surface):
        """Sample colors from surface and blend with luminance."""
        # Fast path: bypass blending entirely for sharp output
        if self.disable_blending:
            if HAS_NUMPY:
                self._sample_no_blend_numpy(surface)
            else:
                self._sample_no_blend_fallback(surface)
            return

        if HAS_NUMPY:
            self._sample_blend_numpy(surface)
        else:
            self._sample_blend_fallback(surface)

    def _sample_no_blend_numpy(self, surface):
        """Directly sample colors without luminance blending (numpy path).
        
        Handles staggered canvas (90×100) by extracting rows based on column parity.
        """
        pixel_view = surfarray.pixels3d(surface)
        # pixel_view shape is (width, height, 3)
        w, h = pixel_view.shape[0], pixel_view.shape[1]
        
        # Check if this is a staggered canvas (height = width * 2)
        if self.should_stagger and h == self.height * 2:
            # Staggered canvas: sample with column-dependent row offsets
            # Even columns sample from rows [0,2,4,...], Odd columns from [1,3,5,...]
            result = np.zeros((self.height, self.width, 3), dtype=np.uint8)
            for col in range(self.width):
                if col % 2 == 0:
                    # Even column: sample every other row starting at 0
                    src_rows = np.arange(0, h, 2, dtype=np.int32)
                else:
                    # Odd column: sample every other row starting at 1
                    src_rows = np.arange(1, h, 2, dtype=np.int32)
                
                # Copy sampled rows for this column
                for dst_row, src_row in enumerate(src_rows):
                    if src_row < h:
                        result[dst_row, col] = pixel_view[col, src_row]
            self.dot_colors = result
        else:
            # Regular canvas: standard transpose
            self.dot_colors = np.transpose(pixel_view, (1, 0, 2)).copy(order='C')
        del pixel_view

    def _sample_no_blend_fallback(self, surface):
        """Direct sampling without blending (fallback path).
        
        Handles staggered canvas (90×100) by extracting rows based on column parity.
        """
        w, h = surface.get_size()
        
        if self.should_stagger and h == self.height * 2:
            # Staggered canvas: sample with column-dependent row offsets
            for col in range(self.width):
                if col % 2 == 0:
                    # Even column: sample every other row starting at 0
                    src_rows = list(range(0, h, 2))
                else:
                    # Odd column: sample every other row starting at 1
                    src_rows = list(range(1, h, 2))
                
                for dst_row, src_row in enumerate(src_rows):
                    if src_row < h:
                        self.dot_colors[dst_row][col] = surface.get_at((col, src_row))[:3]
        else:
            # Regular canvas: direct sampling
            for row in range(self.height):
                for col in range(self.width):
                    self.dot_colors[row][col] = surface.get_at((col, row))[:3]
    
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
        # Copy to avoid holding the surface lock after this function
        rgb = np.transpose(pixel_view, (1, 0, 2)).copy(order='C')
        del pixel_view
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
        
        # Process events to keep window responsive
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                # Signal app to quit by raising KeyboardInterrupt
                import sys
                sys.exit(0)
        
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
