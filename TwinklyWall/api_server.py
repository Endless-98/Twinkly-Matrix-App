"""
Flask API server for controlling the LED matrix video playback.
Provides REST endpoints for the Flutter app to communicate with.
"""

import os
import tempfile
import threading
import time
import traceback
import subprocess
from pathlib import Path
from werkzeug.utils import secure_filename
from flask import Flask, jsonify, request, send_file
from flask_cors import CORS
from dotmatrix import DotMatrix
from video_player import VideoPlayer
from video_renderer import VideoRenderer
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
# Global render progress tracking: {filename: {'progress': 0.0-1.0, 'status': 'rendering'/'complete'/'error'}}
render_progress = {}
MEDIA_ROOT = Path("/home/fpp/TwinklyWall_Project/media")
TMP_UPLOAD_DIR = MEDIA_ROOT / "tmp_uploads"
rendered_videos_dir = MEDIA_ROOT / "rendered"
source_videos_dir = Path("assets/source_videos")
uploaded_videos_dir = MEDIA_ROOT / "uploads"

# Ensure media directories live on the large (219GB) partition, not /tmp
os.makedirs(rendered_videos_dir, exist_ok=True)
os.makedirs(uploaded_videos_dir, exist_ok=True)
os.makedirs(TMP_UPLOAD_DIR, exist_ok=True)

# Force werkzeug/tempfile to use the large partition for request temp files
os.environ["TMPDIR"] = str(TMP_UPLOAD_DIR)
tempfile.tempdir = str(TMP_UPLOAD_DIR)

# Upload configuration
ALLOWED_EXTENSIONS = {'mp4', 'avi', 'mov', 'mkv', 'flv', 'wmv'}
MAX_UPLOAD_SIZE = 500 * 1024 * 1024  # 500 MB

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
    """Get list of available rendered videos (.npz) with thumbnail information."""
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
                # Check if thumbnail exists
                thumbnail_path = file.with_suffix('.png')
                thumbnail_exists = thumbnail_path.exists()
                
                videos.append({
                    'filename': file.name,
                    'has_thumbnail': thumbnail_exists,
                    'thumbnail': f'/api/video/{file.stem}/thumbnail' if thumbnail_exists else None,
                })

        # Sort by filename
        videos.sort(key=lambda x: x['filename'])
        return jsonify({'videos': videos})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>', methods=['DELETE'])
