"""
Flask API server for controlling the LED matrix video playback.
Provides REST endpoints for the Flutter app to communicate with.
"""

import os
import threading
import time
import traceback
from pathlib import Path
from flask import Flask, jsonify, request
from flask_cors import CORS
from dotmatrix import DotMatrix
from video_player import VideoPlayer
from game_players import join_game, leave_game, heartbeat, get_active_players_for_game, is_game_full, get_game_for_player, player_count_for_game
from logger import log

app = Flask(__name__)
CORS(app)  # Enable CORS for Flutter web app

# Global state
current_player = None
current_matrix = None
playback_thread = None
playback_active = False
current_video_name = None
rendered_videos_dir = Path("dotmatrix/rendered_videos")
source_videos_dir = Path("assets/source_videos")

# Cleanup thread for idle players
cleanup_thread = None
cleanup_active = False


def _resolve_fpp_memory_file():
    """Resolve the FPP memory-mapped file path from env.

    Precedence:
    - FPP_MEMORY_FILE (full path)
    - FPP_MODEL_NAME (model name; spaces become underscores)
    - default to Light_Wall
    """
    env_file = os.environ.get("FPP_MEMORY_FILE")
    if env_file:
        return env_file
    model_name = os.environ.get("FPP_MODEL_NAME", "Light Wall")
    safe_model = model_name.replace(" ", "_")
    return f"/dev/shm/FPP-Model-Data-{safe_model}"


def get_video_name_from_source(source_filename):
    """Convert source video filename to rendered video filename."""
    base_name = Path(source_filename).stem
    # Look for matching rendered file
    for rendered_file in rendered_videos_dir.glob(f"{base_name}*.npz"):
        return rendered_file.name
    return None


def initialize_matrix():
    """Initialize the DotMatrix if not already initialized."""
    global current_matrix
    if current_matrix is None:
        # Detect if running on Pi
        try:
            with open('/proc/device-tree/model', 'r') as f:
                on_pi = 'raspberry pi' in f.read().lower()
        except:
            on_pi = False
        
        headless = on_pi or ('DISPLAY' not in os.environ)
        
        fpp_memory_file = _resolve_fpp_memory_file()
        print(f"DotMatrix init: headless={headless}")
        print(f"DotMatrix FPP output enabled: {on_pi}")
        if on_pi:
            print(f"DotMatrix FPP memory file: {fpp_memory_file}")

        current_matrix = DotMatrix(
            headless=headless,
            fpp_output=on_pi,
            show_source_preview=True,
            enable_performance_monitor=True,
            disable_blending=True,
            supersample=1,
            fpp_gamma=2.2,
            fpp_color_order="RGB",
            fpp_memory_buffer_file=fpp_memory_file,
        )
    return current_matrix


def stop_current_playback():
    """Stop the current playback if any."""
    global playback_active, current_player, playback_thread, current_video_name
    
    playback_active = False
    current_video_name = None
    
    if current_player:
        current_player.stop()
        current_player = None
    
    if playback_thread and playback_thread.is_alive():
        playback_thread.join(timeout=2)
    playback_thread = None

    # After stopping playback, explicitly clear the LEDs to black on FPP
    try:
        matrix = initialize_matrix()
        if matrix:
            # Set internal buffer to black
            matrix.clear()
            # Push the black frame to hardware immediately
            if getattr(matrix, 'fpp', None):
                matrix.fpp.write(matrix.dot_colors)
    except Exception as e:
        # Avoid crashing stop flow on clear failures; just log
        print(f"Warning: failed to clear LEDs after stop: {e}")


def play_video_thread(video_path, loop, speed, brightness, playback_fps):
    """Thread function to play video."""
    global current_player, current_matrix, playback_active
    
    try:
        matrix = initialize_matrix()
        player = VideoPlayer(matrix)
        current_player = player
        
        print(f"Starting playback: {video_path}")
        print(f"  Loop: {loop}, Speed: {speed}, Brightness: {brightness}, FPS: {playback_fps}")
        
        # Play the video
        frames = player.play(
            video_path,
            loop=loop,
            speed=speed,
            start_frame=0,
            end_frame=None,
            brightness=brightness,
            playback_fps=playback_fps,
        )
        
        print(f"Playback complete: {frames} frames")
        
    except Exception as e:
        print(f"Error during playback: {e}")
    finally:
        playback_active = False
        current_player = None


@app.route('/api/videos', methods=['GET'])
def get_videos():
    """Get list of available rendered videos (.npz)."""
    try:
        # Ensure the rendered videos directory exists; create if missing
        if not rendered_videos_dir.exists():
            try:
                rendered_videos_dir.mkdir(parents=True, exist_ok=True)
            except Exception:
                pass
            return jsonify({'videos': []})

        videos = []
        for file in rendered_videos_dir.iterdir():
            if file.is_file() and file.suffix.lower() == '.npz':
                videos.append(file.name)

        videos.sort()
        return jsonify({'videos': videos})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/play', methods=['POST'])
