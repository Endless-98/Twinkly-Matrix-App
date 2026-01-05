import pygame
import time
import mmap
import os
from .source_canvas import CanvasSource, SourcePreview
from .light_wall_mapping import load_light_wall_mapping, create_fpp_buffer_from_grid


class DotMatrix:
    def __init__(
        self,
        width=90,
        height=50,
        dot_size=6,
        spacing=15,
        should_stagger=True,
        blend_power=0.2,
        show_source_preview=False,
        supersample=3,
        headless=False,
        fpp_output=False,
        fpp_memory_buffer_file="/dev/shm/FPP-Model-Data-Light_Wall",
    ):
        self.width = width
        self.height = height
        self.dot_size = dot_size
        self.spacing = spacing
        self.should_stagger = should_stagger
        self.blend_power = blend_power
        self.supersample = max(1, int(supersample))
        self.headless = headless
        self.running = True
        
        self.fpp_mm = None
        self.fpp_memory_buffer_file = None
        self.fpp_mapping = load_light_wall_mapping() if fpp_output else None
        if fpp_output:
            self._initialize_fpp(fpp_memory_buffer_file)
        
        if not headless:
            pygame.init()

        self.bg_color = (0, 0, 0)
        self.off_color = (10, 10, 10)
        self.dot_colors = [[self.off_color for _ in range(width)] for _ in range(height)]
        
        window_width = width * (dot_size + spacing) + spacing
        window_height = height * (dot_size + spacing) + spacing
        
        if headless:
            self.screen = None
        else:
            self.screen = pygame.display.set_mode((window_width, window_height))
            pygame.display.set_caption("Dot Matrix Display")

        self.preview = SourcePreview(self.width, self.height, enabled=show_source_preview)
        self.clock = pygame.time.Clock() if not headless else None

    def _initialize_fpp(self, fpp_file):
        buffer_size = self.width * self.height * 3  # 87 * 50 * 3 = 13,050 bytes
        try:
            if not os.path.exists(fpp_file):
                try:
                    with open(fpp_file, 'wb') as f:
                        f.write(b'\x00' * buffer_size)
                except PermissionError:
                    print(f"Permission denied creating {fpp_file}")
                    print("Try running: sudo touch {}".format(fpp_file))
                    print("          sudo chmod 666 {}".format(fpp_file))
                    raise
            
            # Get actual file size to handle mmap correctly
            file_size = os.path.getsize(fpp_file)
            mmap_size = min(buffer_size, file_size)  # Use smaller of expected or actual
            
            self.fpp_memory_buffer_file = open(fpp_file, 'r+b')
            self.fpp_mm = mmap.mmap(self.fpp_memory_buffer_file.fileno(), mmap_size)
        except PermissionError:
            print(f"Permission denied accessing {fpp_file}")
            print("Fix with: sudo chmod 666 {}".format(fpp_file))
            if self.fpp_memory_buffer_file:
                self.fpp_memory_buffer_file.close()
            self.fpp_mm = None
            self.fpp_memory_buffer_file = None
        except Exception as e:
            print(f"FPP output initialization failed: {e}")
            if self.fpp_memory_buffer_file:
                self.fpp_memory_buffer_file.close()
            self.fpp_mm = None
            self.fpp_memory_buffer_file = None

    def draw_on_twinklys(self):
        if not self.fpp_mm or not self.fpp_mapping:
            return
        
        buffer = create_fpp_buffer_from_grid(self.dot_colors, self.fpp_mapping)
        
        self.fpp_mm.seek(0)
        self.fpp_mm.write(buffer)
        self.fpp_mm.flush()

    def draw_dot(self, x, y, color):
        if self.screen:
            pygame.draw.circle(self.screen, color, (x, y), self.dot_size)

    def visualize_matrix(self): # Only in non-headless mode
        if self.headless:
            return
            
        self.screen.fill(self.bg_color)
        stagger_offset = (self.dot_size / 2) + self.spacing / 2 if self.should_stagger else 0
        
        for row in range(self.height):
            for col in range(self.width):
                x = self.spacing + col * (self.dot_size + self.spacing)
                y = self.spacing + row * (self.dot_size + self.spacing) + (stagger_offset * (col % 2))
                self.draw_dot(x, y, self.dot_colors[row][col])
        
        pygame.display.flip()

    def _dot_position(self, row, col):
        stagger_offset = (self.dot_size / 2) + self.spacing / 2 if self.should_stagger else 0
        x = self.spacing + col * (self.dot_size + self.spacing)
        y = self.spacing + row * (self.dot_size + self.spacing) + (stagger_offset * (col % 2))
        return x, y

    def convert_canvas_to_matrix(self, canvas): # TODO - Move to source_canvas
        source_surface = canvas.surface if isinstance(canvas, CanvasSource) else canvas
        if self.preview:
            self.preview.update(source_surface)

        base_w, base_h = self.width, self.height
        target_up = (base_w * self.supersample, base_h * self.supersample)

        working_surface = source_surface
        if working_surface.get_size() != target_up:
            working_surface = pygame.transform.smoothscale(working_surface, target_up)

        scaled_surface = pygame.transform.smoothscale(working_surface, (base_w, base_h))
        
        samples = []
        max_luminance = 0.0
        for row in range(self.height):
            for col in range(self.width):
                color = scaled_surface.get_at((col, row))[:3]
                luminance = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
                samples.append((row, col, color, luminance))
                if luminance > max_luminance:
                    max_luminance = luminance

        norm = max(1.0, max_luminance)
        exp = max(0.001, self.blend_power)
        
        for row, col, color, luminance in samples:
            t = max(0.0, min(1.0, luminance / norm)) ** exp
            blended = tuple(
                int(self.off_color[i] * (1.0 - t) + color[i] * t)
                for i in range(3)
            )
            self.dot_colors[row][col] = blended

        self.visualize_matrix()
        self.draw_on_twinklys()

    def render_sample_pattern(self):
        if self.headless:
            # In headless FPP mode, render circle directly to dot_colors without pygame
            self._render_circle_pattern()
            self.draw_on_twinklys()
        else:
            # On desktop with display, use pygame for rendering
            pygame.init()
            hi_w = self.width * self.supersample
            hi_h = self.height * self.supersample
            source_canvas = CanvasSource.from_size(hi_w, hi_h)
            source_canvas.surface.fill((0, 0, 0))
            pygame.draw.circle(
                source_canvas.surface,
                (0, 200, 255),  # Cyan
                (hi_w // 2, hi_h // 2),
                min(hi_w, hi_h) // 3,
            )
            self.convert_canvas_to_matrix(source_canvas)
    
    def _render_circle_pattern(self):
        """Render a cyan circle directly without pygame surfaces (safe for headless FPP)"""
        # Use supersampled dimensions for better circle quality
        ss_width = self.width * self.supersample
        ss_height = self.height * self.supersample
        
        # Center and radius in supersampled space
        center_x = ss_width / 2
        center_y = ss_height / 2
        radius = min(ss_width, ss_height) / 3
        
        cyan = (0, 200, 255)
        off = self.off_color
        
        # Create supersampled grid and downsample
        ss_grid = [[off for _ in range(ss_width)] for _ in range(ss_height)]
        
        # Draw circle in supersampled space
        for ss_row in range(ss_height):
            for ss_col in range(ss_width):
                dx = ss_col - center_x
                dy = ss_row - center_y
                dist = (dx * dx + dy * dy) ** 0.5
                
                if dist <= radius:
                    ss_grid[ss_row][ss_col] = cyan
        
        # Downsample back to grid resolution
        for row in range(self.height):
            for col in range(self.width):
                # Average the supersampled pixels
                r_sum = g_sum = b_sum = 0
                count = 0
                for ss_row in range(row * self.supersample, (row + 1) * self.supersample):
                    for ss_col in range(col * self.supersample, (col + 1) * self.supersample):
                        r, g, b = ss_grid[ss_row][ss_col]
                        r_sum += r
                        g_sum += g
                        b_sum += b
                        count += 1
                
                r_avg = int(r_sum / count)
                g_avg = int(g_sum / count)
                b_avg = int(b_sum / count)
                self.dot_colors[row][col] = (r_avg, g_avg, b_avg)

    def render_image(self, image_path):
        source_canvas = CanvasSource.from_image(image_path, size=(self.width, self.height))
        self.convert_canvas_to_matrix(source_canvas)

    def wait_for_exit(self):
        if self.headless:
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                pass
            finally:
                self._turn_off_all_lights()
        else:
            try:
                while self.running:
                    for event in pygame.event.get():
                        if event.type == pygame.QUIT:
                            self.running = False
                        if event.type == pygame.MOUSEBUTTONDOWN:
                            self.handle_click(event.pos)
                    
                    if self.clock:
                        self.clock.tick(40)
            except KeyboardInterrupt:
                pass
            finally:
                self._turn_off_all_lights()
                pygame.quit()
    
    def _turn_off_all_lights(self):
        """Turn off all LEDs by setting them to black and writing to FPP"""
        for row in range(self.height):
            for col in range(self.width):
                self.dot_colors[row][col] = (0, 0, 0)
        
        if self.fpp_mm:
            self.draw_on_twinklys()
        
        if self.fpp_mm:
            self.fpp_mm.close()
        if self.fpp_memory_buffer_file:
            self.fpp_memory_buffer_file.close()