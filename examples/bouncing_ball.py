"""
Example: Bouncing ball animation for DotMatrix display.
"""

import pygame
import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotmatrix.dot_matrix_refactored import DotMatrix
from dotmatrix.source_canvas import CanvasSource


def bouncing_ball_demo(headless=False, enable_fpp=False):
    """Run bouncing ball animation."""
    
    # Create matrix
    matrix = DotMatrix(
        headless=headless,
        enable_fpp=enable_fpp,
        show_source_preview=False,
        enable_performance_monitor=True
    )
    
    # Create canvas
    canvas_width = matrix.width * matrix.supersample
    canvas_height = matrix.height * matrix.supersample
    canvas = CanvasSource.from_size(canvas_width, canvas_height)
    
    # Animation state
    ball_x = canvas_width // 2
    ball_y = canvas_height // 2
    velocity_x = 3
    velocity_y = 2
    radius = 20
    
    # Main loop
    running = True
    try:
        while running:
            # Handle events
            if not headless:
                for event in pygame.event.get():
                    if event.type == pygame.QUIT:
                        running = False
            
            # Update physics
            ball_x += velocity_x
            ball_y += velocity_y
            
            # Bounce
            if ball_x - radius < 0 or ball_x + radius > canvas_width:
                velocity_x *= -1
            if ball_y - radius < 0 or ball_y + radius > canvas_height:
                velocity_y *= -1
            
            # Draw
            canvas.surface.fill((0, 0, 0))
            pygame.draw.circle(
                canvas.surface,
                (0, 200, 255),
                (int(ball_x), int(ball_y)),
                radius
            )
            
            # Render
            matrix.render_frame(canvas)
    
    except KeyboardInterrupt:
        pass
    finally:
        matrix.shutdown()


if __name__ == "__main__":
    # Auto-detect if on Raspberry Pi
    def is_pi():
        try:
            with open('/proc/device-tree/model', 'r') as f:
                return 'raspberry pi' in f.read().lower()
        except:
            return False
    
    on_pi = is_pi()
    bouncing_ball_demo(headless=on_pi, enable_fpp=on_pi)
