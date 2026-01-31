import os
import sys
import argparse
import signal
import time

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
    # Use 'dummy' driver but ensure image loading still works
    # The dummy driver doesn't initialize a display but pygame.image still works
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
    os.environ['SDL_AUDIODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

# Import pygame after setting env vars
import pygame
# Initialize pygame to ensure image module is available even in headless mode
if HEADLESS:
    # Initialize display and set a video mode for the dummy driver
    # This is required for convert_alpha() to work when loading images
    pygame.display.init()
    pygame.display.set_mode((1, 1))  # Minimal dummy surface

# FPS/performance debug flag (off by default, enable via env or CLI)
FPS_DEBUG = os.environ.get('TWINKLYWALL_FPS_DEBUG', '').lower() in ('1', 'true', 'yes')

# Import after setting environment variables
from dotmatrix import DotMatrix
from games.tetris.tetris import Tetris
from video_player import VideoPlayer
from logger import log
from event_poller import EventPoller
from game_players import get_player_gamemode
import players

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

def run_tetris(matrix, stop_event=None, level=1):
    canvas_width = matrix.width * matrix.supersample
    canvas_height = (matrix.height) * matrix.supersample
    canvas = pygame.Surface((canvas_width, canvas_height), pygame.SRCALPHA)
    
    # Get gamemode from the first active player (default to MODERN if no players)
    active_players = players.active_players()
    gamemode_selection = 1  # Default to MODERN
    if active_players:
        gamemode_selection = get_player_gamemode(active_players[0].player_id)
        log(f"🎮 Starting Tetris with gamemode: {'CLASSIC' if gamemode_selection == 0 else 'MODERN'}", module="Tetris")
    
    tetris = Tetris(canvas, HEADLESS, level, gamemode_selection)
    tetris.begin_play()

    # Game timing constants
    GAME_TICK_RATE = 20
    RENDER_FPS = 20
    game_tick_interval = 1.0 / GAME_TICK_RATE
    render_interval = 1.0 / RENDER_FPS

    # Timing state
    current_time = time.time()
    last_game_tick = current_time
    last_render = current_time
    last_tick_time = current_time
    last_frame_time = current_time
    current_fps = RENDER_FPS
    
    # FPS tracking (always enabled for Tetris)
    frame_count = 0
    fps_check_interval = 100
    last_fps_time = current_time
    
    # Input state
    input_triggered_render = False
    key_press_time = {}
    key_repeating = {}
    key_last_repeat = {}
    AUTO_REPEAT_DELAY = 0.125
    AUTO_REPEAT_INTERVAL = 0.05

    # Pre-compute key list for auto-repeat
    REPEATABLE_KEYS = (pygame.K_LEFT, pygame.K_RIGHT, pygame.K_UP)
    
    # Start dedicated event polling thread (prevents event drops)
    event_poller = None
    if not HEADLESS:
        event_poller = EventPoller()
        event_poller.start()

    try:
        log("▶️ Tetris game loop started", module="Tetris")
        while True:
            current_time = time.time()
            
            # Check stop signal
            if stop_event and stop_event.is_set():
                log("⏹️  Stop signal received, exiting Tetris loop", module="Tetris")
                break

            # ALWAYS process events first - highest priority to prevent drops
            if not HEADLESS:
                input_triggered_render = False
                
                # Get all events from the dedicated polling thread
                events = event_poller.get_events()
                
                # Process all pending events in one batch
                for event in events:
                    if event.type == pygame.QUIT:
                        log("Quit event received", module="Tetris")
                        break
                    elif event.type == pygame.KEYDOWN:
                        input_triggered_render = True
                        key = event.key
                        
                        # Execute command immediately
                        try:
                            if key == pygame.K_LEFT:
                                tetris.move_piece_left()
                                key_press_time[key] = current_time
                                key_repeating[key] = False
                            elif key == pygame.K_RIGHT:
                                tetris.move_piece_right()
                                key_press_time[key] = current_time
                                key_repeating[key] = False
                            elif key == pygame.K_UP:
                                tetris.rotate_clockwise()
                                key_press_time[key] = current_time
                                key_repeating[key] = False
                            elif key == pygame.K_DOWN:
                                tetris.drop_piece(is_pressed=True)
                            elif key == pygame.K_SPACE:
                                tetris.hard_drop_piece()
                        except Exception as e:
                            log(f"Error handling key: {e}", level='ERROR', module="Tetris")
                            
                    elif event.type == pygame.KEYUP:
                        input_triggered_render = True
                        key = event.key
                        
                        # Handle drop piece release
                        try:
                            if key == pygame.K_DOWN:
                                tetris.drop_piece(is_pressed=False)
                        except Exception as e:
                            log(f"Error handling key release: {e}", level='ERROR', module="Tetris")
                        
                        # Clear tracking
                        key_press_time.pop(key, None)
                        key_repeating.pop(key, None)
                        key_last_repeat.pop(key, None)
                
                # Auto-repeat for held keys (only if no events were processed)
                if key_press_time:
                    keys_pressed = pygame.key.get_pressed()
                    for key in REPEATABLE_KEYS:
                        if key not in key_press_time or not keys_pressed[key]:
                            continue
                            
                        hold_duration = current_time - key_press_time[key]
                        
                        # Start repeating after delay
                        if not key_repeating.get(key) and hold_duration >= AUTO_REPEAT_DELAY:
                            key_repeating[key] = True
                            key_last_repeat[key] = current_time
                        
                        # Fire repeat commands
                        if key_repeating.get(key):
                            if current_time - key_last_repeat[key] >= AUTO_REPEAT_INTERVAL:
                                input_triggered_render = True
                                try:
                                    if key == pygame.K_LEFT:
                                        tetris.move_piece_left()
                                    elif key == pygame.K_RIGHT:
                                        tetris.move_piece_right()
                                    elif key == pygame.K_UP:
                                        tetris.rotate_clockwise()
                                    key_last_repeat[key] = current_time
                                except Exception as e:
                                    log(f"Error in auto-repeat: {e}", level='ERROR', module="Tetris")

            # Drain any queued player inputs (from API threads) on the game thread
            for player in players.active_players():
                while True:
                    payload = players.next_input(player.player_id)
                    if payload is None:
                        break
                    handler = player.on_input
                    if handler:
                        try:
                            handler(player, payload)
                            input_triggered_render = True
                        except Exception as e:
                            import traceback
                            log(f"Error handling queued input for player {player.player_id}: {e}\n{traceback.format_exc()}", level='ERROR', module="Tetris")

            # Game logic tick (only if enough time has passed)
            tick_needed = current_time - last_game_tick >= game_tick_interval
            if tick_needed:
                delta_time = current_time - last_tick_time
                try:
                    tetris.tick(delta_time, current_fps)
                    last_game_tick = current_time
                    last_tick_time = current_time
                except Exception as e:
                    import traceback
                    log(f"Error in tetris.tick(): {e}\n{traceback.format_exc()}", level='ERROR', module="Tetris")
                    break

            # Render frame (only if needed - don't block event processing)
            render_needed = input_triggered_render or players.input_received or current_time - last_render >= render_interval
            if render_needed:
                try:
                    matrix.render_frame(canvas)
                    frame_count += 1
                    
                    # Calculate actual FPS
                    render_delta = current_time - last_frame_time
                    if render_delta > 0:
                        current_fps = 1.0 / render_delta
                    
                    last_frame_time = current_time
                    last_render = current_time
                    players.input_received = False

                    # FPS logging (always enabled for Tetris)
                    if frame_count % fps_check_interval == 0:
                        elapsed = current_time - last_fps_time
                        actual_fps = fps_check_interval / elapsed if elapsed > 0 else 0
                        log(f"📊 Tetris FPS: {actual_fps:.1f} | Frame: {frame_count}", module="Tetris")
                        last_fps_time = current_time

                except Exception as e:
                    import traceback
                    log(f"Error in matrix.render_frame(): {e}\n{traceback.format_exc()}", level='ERROR', module="Tetris")
                    break

            # NO SLEEP - poll events as fast as possible to prevent drops

    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        import traceback
        log(f"Unexpected error in Tetris loop: {e}\n{traceback.format_exc()}", level='ERROR', module="Tetris")
    finally:
        log(f"🛑 Tetris shutting down | Total frames: {frame_count}", module="Tetris")
        
        # Stop event poller thread
        if event_poller:
            event_poller.stop()
        
        try:
            matrix.shutdown()
        except Exception as e:
            import traceback
            log(f"Error during matrix shutdown: {e}\n{traceback.format_exc()}", level='ERROR', module="Tetris")
        log("✅ Tetris fully stopped", module="Tetris")


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


def build_matrix(show_preview=True, fps=20):
    fpp_memory_file = _resolve_fpp_memory_file()
    
    # Determine output mode based on platform
    # On Pi: use FPP memory-mapped output (direct hardware control)
    # On Windows/Mac: use DDP network output to send to FPP over network
    use_fpp_output = ON_PI
    use_ddp_output = not ON_PI and sys.platform.startswith('win')  # Enable DDP on Windows
    ddp_host = os.environ.get('FPP_IP', '192.168.1.68')  # Default FPP IP
    ddp_port = int(os.environ.get('DDP_PORT', '4048'))   # Default DDP port
    
    if ON_PI:
        print(f"FPP memory file: {fpp_memory_file}")
    else:
        print(f"Running on {sys.platform}")
        if use_ddp_output:
            print(f"DDP network output enabled: {ddp_host}:{ddp_port}")
            print("Set FPP_IP environment variable to change target FPP device")
    
    # Show preview windows only when not on Pi and show_preview is True
    show_windows = not ON_PI and show_preview
    
    log(f"🎬 Building DotMatrix with {fps} FPS cap, headless={HEADLESS}, fpp_output={use_fpp_output}, ddp_output={use_ddp_output}", module="Matrix")
    
    return DotMatrix(
        headless=HEADLESS,
        fpp_output=use_fpp_output,
        ddp_output=use_ddp_output,
        ddp_host=ddp_host if use_ddp_output else None,
        ddp_port=ddp_port if use_ddp_output else 4048,
        show_source_preview=show_windows,
        enable_performance_monitor=FPS_DEBUG,
        disable_blending=True,
        supersample=1,
        max_fps=fps,  # Explicitly set FPS cap
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
    parser.add_argument("--fpp-ip", type=str, default=None, help="FPP IP address for DDP network output (Windows/Mac mode)")
    parser.add_argument("--ddp-port", type=int, default=4048, help="DDP port (default: 4048)")
    parser.add_argument("--level", type=int, default=1, help="Starting level for Tetris")
    parser.add_argument("--fps-debug", action="store_true", help="Enable FPS/performance debug logging")
    args = parser.parse_args()
    
    # Apply CLI flag for FPS debug (overrides env when true)
    global FPS_DEBUG
    if args.fps_debug:
        FPS_DEBUG = True
    
    # Set FPP IP from command line if provided
    if args.fpp_ip:
        os.environ['FPP_IP'] = args.fpp_ip
    if args.ddp_port:
        os.environ['DDP_PORT'] = str(args.ddp_port)

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
        
        # Thread to monitor Tetris and control game lifecycle
        def _monitor_tetris():
            tetris_thread = None
            stop_event = None
            matrix = None
            last_player_count = 0

            while True:
                try:
                    players = get_active_players_for_game("tetris")
                    current_count = len(players)

                    # Start Tetris if players just joined and no game is running
                    if current_count > 0 and last_player_count == 0 and (not tetris_thread or not tetris_thread.is_alive()):
                        log(f"🎮 {current_count} player(s) joined Tetris, starting game...", module="TetrisMonitor")
                        # Stop any active video playback managed by the API server
                        try:
                            from api_server import stop_current_playback
                            stop_current_playback()
                            log("🔇 Stopped active video playback before starting game", module="TetrisMonitor")
                        except Exception as e:
                            log(f"Error stopping video playback: {e}", level='ERROR', module="TetrisMonitor")
                        matrix = build_matrix(show_preview=False)  # API mode doesn't show windows
                        stop_event = threading.Event()
                        tetris_thread = threading.Thread(
                            target=run_tetris,
                            args=(matrix, stop_event),
                            daemon=True
                        )
                        tetris_thread.start()

                    # Stop Tetris if all players left and a game is running
                    elif current_count == 0 and last_player_count > 0:
                        if tetris_thread and tetris_thread.is_alive():
                            log("⏹️  All players left Tetris, stopping game immediately...", module="TetrisMonitor")
                            try:
                                if stop_event:
                                    stop_event.set()
                                    log("Set stop_event signal", module="TetrisMonitor")
                                # Wait for thread to exit (shorter timeout)
                                tetris_thread.join(timeout=1)
                                if tetris_thread.is_alive():
                                    log("⚠️  Tetris thread still alive after 1s, waiting again...", level='WARNING', module="TetrisMonitor")
                                    tetris_thread.join(timeout=1)
                                    if tetris_thread.is_alive():
                                        log("❌ Tetris thread STILL running! Forcefully abandoning it (daemon thread will be killed when process exits)", level='ERROR', module="TetrisMonitor")
                            except Exception as e:
                                log(f"Error while stopping Tetris thread: {e}", level='ERROR', module="TetrisMonitor")
                            finally:
                                try:
                                    if matrix:
                                        log("Calling matrix.shutdown()...", module="TetrisMonitor")
                                        matrix.shutdown()
                                except Exception as e:
                                    log(f"Error shutting down matrix: {e}", level='ERROR', module="TetrisMonitor")
                                tetris_thread = None
                                stop_event = None
                                matrix = None
                                log("✅ Tetris cleanup complete", module="TetrisMonitor")
                        else:
                            # No thread to stop, just reset state
                            tetris_thread = None
                            stop_event = None
                            matrix = None

                    last_player_count = current_count
                    time.sleep(1)
                except Exception as e:
                    log(f"Error in Tetris monitor: {e}", level='ERROR', module="TetrisMonitor")
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
            run_tetris(matrix, level=args.level)
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