def delete_video(filename):
    """Delete a specific video file.
    
    Args:
        filename: Name of the video file to delete (must end with .npz)
    """
    try:
        # Security: Only allow .npz files to be deleted
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type. Only .npz files can be deleted.'}), 400
        
        # Construct the file path
        file_path = rendered_videos_dir / filename
        
        # Check if file exists
        if not file_path.exists():
            return jsonify({'error': f'Video not found: {filename}'}), 404
        
        # If this video is currently playing, stop playback first
        global current_video_name
        if current_video_name == filename:
            stop_playback()
            log(f"Stopped playback of {filename} before deletion", module="API")
        
        # Delete the file
        file_path.unlink()
        log(f"Deleted video: {filename}", module="API")
        
        return jsonify({
            'success': True,
            'message': f'Video {filename} deleted successfully'
        }), 200
        
    except Exception as e:
        log(f"Delete video error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/video/<video_stem>/thumbnail', methods=['GET'])
def get_video_thumbnail(video_stem):
    """Get thumbnail image for a video (PNG format)."""
    try:
        # Find the thumbnail file (should be .png with same stem as .npz)
        thumbnail_path = rendered_videos_dir / f"{video_stem}.png"
        
        if not thumbnail_path.exists():
            return jsonify({'error': 'Thumbnail not found'}), 404
        
        # Return the image file
        return send_file(thumbnail_path, mimetype='image/png')
    except Exception as e:
        log(f"Get thumbnail error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/meta', methods=['GET'])
def get_video_metadata(filename):
    """Return basic metadata for a rendered video (.npz)."""
    try:
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            return jsonify({'error': 'Video not found'}), 404

        # Load minimal metadata
        data = np.load(file_path)
        frames = data['frames']
        fps = float(data['fps']) if 'fps' in data else 20.0
        height, width = frames.shape[1], frames.shape[2]
        duration = len(frames) / fps if fps > 0 else 0

        return jsonify({
            'width': int(width),
            'height': int(height),
            'fps': fps,
            'frames': int(len(frames)),
            'duration': duration,
        })
    except Exception as e:
        log(f"Metadata error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/trim', methods=['POST'])
def trim_rendered_video(filename):
    """Trim an existing rendered video (.npz) and save as a new file."""
    try:
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            return jsonify({'error': 'Video not found'}), 404

        data = request.json or {}
        start_time = data.get('start_time')
        end_time = data.get('end_time')
        output_name = data.get('output_name')

        if start_time is None or end_time is None:
            return jsonify({'error': 'start_time and end_time are required'}), 400

        arr = np.load(file_path)
        frames = arr['frames']
        fps = float(arr['fps']) if 'fps' in arr else 20.0

        total_frames = len(frames)
        start_frame = max(0, min(int(start_time * fps), total_frames - 1))
        end_frame = max(start_frame + 1, min(int(end_time * fps), total_frames))

        trimmed = frames[start_frame:end_frame]

        if output_name:
            if not output_name.endswith('.npz'):
                output_name += '.npz'
        else:
            stem = Path(filename).stem
            output_name = f"{stem}_trim_{start_frame}-{end_frame}.npz"

        output_path = rendered_videos_dir / output_name
        np.savez_compressed(
            output_path,
            frames=trimmed,
            fps=fps,
            width=arr['width'] if 'width' in arr else trimmed.shape[2],
            height=arr['height'] if 'height' in arr else trimmed.shape[1],
            source_video=arr['source_video'] if 'source_video' in arr else filename,
        )

        log(f"Trimmed {filename} -> {output_name} ({len(trimmed)} frames)", module="API")

        return jsonify({
            'status': 'trimmed',
            'filename': output_name,
            'frames': len(trimmed),
        })
    except Exception as e:
        log(f"Trim error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/rename', methods=['POST'])
def rename_rendered_video(filename):
    """Rename an existing rendered video (.npz)."""
    try:
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            return jsonify({'error': 'Video not found'}), 404

        data = request.json or {}
        new_name = data.get('new_name')
        if not new_name:
            return jsonify({'error': 'new_name is required'}), 400

        if not new_name.endswith('.npz'):
            new_name += '.npz'

        new_path = rendered_videos_dir / new_name
        if new_path.exists():
            return jsonify({'error': 'Target filename already exists'}), 400

        file_path.rename(new_path)
        log(f"Renamed {filename} -> {new_name}", module="API")

        return jsonify({'status': 'renamed', 'filename': new_name})
    except Exception as e:
        log(f"Rename error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


def allowed_file(filename):
    """Check if file has an allowed extension."""
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS


@app.route('/api/upload', methods=['POST'])
def upload_video():
    """Upload a video file from mobile app.
    
    Form data:
    - file: video file
    - render_fps: (optional) target FPS for rendering (20 or 40, default 20)
    """
    try:
        # Check if file is present
        if 'file' not in request.files:
            return jsonify({'error': 'No file provided'}), 400
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({'error': 'Empty filename'}), 400
        
        if not allowed_file(file.filename):
            return jsonify({'error': f'File type not allowed. Allowed: {", ".join(ALLOWED_EXTENSIONS)}'}), 400
        
        # Secure the filename
        filename = secure_filename(file.filename)
        upload_path = uploaded_videos_dir / filename
        
        # Check file size
        file.seek(0, os.SEEK_END)
        file_size = file.tell()
        file.seek(0)
        
        if file_size > MAX_UPLOAD_SIZE:
            return jsonify({'error': f'File too large. Max size: {MAX_UPLOAD_SIZE / (1024*1024):.0f} MB'}), 413
        
        # Save uploaded file directly to avoid /tmp buffering on large files
        with open(upload_path, 'wb') as f:
            while True:
                chunk = file.read(8192)  # Read in 8KB chunks
                if not chunk:
                    break
                f.write(chunk)
        
        log(f"Video uploaded: {filename} ({file_size / (1024*1024):.2f} MB)", module="API")
        
        # Get render FPS from request (default 20)
        render_fps = request.form.get('render_fps', 20, type=int)
        if render_fps not in [20, 40]:
            render_fps = 20
        
        return jsonify({
            'status': 'uploaded',
            'filename': filename,
            'size_mb': round(file_size / (1024*1024), 2),
            'render_fps': render_fps,
            'next_step': 'Call /api/render to process the video'
        }), 201
        
    except Exception as e:
        log(f"Upload error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


def render_video_thread(video_path, render_fps, start_time=None, end_time=None, crop_rect=None, output_name=None):
    """Thread function to render an uploaded video."""
    filename = Path(video_path).name
    # Use output_name for progress tracking if provided, otherwise use input filename
    progress_key = output_name if output_name else filename
    
    try:
        renderer = VideoRenderer()
        log(f"Starting render: {video_path} at {render_fps} FPS", module="API")
        if start_time or end_time:
            log(f"  Trim: {start_time}s to {end_time}s", module="API")
        if crop_rect:
            log(f"  Crop: {crop_rect}", module="API")
        if output_name:
            log(f"  Output name: {output_name}", module="API")
        
        # Define progress callback
        def progress_callback(current_frame, total_frames):
            if progress_key in render_progress:
                render_progress[progress_key]['progress'] = current_frame / total_frames if total_frames > 0 else 0.0
        
        # Render the video with trim/crop parameters
        output_path = renderer.render_video(
            video_path, 
            output_fps=render_fps,
            start_time=start_time,
            end_time=end_time,
            crop_rect=crop_rect,
            output_name=output_name,
            progress_callback=progress_callback
        )
        
        if output_path:
            log(f"Render complete: {output_path}", module="API")
            # Mark as complete
            if progress_key in render_progress:
                render_progress[progress_key]['progress'] = 1.0
                render_progress[progress_key]['status'] = 'complete'
            # Delete the original uploaded video
            try:
                os.remove(video_path)
                log(f"Deleted uploaded video: {video_path}", module="API")
            except Exception as e:
                log(f"Failed to delete uploaded video {video_path}: {e}", level='WARNING', module="API")
        else:
            log(f"Render failed for: {video_path}", level='ERROR', module="API")
            if progress_key in render_progress:
                render_progress[progress_key]['status'] = 'error'
            
    except Exception as e:
        log(f"Render thread error: {e}", level='ERROR', module="API")
        if progress_key in render_progress:
            render_progress[progress_key]['status'] = 'error'


@app.route('/api/render', methods=['POST'])
def render_uploaded_video():
    """Render an uploaded video asynchronously.
    
    JSON body:
    - filename: name of uploaded file
    - render_fps: target FPS (20 or 40, default 20)
    - start_time: (optional) start time in seconds
    - end_time: (optional) end time in seconds
    - crop_left, crop_top, crop_right, crop_bottom: (optional) crop rectangle in normalized 0-1 coordinates
    - output_name: (optional) custom name for the output file
    """
    try:
        data = request.json
        filename = data.get('filename')
        render_fps = data.get('render_fps', 20)
        start_time = data.get('start_time')
        end_time = data.get('end_time')
        output_name = data.get('output_name')
        
        # Extract crop parameters if provided
        crop_rect = None
        if all(k in data for k in ['crop_left', 'crop_top', 'crop_right', 'crop_bottom']):
            crop_rect = (
                float(data['crop_left']),
                float(data['crop_top']),
                float(data['crop_right']),
                float(data['crop_bottom'])
            )
        
        if not filename:
            return jsonify({'error': 'No filename specified'}), 400
        
        if render_fps not in [20, 40]:
            render_fps = 20
        
        # Verify file exists
        video_path = uploaded_videos_dir / filename
        if not video_path.exists():
            return jsonify({'error': f'Uploaded video not found: {filename}'}), 404
        
        # Ensure output_name has .npz extension if provided
        if output_name and not output_name.endswith('.npz'):
            output_name = f'{output_name}.npz'
        
        # Initialize progress tracking using output_name if provided, otherwise use input filename
        progress_key = output_name if output_name else filename
        render_progress[progress_key] = {'progress': 0.0, 'status': 'rendering'}
        
        # Start rendering in background thread
        render_thread = threading.Thread(
            target=render_video_thread,
            args=(str(video_path), render_fps, start_time, end_time, crop_rect, output_name),
            daemon=True
        )
        render_thread.start()
        
        log(f"Render job queued: {filename} at {render_fps} FPS", module="API")
        
        return jsonify({
            'status': 'rendering',
            'filename': progress_key,
            'render_fps': render_fps,
            'message': 'Video is being rendered in the background. It will appear in /api/videos once complete.'
        }), 202
        
        return jsonify({
            'status': 'rendering',
            'filename': filename,
            'render_fps': render_fps,
            'message': 'Video is being rendered in the background. It will appear in /api/videos once complete.'
        }), 202
        
    except Exception as e:
        log(f"Render request error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/render/progress/<filename>', methods=['GET'])
def get_render_progress(filename):
    """Get rendering progress for a specific file.
    
    Returns:
        JSON with 'progress' (0.0-1.0), 'status' ('rendering'/'complete'/'error'/'not_found')
    """
    if filename in render_progress:
        return jsonify(render_progress[filename]), 200
    else:
        return jsonify({'progress': 0.0, 'status': 'not_found'}), 404


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


@app.route('/api/youtube/download', methods=['POST'])
def download_youtube_video():
    """Download a video from YouTube using yt-dlp.
    
    JSON body:
    - url: YouTube video URL
    """
    try:
        data = request.json or {}
        url = data.get('url')
        
        if not url:
            return jsonify({'error': 'No URL provided'}), 400
        
        # Validate it's a YouTube URL
        if 'youtube.com' not in url and 'youtu.be' not in url:
            return jsonify({'error': 'Invalid YouTube URL'}), 400
        
        # Use yt-dlp to download the video
        try:
            import yt_dlp
        except ImportError:
            return jsonify({'error': 'yt-dlp not installed. Install with: pip install yt-dlp'}), 500
        
        # Download to uploaded_videos directory
        output_template = str(uploaded_videos_dir / '%(title)s.%(ext)s')
        
        # Configure yt-dlp with fallbacks for various YouTube streaming methods
        ydl_opts = {
            'format': 'best[ext=mp4][height<=720]/best[height<=720]/best',
            'outtmpl': output_template,
            'quiet': False,
            'no_warnings': False,
            'socket_timeout': 30,
            'http_headers': {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            },
            'extractor_args': {
                'youtube': {
                    'skip': ['dash', 'hls'],  # Skip DASH/HLS formats that require JS extraction
                }
            }
        }
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            filename = ydl.prepare_filename(info)
            filepath = Path(filename)
            
            # Sanitize filename by replacing problematic Unicode chars
            # Some YouTube titles use fancy Unicode quotes and slashes that cause issues
            safe_name = filepath.name.replace('＂', '"').replace('⧸', '-').replace('"', "'")
            safe_name = secure_filename(safe_name)
            safe_filepath = filepath.parent / safe_name
            
            # Rename if needed
            if filepath != safe_filepath and filepath.exists():
                filepath.rename(safe_filepath)
                filepath = safe_filepath
        
        log(f"Downloaded from YouTube: {filepath.name}", module="API")
        
        return jsonify({
            'status': 'downloaded',
            'filename': filepath.name,
            'url': f'/api/video/{filepath.name}',  # Serve file via HTTP endpoint
            'size_mb': filepath.stat().st_size / (1024*1024),
        }), 200
        
    except Exception as e:
        log(f"YouTube download error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/video/<filename>', methods=['GET'])
def serve_video(filename):
    """Serve a video file from the uploads directory."""
    try:
        # The filename is already sanitized on upload, just validate it's safe
        filename = secure_filename(filename)
        filepath = uploaded_videos_dir / filename
        
        # Check file exists and is actually a video
        if not filepath.exists() or not filepath.is_file():
            log(f"Video not found: {filename}", level='WARNING', module="API")
            return jsonify({'error': 'Video not found'}), 404
        
        log(f"Serving video: {filename}", module="API")
        
        # Use send_file with streaming for large videos
        from flask import send_file
        return send_file(
            str(filepath),
            mimetype='video/mp4',
            as_attachment=False,  # Display inline in browser/player
        )
    except Exception as e:
        log(f"Video serving error: {e}", level='ERROR', module="API")
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