def play_video():
    """Start playing a video."""
    global playback_active, playback_thread, current_video_name
    
    try:
        data = request.json
        video_name = data.get('video')
        loop = data.get('loop', True)
        brightness = data.get('brightness', None)
        playback_fps = data.get('playback_fps', 20.0)
        
        if not video_name:
            return jsonify({'error': 'No video specified'}), 400
        
        # Accept a rendered filename directly (preferred)
        rendered_name = None
        if video_name.endswith('.npz'):
            rendered_name = video_name
        else:
            # Backward compatibility: map source name to rendered
            rendered_name = get_video_name_from_source(video_name)
            if not rendered_name:
                return jsonify({'error': f'No rendered version found for {video_name}'}), 404

        rendered_path = rendered_videos_dir / rendered_name
        if not rendered_path.exists():
            return jsonify({'error': f'Rendered video not found: {rendered_name}'}), 404
        
        # Stop any current playback
        stop_current_playback()
        
        # Start new playback in a thread
        playback_active = True
        current_video_name = video_name
        playback_thread = threading.Thread(
            target=play_video_thread,
            args=(str(rendered_path), loop, 1.0, brightness, playback_fps),
            daemon=True
        )
        playback_thread.start()
        
        return jsonify({
            'status': 'playing',
            'video': video_name,
            'rendered_file': rendered_name
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/stop', methods=['POST'])
def stop_playback():
    """Stop current playback."""
    try:
        stop_current_playback()
        return jsonify({'status': 'stopped'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/status', methods=['GET'])
def get_status():
    """Get current playback status."""
    return jsonify({
        'playing': playback_active,
        'video': current_video_name,
    })


@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint."""
    return jsonify({'status': 'ok'})


@app.route('/api/game/join', methods=['POST'])
def game_join():
    """
    Register a player for a game.
    Request body: {"player_id": "uuid-123", "phone_id": "AlicePhone", "game": "tetris"}
    Response: {"status": "ok", "player_id": "...", "count": 1} or error if game is full.
    """
    try:
        data = request.json
        player_id = data.get('player_id')
        phone_id = data.get('phone_id', player_id)
        game = data.get('game', 'tetris')

        if not player_id:
            return jsonify({'error': 'Missing player_id'}), 400

        # Attempt to join
        log(f"Player {phone_id} ({player_id}) attempting to join {game}", module="API")
        success = join_game(player_id, phone_id=phone_id, game=game)
        if not success:
            log(f"Failed: Game {game} is full", level='WARNING', module="API")
            return jsonify({'error': f'Game "{game}" is full'}), 403

        # Return active players for this game
        players = get_active_players_for_game(game)
        log(f"🎮 {game.upper()} JOINED - Player: {phone_id} | Total players: {len(players)} | Player index: {len(players) - 1}", module="API")
        return jsonify({
            'status': 'ok',
            'player_id': player_id,
            'game': game,
            'player_count': len(players),
            'player_index': len(players) - 1,  # 0-indexed position
        }), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/game/leave', methods=['POST'])
def game_leave():
    """
    Remove a player from their game.
    Request body: {"player_id": "uuid-123"}
    """
    try:
        data = request.json or {}
        player_id = data.get('player_id')

        if not player_id:
            return jsonify({'error': 'Missing player_id'}), 400

        game = get_game_for_player(player_id)
        if game is None:
            log(f"⚠️  LEAVE - Player {player_id} not found in registry, already left?", module="API")
            return jsonify({'status': 'ok', 'player_id': player_id, 'message': 'Player not in any game'}), 200
        
        count_before = player_count_for_game(game)
        log(f"👋 PLAYER LEFT - Player: {player_id} | Game: {game} | Players before: {count_before}", module="API")
        leave_game(player_id)
        count_after = player_count_for_game(game)
        log(f"   Removed! Players after: {count_after}", module="API")
        return jsonify({'status': 'ok', 'player_id': player_id}), 200

    except Exception as e:
        log(f"❌ Error in game_leave: {e}\n{traceback.format_exc()}", level='ERROR', module="API")
        return jsonify({'error': str(e), 'traceback': traceback.format_exc()}), 500


@app.route('/api/game/heartbeat', methods=['POST'])
def game_heartbeat():
    """
    Keep-alive ping from a player. Call this periodically to prevent timeout.
    Also routes any input command to the player registry.
    Request body: {"player_id": "uuid-123", "cmd": "MOVE_LEFT", ...}
    """
    try:
        from game_players import get_game_for_player
        from players import handle_input

        data = request.json
        player_id = data.get('player_id')

        if not player_id:
            return jsonify({'error': 'Missing player_id'}), 400

        # Ensure the player is joined so per-game handlers are bound
        current_game = get_game_for_player(player_id)
        if current_game is None:
            # Auto-join to tetris if not already tracked
            join_game(player_id, phone_id=player_id, game='tetris')
            current_game = 'tetris'

        # Update heartbeat
        heartbeat(player_id)

        # If there's a command, route it to the player registry
        if 'cmd' in data:
            from game_players import get_game_for_player as get_player_game
            player_game = get_player_game(player_id)
            # Normalize command for consistent routing
            raw_cmd = data.get('cmd', 'UNKNOWN')
            cmd = raw_cmd.strip().upper()
            # Map common variants to expected command names
            if cmd in ("DROP", "DROP_HARD", "HARD"):  # allow Flutter variations
                cmd = "HARD_DROP"
            data['cmd'] = cmd

            log(f"🕹️  BUTTON PRESS - Player: {player_id} | Game: {player_game} | Command: {cmd}", module="API")
            handle_input(player_id, data)

        game = get_game_for_player(player_id)
        return jsonify({'status': 'ok', 'player_id': player_id, 'game': game}), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/game/status', methods=['GET'])
def game_status():
    """
    Get current game status (active players, availability).
    Query params: ?game=tetris
    """
    try:
        from game_players import player_count_for_game

        game = request.args.get('game', 'tetris')
        count = player_count_for_game(game)
        players = get_active_players_for_game(game)
        full = is_game_full(game)

        return jsonify({
            'game': game,
            'player_count': count,
            'is_full': full,
            'players': [
                {'player_id': p.player_id, 'phone_id': p.phone_id, 'index': i}
                for i, p in enumerate(players)
            ],
        }), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/game/state', methods=['GET'])
def game_state():
    """
    Get current game state for a player (score, level, lines, etc.).
    Query params: ?game=tetris&player_id=uuid-123
    """
    try:
        from game_players import get_player_data

        game = request.args.get('game', 'tetris')
        player_id = request.args.get('player_id')

        if not player_id:
            return jsonify({'error': 'Missing player_id'}), 400

        # Fetch player data from the game state
        player_data = get_player_data(player_id)
        
        if not player_data:
            # Return default state if player not found
            return jsonify({
                'status': 'ok',
                'player_id': player_id,
                'game': game,
                'score': 0,
                'level': 1,
                'lines': 0,
            }), 200

        return jsonify({
            'status': 'ok',
            'player_id': player_id,
            'game': game,
            'score': player_data.get('score', 0),
            'level': player_data.get('level', 1),
            'lines': player_data.get('lines', 0),
        }), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/test/solid', methods=['POST'])
def test_solid():
    try:
        data = request.get_json(silent=True) or {}
        r = int(data.get('r', data.get('red', 255)))
        g = int(data.get('g', data.get('green', 0)))
        b = int(data.get('b', data.get('blue', 0)))
        matrix = initialize_matrix()
        if getattr(matrix, 'fpp', None):
            ms = matrix.fpp.write_solid(r, g, b)
            return jsonify({'status': 'ok', 'ms': ms, 'rgb': [r, g, b]})
        return jsonify({'error': 'FPP output not enabled'}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/test/black', methods=['POST'])
def test_black():
    try:
        matrix = initialize_matrix()
        if getattr(matrix, 'fpp', None):
            ms = matrix.fpp.write_solid(0, 0, 0)
            return jsonify({'status': 'ok', 'ms': ms})
        return jsonify({'error': 'FPP output not enabled'}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def cleanup():
    """Cleanup function to be called on shutdown."""
    global current_matrix, cleanup_active
    cleanup_active = False
    stop_current_playback()
    if current_matrix:
        current_matrix.shutdown()


def cleanup_idle_loop():
    """Background thread that periodically removes idle players."""
    from game_players import cleanup_idle_players
    
    while cleanup_active:
        try:
            cleanup_idle_players()
            time.sleep(5)  # Check every 5 seconds
        except Exception as e:
            print(f"Error in cleanup loop: {e}")


def start_cleanup_thread():
    """Start the background cleanup thread."""
    global cleanup_thread, cleanup_active
    if cleanup_thread and cleanup_thread.is_alive():
        return
    cleanup_active = True
    cleanup_thread = threading.Thread(target=cleanup_idle_loop, daemon=True)
    cleanup_thread.start()


if __name__ == '__main__':
    import atexit
    atexit.register(cleanup)
    
    # Start background cleanup thread for idle players
    start_cleanup_thread()
    
    # Run the Flask server
    print("Starting Flask API server on port 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)

