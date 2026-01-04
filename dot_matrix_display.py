import os
import mmap
import pygame
import time

try:
    from pygame._sdl2.video import Window as SDLWindow, Renderer as SDLRenderer, Texture as SDLTexture
except ImportError:  # Optional dependency; preview window will be skipped if unavailable.
    SDLWindow = SDLRenderer = SDLTexture = None


class CanvasSource:
    def __init__(self, source_surface):
        self.surface = source_surface

    @classmethod
    def from_window(cls, window_surface=None):
        surface = window_surface or pygame.display.get_surface()
        if surface is None:
            raise RuntimeError("No Pygame display surface is available to capture.")
        return cls(surface)

    @classmethod
    def from_size(cls, width, height):
        surface = pygame.Surface((width, height)).convert()
        return cls(surface)

    def update_from_window(self, window_surface=None):
        surface = window_surface or pygame.display.get_surface()
        if surface is None:
            raise RuntimeError("No Pygame display surface is available to capture.")
        target_size = self.surface.get_size()
        if surface.get_size() != target_size:
            self.surface = pygame.transform.smoothscale(surface, target_size)
        else:
            self.surface.blit(surface, (0, 0))
        return self.surface

class DotMatrix:
    def __init__(
        self,
        width=87,
        height=50,
        dot_size=6,
        spacing=15,
        should_stagger=True,
        blend_power=1.0,
        show_source_preview=False,
    ):
        self.width = width
        self.height = height
        self.dot_size = dot_size
        self.spacing = spacing
        self.should_stagger = should_stagger
        self.blend_power = blend_power  # >1 hardens edges, <1 softens them
        self.show_source_preview = show_source_preview
        pygame.init()

        self.bg_color = (0, 0, 0)
        self.off_color = (50, 50, 50)
        self.on_color = (255, 255, 255)
        self.dot_colors = [[self.off_color for _ in range(width)] for _ in range(height)]
        
        # Calculate window size based on matrix dimensions
        window_width = width * (dot_size + spacing) + spacing
        window_height = height * (dot_size + spacing) + spacing
        
        self.screen = pygame.display.set_mode((window_width, window_height))
        pygame.display.set_caption("Dot Matrix Display")

        self.source_window = None
        self.source_renderer = None
        self.source_texture = None
        if self.show_source_preview and SDLWindow and SDLRenderer:
            self._init_source_preview()
        
        self.clock = pygame.time.Clock()
        self.running = True

    def draw_dot(self, x, y, color=(50, 50, 50)):
        pygame.draw.circle(self.screen, color, (x, y), self.dot_size)

    def display_matrix(self):
        self.screen.fill(self.bg_color)
        first_column_color = (255, 0, 0)  # Red for the first column
        second_column_color = (0, 255, 0)  # Green for the second column
        stagger_offset = (self.dot_size / 2) + self.spacing / 2 if self.should_stagger else 0
        for row in range(self.height):
            for col in range(self.width):
                x = self.spacing + col * (self.dot_size + self.spacing)
                y = self.spacing + row * (self.dot_size + self.spacing) + (stagger_offset * (col % 2))
                self.draw_dot(x, y, color=self.dot_colors[row][col])
        
        pygame.display.flip()

    def _dot_position(self, row, col):
        stagger_offset = (self.dot_size / 2) + self.spacing / 2 if self.should_stagger else 0
        x = self.spacing + col * (self.dot_size + self.spacing)
        y = self.spacing + row * (self.dot_size + self.spacing) + (stagger_offset * (col % 2))
        return x, y

    def handle_click(self, pos):
        mx, my = pos
        radius_sq = self.dot_size * self.dot_size
        for row in range(self.height):
            for col in range(self.width):
                x, y = self._dot_position(row, col)
                dx = mx - x
                dy = my - y
                if dx * dx + dy * dy <= radius_sq:
                    new_color = self.off_color if self.dot_colors[row][col] == self.on_color else self.on_color
                    self.dot_colors[row][col] = new_color
                    self.draw_dot(x, y, color=new_color)
                    pygame.display.update()
                    return

    def convert_canvas_to_matrix(self, canvas):
        # Accepts either a CanvasSource or a raw Pygame surface.
        source_surface = canvas.surface if isinstance(canvas, CanvasSource) else canvas
        if self.show_source_preview:
            self._maybe_update_preview(source_surface)
        canvas_width, canvas_height = source_surface.get_size()
        for row in range(self.height):
            for col in range(self.width):
                x = int((col + 0.5) * canvas_width / self.width)
                y = int((row + 0.5) * canvas_height / self.height)
                color = source_surface.get_at((x, y))[:3]
                brightness = sum(color) / 3
                # Map brightness to a blend factor, tweakable via blend_power
                t = max(0.0, min(1.0, brightness / 255.0)) ** max(0.001, self.blend_power)
                # Preserve hue by blending toward the sampled color instead of pure white.
                blended = tuple(
                    int(self.off_color[i] + (color[i] - self.off_color[i]) * t)
                    for i in range(3)
                )
                self.dot_colors[row][col] = blended
        self.display_matrix()

    def _init_source_preview(self):
        # Uses pygame._sdl2 to open a second window to visualize the source canvas.
        self.source_window = SDLWindow("Source Canvas", size=(self.width, self.height), position=(50, 50))
        self.source_renderer = SDLRenderer(self.source_window)
        self.source_texture = None

    def _maybe_update_preview(self, surface):
        if not (self.source_renderer and SDLTexture):
            return
        try:
            # Recreate texture each time to keep things simple and robust across formats.
            texture = SDLTexture.from_surface(self.source_renderer, surface)
            self.source_renderer.clear()
            if hasattr(self.source_renderer, "copy"):
                # copy supports optional src/dst rects; let it stretch to window size.
                self.source_renderer.copy(texture, None, None)
            elif hasattr(texture, "draw"):
                # draw accepts an optional dest rect or None to fill the target.
                texture.draw(None)
            else:
                return
            self.source_renderer.present()
            self.source_texture = texture
        except Exception:
            # If preview rendering fails on this platform/build, disable it to avoid crashing.
            self.source_renderer = None
            self.source_window = None
            self.source_texture = None

    def render_sample_pattern(self):
        source_canvas = CanvasSource.from_size(self.width, self.height)
        source_canvas.surface.fill((0, 0, 0))
        pygame.draw.circle(
            source_canvas.surface,
            (0, 200, 255),
            (
                source_canvas.surface.get_width() // 2,
                source_canvas.surface.get_height() // 2,
            ),
            min(
                source_canvas.surface.get_width(),
                source_canvas.surface.get_height(),
            ) // 3,
        )
        self.convert_canvas_to_matrix(source_canvas)

    def wait_for_exit(self):
        while self.running:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    self.running = False
                if event.type == pygame.MOUSEBUTTONDOWN:
                    self.handle_click(event.pos)
            
            self.clock.tick(40)  # 40 FPS
        
        pygame.quit()
