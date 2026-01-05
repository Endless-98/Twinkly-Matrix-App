import os
import sys

# Set pygame to use dummy driver if headless
def is_raspberry_pi():
    """Detect if running on Raspberry Pi."""
    try:
        with open('/proc/device-tree/model', 'r') as f:
            return 'raspberry pi' in f.read().lower()
    except:
        return False

ON_PI = is_raspberry_pi()
HEADLESS = ON_PI or ('DISPLAY' not in os.environ)

if HEADLESS:
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
    os.environ['SDL_AUDIODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

# Import after setting environment variables
from dotmatrix import DotMatrix, CanvasSource
import pygame

print(f"Platform: {'Raspberry Pi' if ON_PI else 'Desktop'}")
print(f"Mode: {'Headless' if HEADLESS else 'Windowed'}")
print(f"FPP Output: {ON_PI}\n")


def main():
    # Create matrix with platform-appropriate settings
    matrix = DotMatrix(
        headless=HEADLESS,
        fpp_output=ON_PI,
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
    
    # Animation loop
    running = True
    frame_count = 0
    try:
        while running:
            # Handle events
            if not HEADLESS:
                for event in pygame.event.get():
                    if event.type == pygame.QUIT:
                        running = False
            
            
            
            # Render to matrix
            matrix.render_frame(canvas)
            frame_count += 1
            if frame_count == 1:
                print(f"First frame rendered successfully")
    
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        matrix.shutdown()


if __name__ == "__main__":
    main()


def animate_test_circle(canvas, ball_x, ball_y, velocity_x, velocity_y, radius, canvas_width, canvas_height):
                """Update ball physics and render to canvas."""
                # Update physics
                ball_x += velocity_x
                ball_y += velocity_y
                
                # Bounce off walls
                if ball_x - radius < 0 or ball_x + radius > canvas_width:
                    velocity_x *= -1
                if ball_y - radius < 0 or ball_y + radius > canvas_height:
                    velocity_y *= -1
                
                # Clear and redraw
                canvas.surface.fill((0, 0, 0))
                pygame.draw.circle(
                    canvas.surface,
                    (0, 200, 255),
                    (int(ball_x), int(ball_y)),
                    radius
                )
                
                return ball_x, ball_y, velocity_x, velocity_y