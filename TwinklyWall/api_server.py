"""
Flask API server for controlling the LED matrix video playback.
Provides REST endpoints for the Flutter app to communicate with.
"""

import os
import threading
import time
from pathlib import Path
from flask import Flask, jsonify, request
from flask_cors import CORS
from dotmatrix import DotMatrix
from video_player import VideoPlayer

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
    global current_matrix
    stop_current_playback()
    if current_matrix:
        current_matrix.shutdown()


if __name__ == '__main__':
    import atexit
    atexit.register(cleanup)
    
    # Run the Flask server
    print("Starting Flask API server on port 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
