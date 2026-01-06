"""Source preview window utilities."""

import pygame

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

try:
    from pygame._sdl2.video import Window as SDLWindow, Renderer as SDLRenderer, Texture as SDLTexture
except ImportError:
    SDLWindow = SDLRenderer = SDLTexture = None


class SourcePreview:
    def __init__(self, width, height, enabled=False, min_preview_color=(15, 15, 15)):
        self.enabled = bool(enabled and SDLWindow and SDLRenderer)
        self.window = None
        self.renderer = None
        self.texture = None

        # Clamp to valid range and precompute numpy array for fast max
        self.min_preview_color = tuple(max(0, min(255, c)) for c in min_preview_color)
        self._min_preview_array = np.array(self.min_preview_color, dtype=np.uint8) if HAS_NUMPY else None

        if self.enabled:
            self.window = SDLWindow("Source Canvas", size=(width, height), position=(50, 50))
            self.renderer = SDLRenderer(self.window)

    def _apply_min_brightness(self, surface):
        """Clamp surface so every channel is at least the preview minimum."""
        if self.min_preview_color == (0, 0, 0):
            return surface

        # Copy so we never mutate the source surface used for FPP output
        clamped = surface.copy()

        if HAS_NUMPY:
            pixels = pygame.surfarray.pixels3d(clamped)
            np.maximum(pixels, self._min_preview_array, out=pixels)
            del pixels  # release view
            return clamped

        # Fallback: per-pixel clamp (preview-only, so acceptable if slower)
        min_r, min_g, min_b = self.min_preview_color
        width, height = clamped.get_size()
        for y in range(height):
            for x in range(width):
                r, g, b, *_ = clamped.get_at((x, y))
                clamped.set_at((x, y), (max(r, min_r), max(g, min_g), max(b, min_b)))
        return clamped

    def update(self, surface):
        if not (self.enabled and self.renderer and SDLTexture):
            return
        try:
            render_surface = self._apply_min_brightness(surface)
            rendered_texture = SDLTexture.from_surface(self.renderer, render_surface)
            self.renderer.clear()
            if hasattr(self.renderer, "copy"):
                self.renderer.copy(rendered_texture, None, None)
            elif hasattr(rendered_texture, "draw"):
                rendered_texture.draw(None)
            else:
                return
            self.renderer.present()
            self.texture = rendered_texture
        except Exception:
            self.enabled = False
            self.window = None
            self.renderer = None
