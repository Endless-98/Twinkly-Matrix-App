import os
import sys
import argparse
import signal

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
from logger import log
import pygame

print(f"Platform: {'Raspberry Pi' if ON_PI else 'Desktop'}")
print(f"Mode: {'Headless' if HEADLESS else 'Windowed'}")
print(f"FPP Output: {ON_PI}\n")


def _resolve_fpp_memory_file():
    env_file = os.environ.get('FPP_MEMORY_FILE')
    if env_file:
        return env_file
    model_name = os.environ.get('FPP_MODEL_NAME', 'Light Wall')
    return f"/dev/shm/FPP-Model-Data-{model_name.replace(' ', '_')}"

from logger import log

def run_tetris(matrix):
    canvas_width = matrix.width * matrix.supersample
    # Canvas height accounts for stagger: 50 logical rows × 2 pixels per row
    # This ensures each dot gets unique pixel data when staggered columns are sampled.
    # Even columns sample rows [0,2,4,...,98], odd columns sample [1,3,5,...,99]
    canvas_height = (matrix.height * 2) * matrix.supersample  # 50 * 2 = 100px tall
    canvas = pygame.Surface((canvas_width, canvas_height))
    tetris = Tetris(canvas, HEADLESS)



    running = True
    frame_count = 0
    try:
        log("Run tetris!")
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
        frames = player.play(
            render_path,
            loop=loop,
            speed=speed,
            start_frame=start,
            end_frame=end,
            brightness=brightness,
            playback_fps=playback_fps,
        )
        print(f"Playback complete: {frames} frames")
    except KeyboardInterrupt:
        print("\nPlayback interrupted")
    finally:
        matrix.shutdown()


def build_matrix(show_preview=True):
    fpp_memory_file = _resolve_fpp_memory_file()
    if ON_PI:
        print(f"FPP memory file: {fpp_memory_file}")
    
    # Show preview windows only when not on Pi and show_preview is True
    show_windows = not ON_PI and show_preview
    
    return DotMatrix(
        headless=HEADLESS,
        fpp_output=ON_PI,
        show_source_preview=show_windows,
        enable_performance_monitor=True,
        disable_blending=True,
        supersample=1,
        # Keep FPP options configurable later; defaults here
        fpp_gamma=2.2,
        fpp_color_order="RGB",
        fpp_memory_buffer_file=fpp_memory_file,
    )


def main():
    parser = argparse.ArgumentParser(description="Run LED Wall apps")
    parser.add_argument("--mode", choices=["tetris", "video", "api"], default="api", help="App mode to run")
    parser.add_argument("--render", type=str, default=None, help="Path or name of rendered .npz (for video mode)")
    parser.add_argument("--no-loop", action="store_true", help="Disable looping (video mode)")
    parser.add_argument("--speed", type=float, default=1.0, help="Playback speed multiplier (video mode)")
    parser.add_argument("--playback-fps", type=float, default=20.0, help="Playback FPS target; adjusts speed relative to render")
    parser.add_argument("--start", type=int, default=0, help="Start frame (video mode)")
    parser.add_argument("--end", type=int, default=None, help="End frame (exclusive, video mode)")
    parser.add_argument("--brightness", type=float, default=None, help="Optional brightness scalar (0-1 or 0-255) for video mode")
    args = parser.parse_args()

    # Install graceful shutdown for SIGTERM/SIGINT so systemd stops cleanly
    def _graceful_exit(signum, frame):
        try:
            print(f"Received signal {signum}, shutting down...")
            # Best-effort cleanup for API mode if imported
            try:
                from api_server import cleanup
                cleanup()
            except Exception:
                pass
        finally:
            sys.exit(0)

    signal.signal(signal.SIGTERM, _graceful_exit)
    signal.signal(signal.SIGINT, _graceful_exit)

    if args.mode == "api":
        # Run the API server with Tetris monitor thread
        print("Starting API server mode...")
        from api_server import app, start_cleanup_thread
        from game_players import get_active_players_for_game
        import threading
        import time
        
        start_cleanup_thread()
        
        # Thread to monitor Tetris and auto-start when player joins
        def _monitor_tetris():
            tetris_instance = None
            tetris_thread = None
            last_player_count = 0
            
            while True:
                try:
                    players = get_active_players_for_game("tetris")
                    current_count = len(players)
                    
                    # Start Tetris if players just joined
                    if current_count > 0 and last_player_count == 0:
                        log(f"{current_count} player(s) joined Tetris, starting game...", module="TetrisMonitor")
                        matrix = build_matrix(show_preview=False)  # API mode doesn't show windows
                        tetris_thread = threading.Thread(
                            target=run_tetris,
                            args=(matrix,),
                            daemon=True
                        )
                        tetris_thread.start()
                    
                    # Stop Tetris if all players left
                    elif current_count == 0 and last_player_count > 0:
                        log(f"All players left Tetris, stopping game...", module="TetrisMonitor")
                    
                    last_player_count = current_count
                    time.sleep(1)
                except Exception as e:
                    log(f"Error: {e}", level='ERROR', module="TetrisMonitor")
                    time.sleep(1)
        
        monitor_thread = threading.Thread(target=_monitor_tetris, daemon=True)
        monitor_thread.start()
        
        # Run Flask server (blocks)
        app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
    else:
        matrix = build_matrix()

        if args.mode == "tetris":
            run_tetris(matrix)
        else:
            # Default to Shireworks render if none specified
            render_path = args.render or "dotmatrix/rendered_videos/Shireworks - Trim_90x50_20fps.npz"
            loop = not args.no_loop  # Loop by default for video mode
            run_video(matrix, render_path, loop, args.speed, args.start, args.end, args.brightness, args.playback_fps)


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