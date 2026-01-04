import os
import mmap
import pygame
import time

from source_canvas import CanvasSource, SourcePreview


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

        self.preview = SourcePreview(self.width, self.height, enabled=self.show_source_preview)
        
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
        if self.preview:
            self.preview.update(source_surface)
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

    def render_image(self, image_path):
        source_canvas = CanvasSource.from_image(image_path, size=(self.width, self.height))
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
