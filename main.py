import os
import sys
import argparse

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
from dotmatrix import DotMatrix
from games.tetris import Tetris
from video_player import VideoPlayer
import pygame

print(f"Platform: {'Raspberry Pi' if ON_PI else 'Desktop'}")
print(f"Mode: {'Headless' if HEADLESS else 'Windowed'}")
print(f"FPP Output: {ON_PI}\n")


def run_tetris(matrix):
    canvas_width = matrix.width * matrix.supersample
    canvas_height = matrix.height * matrix.supersample
    canvas = pygame.Surface((canvas_width, canvas_height))
    tetris = Tetris(canvas, HEADLESS)

    running = True
    frame_count = 0
    try:
        while running:
            if not HEADLESS:
                for event in pygame.event.get():
                    if event.type == pygame.QUIT:
                        running = False
            tetris.tick()
            matrix.render_frame(canvas)
            frame_count += 1
            if frame_count == 1:
                print("First frame rendered successfully")
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        matrix.shutdown()


def run_video(matrix, render_path, loop, speed, start, end, brightness, playback_fps):
    player = VideoPlayer(matrix)

    # If playback_fps is specified, compute speed relative to the render fps
    if playback_fps is not None:
        clip_meta = player.load(render_path)
        render_fps = clip_meta["fps"]
        speed = float(playback_fps) / float(render_fps)
        print(f"Playback fps override: render {render_fps:.2f} -> playback {playback_fps:.2f} (speed={speed:.3f})")

    try:
        frames = player.play(render_path, loop=loop, speed=speed, start_frame=start, end_frame=end, brightness=brightness)
        print(f"Playback complete: {frames} frames")
    except KeyboardInterrupt:
        print("\nPlayback interrupted")
    finally:
        matrix.shutdown()


def build_matrix():
    return DotMatrix(
        headless=HEADLESS,
        fpp_output=ON_PI,
        show_source_preview=True,
        enable_performance_monitor=False,
        disable_blending=True,
        supersample=1,
        # Keep FPP options configurable later; defaults here
        fpp_gamma=2.2,
        fpp_color_order="RGB",
    )


def main():
    parser = argparse.ArgumentParser(description="Run LED Wall apps")
    parser.add_argument("--mode", choices=["tetris", "video"], default="video", help="App mode to run")
    parser.add_argument("--render", type=str, default=None, help="Path or name of rendered .npz (for video mode)")
    parser.add_argument("--loop", action="store_true", help="Loop playback (video mode)")
    parser.add_argument("--speed", type=float, default=1.0, help="Playback speed multiplier (video mode)")
    parser.add_argument("--playback-fps", type=float, default=None, help="Override playback FPS; adjusts speed relative to render")
    parser.add_argument("--start", type=int, default=0, help="Start frame (video mode)")
    parser.add_argument("--end", type=int, default=None, help="End frame (exclusive, video mode)")
    parser.add_argument("--brightness", type=float, default=None, help="Optional brightness scalar (0-1 or 0-255) for video mode")
    args = parser.parse_args()

    matrix = build_matrix()

    if args.mode == "tetris":
        run_tetris(matrix)
    else:
        # Default to Star-Spangled render if none specified
        render_path = args.render or "dotmatrix/rendered_videos/Star-Spangled Banner - HD Video Background Loop_90x50_40fps.npz"
        run_video(matrix, render_path, args.loop, args.speed, args.start, args.end, args.brightness, args.playback_fps)


if __name__ == "__main__":
    main()


def animate_test_circle(canvas, canvas_width, canvas_height):
    """Update ball physics and render to canvas."""
           
    # Animation state
    ball_x = canvas_width // 2
    ball_y = canvas_height // 2
    velocity_x = 3
    velocity_y = 2
    radius = 20
                
    # Update physics
    ball_x += velocity_x
    ball_y += velocity_y
    
    # Bounce off walls
    if ball_x - radius < 0 or ball_x + radius > canvas_width:
        velocity_x *= -1
    if ball_y - radius < 0 or ball_y + radius > canvas_height:
        velocity_y *= -1
    
    # Clear and redraw
    canvas.fill((0, 0, 0))
    pygame.draw.circle(
        canvas,
        (0, 200, 255),
        (int(ball_x), int(ball_y)),
        radius
    )
    
    return ball_x, ball_y, velocity_x, velocity_y