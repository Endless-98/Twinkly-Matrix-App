import os
import mmap
import pygame
import time

from .source_canvas import CanvasSource, SourcePreview


class DotMatrix:
    def __init__(
        self,
        width=87,
        height=50,
        dot_size=6,
        spacing=15,
        should_stagger=True,
        blend_power=0.2,
        show_source_preview=False,
        supersample=3,
        debug_log=True,
    ):
        self.width = width
        self.height = height
        self.dot_size = dot_size
        self.spacing = spacing
        self.should_stagger = should_stagger
        self.blend_power = blend_power
        self.show_source_preview = show_source_preview
        self.supersample = max(1, int(supersample))
        self.debug_log = debug_log
        pygame.init()

        self.bg_color = (0, 0, 0)
        self.off_color = (10, 10, 10)
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

        base_w, base_h = self.width, self.height
        target_up = (base_w * self.supersample, base_h * self.supersample)

        working_surface = source_surface
        if working_surface.get_size() != target_up:
            working_surface = pygame.transform.smoothscale(working_surface, target_up)

        # Downscale to matrix resolution to introduce spatial blending/AA.
        scaled_surface = pygame.transform.smoothscale(working_surface, (base_w, base_h))
        canvas_width, canvas_height = scaled_surface.get_size()
        
        ###
        debug_stats = None
        if self.debug_log:
            debug_stats = {
                "luminance_min": float("inf"),
                "luminance_max": float("-inf"),
                "t_min": float("inf"),
                "t_max": float("-inf"),
                "t_sum": 0.0,
                "count": 0,
                "samples": {},
            }
            sample_points = {
                "center": (self.width // 2, self.height // 2),
                "tl": (0, 0),
                "tr": (self.width - 1, 0),
                "bl": (0, self.height - 1),
                "br": (self.width - 1, self.height - 1),
            }
        ###

        samples = []
        max_luminance = 0.0
        for row in range(self.height):
            for col in range(self.width):
                x = col
                y = row
                color = scaled_surface.get_at((x, y))[:3]
                luminance = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
                samples.append((row, col, x, y, color, luminance))
                if luminance > max_luminance:
                    max_luminance = luminance
                if debug_stats is not None:
                    debug_stats["luminance_min"] = min(debug_stats["luminance_min"], luminance)
                    debug_stats["luminance_max"] = max(debug_stats["luminance_max"], luminance)

        norm = max(1.0, max_luminance)
        if debug_stats is not None:
            debug_stats["norm"] = norm

        exp = max(0.001, self.blend_power)
        for row, col, x, y, color, luminance in samples:
            t = max(0.0, min(1.0, luminance / norm))
            t = t ** exp
            blended = tuple(
                int(self.off_color[i] * (1.0 - t) + color[i] * t)
                for i in range(3)
            )
            self.dot_colors[row][col] = blended

            ###
            if debug_stats is not None:
                debug_stats["t_min"] = min(debug_stats["t_min"], t)
                debug_stats["t_max"] = max(debug_stats["t_max"], t)
                debug_stats["t_sum"] += t
                debug_stats["count"] += 1
                for label, (sx, sy) in sample_points.items():
                    if col == sx and row == sy:
                        debug_stats["samples"][label] = {
                            "src_xy": (x, y),
                            "src_color": color,
                            "luminance": round(luminance, 3),
                            "t": round(t, 3),
                            "blended": blended,
                        }
            ###

        self.display_matrix()

        ###
        if debug_stats is not None and debug_stats["count"]:
            avg_t = debug_stats["t_sum"] / debug_stats["count"]
            print("[DotMatrix Debug] blend_power=%.3f" % self.blend_power)
            print(
                "[DotMatrix Debug] luminance min/max=%.2f/%.2f (norm=%.2f)" %
                (debug_stats["luminance_min"], debug_stats.get("luminance_max", 0), debug_stats.get("norm", 0))
            )
            print(
                "[DotMatrix Debug] t min/max/avg=%.3f/%.3f/%.3f" %
                (debug_stats["t_min"], debug_stats["t_max"], avg_t)
            )
            for label, sample in debug_stats["samples"].items():
                print(
                    f"[DotMatrix Debug] sample {label}: src_xy={sample['src_xy']} "
                    f"color={sample['src_color']} luminance={sample['luminance']} "
                    f"t={sample['t']} blended={sample['blended']}"
                )
        ###

    def render_sample_pattern(self):
        hi_w = self.width * self.supersample
        hi_h = self.height * self.supersample
        source_canvas = CanvasSource.from_size(hi_w, hi_h)
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
