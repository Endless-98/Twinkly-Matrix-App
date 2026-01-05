import pygame

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
        surface = pygame.Surface((width, height))
        return cls(surface)

    @classmethod
    def from_image(cls, image_path, size=None):
        image = pygame.image.load(image_path)
        try:
            image = image.convert_alpha()
        except pygame.error:
            # Display format not available in headless mode
            pass
        if size:
            image = pygame.transform.smoothscale(image, size)
        return cls(image)

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


class SourcePreview:
    def __init__(self, width, height, enabled=False):
        self.enabled = bool(enabled and SDLWindow and SDLRenderer)
        self.window = None
        self.renderer = None
        self.texture = None
        if self.enabled:
            self.window = SDLWindow("Source Canvas", size=(width, height), position=(50, 50))
            self.renderer = SDLRenderer(self.window)

    def update(self, surface):
        if not (self.enabled and self.renderer and SDLTexture):
            return
        try:
            texture = SDLTexture.from_surface(self.renderer, surface)
            self.renderer.clear()
            if hasattr(self.renderer, "copy"):
                self.renderer.copy(texture, None, None)
            elif hasattr(texture, "draw"):
                texture.draw(None)
            else:
                return
            self.renderer.present()
            self.texture = texture
        except Exception:
            # Disable preview on failure to avoid crashing the app.
            self.enabled = False
            self.window = None
            self.renderer = None
            self.texture = None
