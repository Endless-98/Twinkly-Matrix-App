"""Flask API server for controlling the LED matrix video playback.

Provides REST endpoints for the Flutter app to communicate with.
"""

import atexit
import datetime
import io
import json
import os
import tempfile
import threading
import time
import traceback
import uuid
from collections import OrderedDict
from pathlib import Path
from urllib.parse import unquote

import numpy as np
try:
    import cv2
    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False
from werkzeug.utils import secure_filename
from flask import Flask, jsonify, request, send_file
from flask_cors import CORS

from dotmatrix import DotMatrix
from playlist_player import PlaylistPlayer
from transitions import TRANSITION_NAMES
from video_player import VideoPlayer
from video_renderer import VideoRenderer
from game_players import (
    cleanup_idle_players, get_active_players_for_game,
    get_game_for_player, get_player_data, heartbeat,
    is_game_full, join_game, leave_game,
    player_count_for_game,
)
from logger import log
from players import handle_input
from idle_pattern import IdlePattern
# NOTE: twinkly_controller is NOT imported and NOT used at runtime.
# fppd's Twinkly.cpp channel output (subtype=8 in co-universes.json) manages
# auth tokens, rt mode, and keepalive natively.  Any external HTTP login to
# /xled/v1/login INVALIDATES fppd's token, causing frame data rejection.

app = Flask(__name__)
CORS(app)  # Enable CORS for Flutter web app

# Global state
current_player = None
current_matrix = None
playback_thread = None
playback_active = False
current_video_name = None
idle_animation = None  # IdlePattern instance (runs when nothing else is active)
# Stop signal shared across all playback threads — checked during load() and play()
_stop_event = threading.Event()
# Generation counter: incremented on every play request.  Threads compare their
# generation against the global to detect when a newer play has superseded them.
_playback_generation = 0
# Lock protecting the play/stop cycle so concurrent API requests don't interleave
_playback_lock = threading.Lock()
# Live color-preview params: set by recolor_preview when adjusting the currently
# playing video so each rendered frame has adjustments applied on-the-fly.
_live_preview_params = None   # dict or None
_live_preview_filename = None  # str or None
# Global render progress tracking: {filename: {'progress': 0.0-1.0, 'status': 'rendering'/'complete'/'error'}}
render_progress = {}
MEDIA_ROOT = Path("/home/fpp/TwinklyWall_Project/media")
TMP_UPLOAD_DIR = MEDIA_ROOT / "tmp_uploads"
rendered_videos_dir = MEDIA_ROOT / "rendered"
source_videos_dir = Path("assets/source_videos")
uploaded_videos_dir = MEDIA_ROOT / "uploads"
playlists_dir = MEDIA_ROOT / "playlists"
schedules_dir = MEDIA_ROOT / "schedules"
smart_schedules_path = MEDIA_ROOT / "smart_schedules.json"

# Ensure media directories live on the large (219GB) partition, not /tmp
os.makedirs(rendered_videos_dir, exist_ok=True)
os.makedirs(uploaded_videos_dir, exist_ok=True)
os.makedirs(TMP_UPLOAD_DIR, exist_ok=True)
os.makedirs(playlists_dir, exist_ok=True)
os.makedirs(schedules_dir, exist_ok=True)

# Migrate any .npz/.png files from the legacy dotmatrix/rendered_videos/ dir
# into the canonical rendered_videos_dir so there is one source of truth.
_legacy_rendered_dir = Path(__file__).parent / 'dotmatrix' / 'rendered_videos'
if _legacy_rendered_dir.exists():
    import shutil as _shutil
    for _legacy_file in _legacy_rendered_dir.iterdir():
        if _legacy_file.is_file() and _legacy_file.suffix.lower() in ('.npz', '.png'):
            _dest = rendered_videos_dir / _legacy_file.name
            if not _dest.exists():
                _shutil.copy2(str(_legacy_file), str(_dest))
                print(f"[MIGRATE] Moved {_legacy_file.name} → {rendered_videos_dir}", flush=True)

# Force werkzeug/tempfile to use the large partition for request temp files
os.environ["TMPDIR"] = str(TMP_UPLOAD_DIR)
tempfile.tempdir = str(TMP_UPLOAD_DIR)

# Upload configuration
ALLOWED_EXTENSIONS = {'mp4', 'avi', 'mov', 'mkv', 'flv', 'wmv'}
MAX_UPLOAD_SIZE = 500 * 1024 * 1024  # 500 MB

# Cleanup thread for idle players
cleanup_thread = None
cleanup_active = False

# Small in-memory cache to avoid reloading .npz frames for every frame request
RENDERED_CACHE_MAX = 2
rendered_frames_cache: OrderedDict[str, dict] = OrderedDict()
rendered_frames_cache_lock = threading.Lock()


def _apply_live_preview_to_frame(frame_uint8):
    """Apply current _live_preview_params to a uint8 frame; returns uint8 array.
    Called per-frame from VideoPlayer/PlaylistPlayer while live color preview is active."""
    params = _live_preview_params
    if params is None:
        return frame_uint8
    brightness = params.get('brightness', 0.0)
    contrast   = params.get('contrast', 1.0)
    hue        = params.get('hue', 0.0)
    saturation = params.get('saturation', 1.0)
    frame = frame_uint8.astype(np.float32)
    if brightness != 0.0:
        frame = np.clip(frame + brightness, 0.0, 255.0)
    if contrast != 1.0:
        frame = np.clip(128.0 + (frame - 128.0) * contrast, 0.0, 255.0)
    if (hue != 0.0 or saturation != 1.0) and HAS_CV2:
        bgr = cv2.cvtColor(frame.astype(np.uint8), cv2.COLOR_RGB2BGR)
        hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV).astype(np.float32)
        if hue != 0.0:
            hsv[:, :, 0] = (hsv[:, :, 0] + hue / 2.0) % 180.0
        if saturation != 1.0:
            hsv[:, :, 1] = np.clip(hsv[:, :, 1] * saturation, 0.0, 255.0)
        bgr2 = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR)
        frame = cv2.cvtColor(bgr2, cv2.COLOR_BGR2RGB).astype(np.float32)
    return np.clip(frame, 0, 255).astype(np.uint8)


def _get_cached_rendered_frames(file_path: Path):
    """Load frames from disk once and serve from a tiny LRU cache."""
    cache_key = str(file_path.resolve())

    with rendered_frames_cache_lock:
        cached = rendered_frames_cache.get(cache_key)
        if cached:
            rendered_frames_cache.move_to_end(cache_key)
            return cached["frames"]

    data = None
    try:
        try:
            data = np.load(file_path, mmap_mode='r')
        except ValueError:
            data = np.load(file_path)
        frames = data['frames']
    except Exception:
        if data is not None and hasattr(data, 'close'):
            try:
                data.close()
            except Exception:
                pass
        raise

    with rendered_frames_cache_lock:
        rendered_frames_cache[cache_key] = {"frames": frames, "data": data}
        rendered_frames_cache.move_to_end(cache_key)
        while len(rendered_frames_cache) > RENDERED_CACHE_MAX:
            old_key, old_entry = rendered_frames_cache.popitem(last=False)
            try:
                old_data = old_entry.get("data")
                if hasattr(old_data, 'close'):
                    old_data.close()
            except Exception as cache_err:
                log(f"Frame cache close error for {old_key}: {cache_err}", level='WARNING', module="API")

    return frames


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
        on_pi = False
        try:
            with open('/proc/device-tree/model', 'r') as f:
                on_pi = 'raspberry pi' in f.read().lower()
        except Exception:
            pass

        use_fpp_output = on_pi or bool(os.environ.get("FPP_MODEL_NAME"))
        headless = use_fpp_output or ('DISPLAY' not in os.environ)
        fpp_memory_file = _resolve_fpp_memory_file()

        fpp_gamma_val = 1.0  # No software gamma — Twinkly controllers handle their own
        fpp_color_order = "RGB"
        log(f"DotMatrix init: fpp={use_fpp_output}, headless={headless}, "
            f"gamma={fpp_gamma_val}, color_order={fpp_color_order}, mmap={fpp_memory_file}",
            module="MATRIX")

        current_matrix = DotMatrix(
            headless=headless,
            fpp_output=use_fpp_output,
            show_source_preview=True,
            enable_performance_monitor=True,
            disable_blending=True,
            supersample=1,
            fpp_gamma=fpp_gamma_val,
            fpp_color_order=fpp_color_order,
            fpp_memory_buffer_file=fpp_memory_file,
        )
        log(f"DotMatrix created OK (fpp={use_fpp_output})", module="MATRIX")
    return current_matrix


def _start_idle():
    """Release the FPP overlay so fppd stops forwarding our mmap data.

    With overlay state 0 and no sequence playing, fppd sends zero packets
    (confirmed by packet capture).  Twinkly controllers exit RT mode after
    ~3 s of silence; fppd re-enters RT mode autonomously on resume without
    the ~60 s backoff that happens when external code invalidates its token.
    """
    global idle_animation
    if idle_animation:
        idle_animation.stop()
        idle_animation = None
    try:
        from frame_buffer import clear_background
        clear_background()
    except ImportError:
        pass
    try:
        m = current_matrix
        if m and getattr(m, 'fpp', None):
            m.fpp.release_overlay()
    except Exception as e:
        log(f"Failed to release FPP overlay: {e}", level='WARNING', module="Idle")
    log("Overlay released — fppd sends nothing while idle", module="Idle")


def _stop_idle():
    """Stop any idle animation (no-op in current design — kept for compatibility)."""
    global idle_animation
    if idle_animation:
        idle_animation.stop()
        idle_animation = None


def stop_current_playback():
    """Stop the current playback if any.  Blocks until the playback thread exits."""
    global playback_active, current_player, playback_thread, current_video_name
    global _live_preview_params, _live_preview_filename

    _stop_idle()

    # Signal stop to any running playback (including threads still in load())
    _stop_event.set()
    playback_active = False
    current_video_name = None
    _live_preview_params = None
    _live_preview_filename = None

    if current_player:
        current_player.stop()
        current_player = None

    # Wait for the thread to actually finish — up to 5s (covers slow .npz loads)
    t = playback_thread
    if t is not None and t.is_alive():
        t.join(timeout=5)
        if t.is_alive():
            log("[STOP] Playback thread did not exit in 5s — abandoning it (daemon)",
                level="WARNING", module="PLAYBACK")
    playback_thread = None
    # Overlay stays in state 3 — set_dark() is called by _start_idle() / stop_playback()
    # to zero the mmap (lights dark) without dropping Twinkly RT mode.


def play_video_thread(video_path, loop, speed, brightness, playback_fps, generation, repeat_count: int = 0):
    """Thread function to play video.  Checks _stop_event during load and play."""
    global current_player, current_matrix, playback_active

    try:
        import time as _time
        _t0 = _time.monotonic()

        log(f"[VIDEO_THREAD] Starting video playback: {video_path}",
            level='INFO', module="PLAYBACK")
        matrix = initialize_matrix()
        log(f"[VIDEO_THREAD] Matrix initialized, FPP output: "
            f"{bool(getattr(matrix, 'fpp', None))} ({(_time.monotonic()-_t0)*1000:.0f}ms)",
            level='INFO', module="PLAYBACK")

        # Bail out if stop was requested while we were setting up
        if _stop_event.is_set():
            log("[VIDEO_THREAD] Stop requested before play started",
                level='INFO', module="PLAYBACK")
            return

        # Enable FPP overlay — fppd re-enters Twinkly RT mode autonomously.
        # We never call /xled/v1/login, so fppd's token is never invalidated;
        # re-auth completes in < 2 s (fppd's own login, not a 60 s backoff).
        if getattr(matrix, 'fpp', None):
            matrix.fpp.acquire_overlay()
            # Log mmap contents immediately after overlay acquire so we can see
            # what was in the buffer before the first frame is written
            try:
                fpp_path = _resolve_fpp_memory_file()
                with open(fpp_path, 'rb') as _f:
                    _raw = _f.read(12)
                import numpy as _np2
                _arr = _np2.frombuffer(open(fpp_path, 'rb').read(), dtype=_np2.uint8)
                log(f"[VIDEO_THREAD] mmap after overlay acquire: first12={_raw.hex()} "
                    f"max={int(_arr.max())} mean={float(_arr.mean()):.1f} nonzero={int(_np2.count_nonzero(_arr))}",
                    module="PLAYBACK")
                log(f"[VIDEO_THREAD] FPP settings: gamma={matrix.fpp.gamma} "
                    f"color_order={matrix.fpp.color_order} "
                    f"routing_entries={len(getattr(matrix.fpp,'_fast_dest',[]))}",
                    module="PLAYBACK")
            except Exception as _diag_e:
                log(f"[VIDEO_THREAD] mmap post-acquire diagnostic error: {_diag_e}", module="PLAYBACK")

        player = VideoPlayer(matrix, stop_event=_stop_event)
        player.color_override = _apply_live_preview_to_frame
        current_player = player

        log(f"[VIDEO_THREAD] Playing: {video_path}", level='INFO', module="PLAYBACK")
        log(f"[VIDEO_THREAD] Settings: Loop={loop}, Speed={speed}, "
            f"Brightness={brightness}, FPS={playback_fps}",
            level='INFO', module="PLAYBACK")

        # Play the video — player checks its own _stop flag each frame
        # repeat_count>0 overrides loop: play exactly N times then stop
        if repeat_count > 0:
            frames = player.play(
                video_path,
                loop=False,
                repeat=repeat_count,
                speed=speed,
                start_frame=0,
                end_frame=None,
                brightness=brightness,
                playback_fps=playback_fps,
            )
        else:
            frames = player.play(
                video_path,
                loop=loop,
                speed=speed,
                start_frame=0,
                end_frame=None,
                brightness=brightness,
                playback_fps=playback_fps,
            )

        log(f"[VIDEO_THREAD] Playback complete: {frames} frames",
            level='INFO', module="PLAYBACK")

    except Exception as e:
        log(f"Error during playback: {e}\n{traceback.format_exc()}",
            level='ERROR', module="PLAYBACK")
    finally:
        current_player = None
        # Only enter idle if THIS thread is still the active generation
        # (i.e. no newer play request superseded us).  This prevents the
        # old thread from releasing the overlay that a new thread just acquired.
        if _playback_generation == generation and playback_active:
            playback_active = False
            _start_idle()


def play_playlist_thread(entries, loop, brightness, playback_fps, transition_duration, generation, repeat_count: int = 0):
    """Thread function to play a playlist with transitions."""
    global current_player, current_matrix, playback_active

    try:
        log(f"[PLAYLIST_THREAD] Starting playlist ({len(entries)} entries)",
            level='INFO', module="PLAYBACK")
        matrix = initialize_matrix()

        if _stop_event.is_set():
            log("[PLAYLIST_THREAD] Stop requested before play started",
                level='INFO', module="PLAYBACK")
            return

        # Enable FPP overlay — fppd re-enters RT mode autonomously (mirrors VIDEO_THREAD).
        if getattr(matrix, 'fpp', None):
            matrix.fpp.acquire_overlay()

        player = PlaylistPlayer(matrix, rendered_videos_dir, stop_event=_stop_event)
        player.color_override = _apply_live_preview_to_frame
        current_player = player

        frames = player.play(
            entries=entries,
            loop=loop if repeat_count == 0 else False,
            repeat_count=repeat_count,
            brightness=brightness,
            playback_fps=playback_fps,
            transition_duration=transition_duration,
        )

        log(f"[PLAYLIST_THREAD] Playback complete: {frames} frames",
            level='INFO', module="PLAYBACK")

    except Exception as e:
        log(f"Error during playlist playback: {e}\n{traceback.format_exc()}",
            level='ERROR', module="PLAYBACK")
    finally:
        current_player = None
        if _playback_generation == generation and playback_active:
            playback_active = False
            _start_idle()


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
                videos.append({
                    'filename': file.name,
                    'has_thumbnail': True,  # endpoint auto-generates from first frame
                    'thumbnail': f'/api/video/{file.stem}/thumbnail',
                })

        # Sort by filename
        videos.sort(key=lambda x: x['filename'])
        return jsonify({'videos': videos})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>', methods=['DELETE'])
def delete_video(filename):
    """Delete a specific video file and its thumbnail.
    
    Args:
        filename: Name of the video file to delete (must end with .npz)
    """
    try:
        filename = unquote(filename)
        
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
        
        # Delete the video file
        file_path.unlink()
        log(f"Deleted video: {filename}", module="API")
        
        # Also delete the thumbnail if it exists
        thumbnail_path = file_path.with_suffix('.png')
        if thumbnail_path.exists():
            thumbnail_path.unlink()
            log(f"Deleted thumbnail: {thumbnail_path.name}", module="API")
        
        return jsonify({
            'success': True,
            'message': f'Video {filename} deleted successfully'
        }), 200
        
    except Exception as e:
        log(f"Delete video error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/video/<video_stem>/thumbnail', methods=['GET'])
def get_video_thumbnail(video_stem):
    """Get thumbnail image for a video (PNG or JPG format).

    Priority:
    1. PNG thumbnail in rendered_videos_dir (generated from first frame)
    2. JPG thumbnail in rendered_videos_dir (copied from YouTube source)
    3. JPG thumbnail in uploaded_videos_dir (downloaded alongside YouTube video)
    4. Auto-generate from first frame of .npz if cv2 available
    """
    try:
        png_path = rendered_videos_dir / f"{video_stem}.png"
        jpg_path = rendered_videos_dir / f"{video_stem}.jpg"
        upload_jpg_path = uploaded_videos_dir / f"{video_stem}.jpg"
        video_path = rendered_videos_dir / f"{video_stem}.npz"

        # If no PNG yet, try to promote a YouTube JPG thumbnail
        if not png_path.exists():
            # Check jpg in rendered dir (copied during render)
            if jpg_path.exists():
                return send_file(str(jpg_path), mimetype='image/jpeg')
            # Check jpg in uploads dir (downloaded alongside YouTube video)
            if upload_jpg_path.exists():
                return send_file(str(upload_jpg_path), mimetype='image/jpeg')

            # Fall back to generating from first frame
            if video_path.exists() and HAS_CV2:
                try:
                    data = np.load(video_path)
                    frames = data['frames']
                    if len(frames) > 0:
                        first_frame = frames[0]  # RGB format
                        bgr_frame = cv2.cvtColor(first_frame, cv2.COLOR_RGB2BGR)
                        cv2.imwrite(str(png_path), bgr_frame)
                        log(f"Generated missing thumbnail: {png_path.name}", module="API")
                except Exception as gen_e:
                    log(f"Failed to generate thumbnail for {video_stem}: {gen_e}", level='WARNING', module="API")

        if not png_path.exists():
            return jsonify({'error': 'Thumbnail not found'}), 404

        # Return the PNG file
        return send_file(str(png_path), mimetype='image/png')
    except Exception as e:
        log(f"Get thumbnail error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/preview', methods=['GET'])
def get_video_preview(filename):
    """Return an MP4 preview of a rendered .npz video, upscaled for viewing."""
    try:
        filename = unquote(filename)
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            fallback_path = Path(__file__).parent / 'dotmatrix' / 'rendered_videos' / filename
            if fallback_path.exists():
                file_path = fallback_path
            else:
                return jsonify({'error': 'Video not found'}), 404

        # Cache in a previews directory
        preview_dir = rendered_videos_dir / '.previews'
        preview_dir.mkdir(exist_ok=True)
        preview_path = preview_dir / (Path(filename).stem + '.mp4')

        # Rebuild if source is newer
        if preview_path.exists() and preview_path.stat().st_mtime >= file_path.stat().st_mtime:
            return send_file(str(preview_path), mimetype='video/mp4')

        if not HAS_CV2:
            return jsonify({'error': 'cv2 not available'}), 500

        arr = np.load(file_path)
        frames = arr['frames']
        fps = float(arr['fps']) if 'fps' in arr else 20.0

        # Upscale for viewability (each LED pixel → 8×8 block)
        scale = 8
        h, w = frames.shape[1], frames.shape[2]
        out_w, out_h = w * scale, h * scale

        tmp_path = str(preview_path) + '.tmp.mp4'
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        writer = cv2.VideoWriter(tmp_path, fourcc, fps, (out_w, out_h))
        try:
            for i in range(len(frames)):
                # Apply the same contrast + saturation boost used at playback time
                arr_f = frames[i].astype(np.float32)
                arr_f = np.clip(128.0 + (arr_f - 128.0) * 1.15, 0.0, 255.0)
                luma = arr_f[:, :, 0:1] * 0.299 + arr_f[:, :, 1:2] * 0.587 + arr_f[:, :, 2:3] * 0.114
                arr_f = np.clip(luma + (arr_f - luma) * 1.4, 0.0, 255.0)
                frame_rgb = arr_f.astype(np.uint8)
                bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)
                big = cv2.resize(bgr, (out_w, out_h), interpolation=cv2.INTER_NEAREST)
                writer.write(big)
        finally:
            writer.release()

        # Atomic rename
        os.replace(tmp_path, str(preview_path))
        log(f"Generated preview: {preview_path.name} ({len(frames)} frames)", module="API")

        return send_file(str(preview_path), mimetype='video/mp4')
    except Exception as e:
        log(f"Preview error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/meta', methods=['GET'])
def get_video_metadata(filename):
    """Return basic metadata for a rendered video (.npz)."""
    try:
        filename = unquote(filename)
        
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        # Try multiple possible locations for the file
        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            return jsonify({'error': f'Video not found: {filename}'}), 404

        # Load minimal metadata
        data = np.load(file_path)
        frames = data['frames']
        fps = float(data['fps']) if 'fps' in data else 20.0
        
        # Handle different frame array shapes (N, H, W, 3) or (H, W, 3, N)
        if frames.ndim == 4:
            if frames.shape[3] == 3:
                # Shape is (N, H, W, 3)
                height, width = frames.shape[1], frames.shape[2]
            else:
                # Shape is (H, W, 3, N) or similar - try to infer
                height, width = frames.shape[0], frames.shape[1]
        else:
            # Unexpected shape, try to extract H, W
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
        log(f"Metadata error for {filename}: {e}", level='ERROR', module="API")
        log(f"Traceback: {traceback.format_exc()}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/trim', methods=['POST'])
def trim_rendered_video(filename):
    """Trim an existing rendered video (.npz) and save as a new file."""
    try:
        filename = unquote(filename)
        
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            fallback_path = Path(__file__).parent / 'dotmatrix' / 'rendered_videos' / filename
            if fallback_path.exists():
                file_path = fallback_path
            else:
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

        # Save thumbnail from first frame of trimmed video
        try:
            thumbnail_path = output_path.with_suffix('.png')
            first_frame = trimmed[0]
            bgr_frame = cv2.cvtColor(first_frame, cv2.COLOR_RGB2BGR)
            cv2.imwrite(str(thumbnail_path), bgr_frame)
            log(f"Thumbnail saved: {thumbnail_path}", module="API")
        except Exception as thumb_e:
            log(f"Warning: Failed to save thumbnail: {thumb_e}", level='WARNING', module="API")

        log(f"Trimmed {filename} -> {output_name} ({len(trimmed)} frames)", module="API")

        return jsonify({
            'status': 'trimmed',
            'filename': output_name,
            'frames': len(trimmed),
        })
    except Exception as e:
        log(f"Trim error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/recolor', methods=['POST'])
def recolor_rendered_video(filename):
    """Apply color adjustments (brightness/contrast/hue/saturation) to a rendered video.

    The original frames are preserved in a ``_original`` key inside the .npz so
    subsequent re-edits always start from the pristine source.

    JSON body:
    - brightness: float, additive offset -100..+100 (0 = no change)
    - contrast:   float, multiplier 0.5..2.0 (1.0 = no change)
    - hue:        float, degrees -180..+180 (0 = no change)
    - saturation: float, multiplier 0.0..3.0 (1.0 = no change)
    """
    try:
        filename = unquote(filename)
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            return jsonify({'error': f'Video not found: {filename}'}), 404

        if not HAS_CV2:
            return jsonify({'error': 'cv2 not available on server'}), 500

        data = request.json or {}
        brightness = float(data.get('brightness', 0.0))
        contrast   = float(data.get('contrast', 1.0))
        hue        = float(data.get('hue', 0.0))
        saturation = float(data.get('saturation', 1.0))

        arr = np.load(file_path, allow_pickle=False)
        # Use original frames as the recolor source if available
        original_frames = arr['original_frames'] if 'original_frames' in arr else arr['frames']
        fps = float(arr['fps']) if 'fps' in arr else 20.0

        # Process frame-by-frame to avoid allocating a full float32 copy of all
        # frames at once (e.g. 13k frames × 50×90×3 × 4 bytes ≈ 677 MB).
        apply_brightness = brightness != 0.0
        apply_contrast = contrast != 1.0
        apply_hsv = hue != 0.0 or saturation != 1.0

        n = len(original_frames)
        result_frames = np.empty_like(original_frames, dtype=np.uint8)
        for i in range(n):
            frame = original_frames[i].astype(np.float32)
            if apply_brightness:
                frame = np.clip(frame + brightness, 0.0, 255.0)
            if apply_contrast:
                frame = np.clip(128.0 + (frame - 128.0) * contrast, 0.0, 255.0)
            if apply_hsv:
                bgr = cv2.cvtColor(frame.astype(np.uint8), cv2.COLOR_RGB2BGR)
                hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV).astype(np.float32)
                if hue != 0.0:
                    hsv[:, :, 0] = (hsv[:, :, 0] + hue / 2.0) % 180.0
                if saturation != 1.0:
                    hsv[:, :, 1] = np.clip(hsv[:, :, 1] * saturation, 0.0, 255.0)
                bgr2 = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR)
                frame = cv2.cvtColor(bgr2, cv2.COLOR_BGR2RGB).astype(np.float32)
            result_frames[i] = np.clip(frame, 0, 255).astype(np.uint8)

        # Save — preserve original_frames for future recolors
        # Exclude 'fps' from extra to avoid duplicate keyword argument
        extra = {}
        for key in arr.files:
            if key not in ('frames', 'original_frames', 'fps'):
                extra[key] = arr[key]

        np.savez_compressed(
            file_path,
            frames=result_frames,
            original_frames=original_frames.astype(np.uint8),
            fps=fps,
            **extra,
        )

        # Regenerate thumbnail from first frame
        try:
            thumb_path = file_path.with_suffix('.png')
            bgr = cv2.cvtColor(result_frames[0], cv2.COLOR_RGB2BGR)
            cv2.imwrite(str(thumb_path), bgr)
        except Exception as te:
            log(f"Recolor thumbnail error: {te}", level='WARNING', module="API")

        log(f"Recolored {filename}: brightness={brightness:+.0f}, contrast={contrast:.2f}x, "
            f"hue={hue:+.0f}°, sat={saturation:.2f}x", module="API")

        return jsonify({'status': 'recolored', 'filename': filename, 'frames': len(result_frames)})
    except Exception as e:
        log(f"Recolor error: {e}\n{traceback.format_exc()}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/recolor_preview', methods=['POST'])
def recolor_preview(filename):
    """Color-adjustment preview.

    Two modes:
    - If the video is currently playing solo → update _live_preview_params so
      every rendered frame picks up the adjustments in real-time (no interruption).
    - Otherwise → pause current playback and push a single middle frame to the wall.

    Pass {"clear": true} to clear any live preview (called on Cancel / Apply).
    """
    global _live_preview_params, _live_preview_filename
    try:
        filename = unquote(filename)
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        data = request.json or {}

        # --- Clear request (sent when dialog is closed) ---
        if data.get('clear'):
            _live_preview_params = None
            _live_preview_filename = None
            return jsonify({'status': 'preview_cleared'})

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            return jsonify({'error': f'Video not found: {filename}'}), 404

        if not HAS_CV2:
            return jsonify({'error': 'cv2 not available on server'}), 500

        brightness = float(data.get('brightness', 0.0))
        contrast   = float(data.get('contrast', 1.0))
        hue        = float(data.get('hue', 0.0))
        saturation = float(data.get('saturation', 1.0))

        # --- Live preview: video is already playing → inject params into the render loop ---
        if current_video_name == filename and playback_active:
            _live_preview_params = {
                'brightness': brightness,
                'contrast': contrast,
                'hue': hue,
                'saturation': saturation,
            }
            _live_preview_filename = filename
            return jsonify({'status': 'live_preview_active'})

        # --- Static preview: different (or no) video playing → stop and show one frame ---
        # Clear any stale live params first
        _live_preview_params = None
        _live_preview_filename = None

        # Stop current playback so the wall is free for us to write to
        with _playback_lock:
            stop_current_playback()
            _stop_event.clear()

        arr = np.load(file_path, allow_pickle=False)
        original_frames = arr['original_frames'] if 'original_frames' in arr else arr['frames']

        # Use the middle frame for a representative preview
        frame = original_frames[len(original_frames) // 2].astype(np.float32)

        if brightness != 0.0:
            frame = np.clip(frame + brightness, 0.0, 255.0)
        if contrast != 1.0:
            frame = np.clip(128.0 + (frame - 128.0) * contrast, 0.0, 255.0)
        if hue != 0.0 or saturation != 1.0:
            bgr = cv2.cvtColor(frame.astype(np.uint8), cv2.COLOR_RGB2BGR)
            hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV).astype(np.float32)
            if hue != 0.0:
                hsv[:, :, 0] = (hsv[:, :, 0] + hue / 2.0) % 180.0
            if saturation != 1.0:
                hsv[:, :, 1] = np.clip(hsv[:, :, 1] * saturation, 0.0, 255.0)
            bgr2 = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR)
            frame = cv2.cvtColor(bgr2, cv2.COLOR_BGR2RGB).astype(np.float32)

        result_frame = np.clip(frame, 0, 255).astype(np.uint8)

        # Write via FPPOutput so the routing table (Light Wall Mapping) is applied
        try:
            m = current_matrix
            if m is not None and getattr(m, 'fpp', None) is not None:
                m.fpp.acquire_overlay()
                m.fpp.write(result_frame)
            else:
                from dotmatrix.fpp_output import FPPOutput
                fpp_path = _resolve_fpp_memory_file()
                fpp_tmp = FPPOutput(
                    width=90, height=50,
                    mapping_file=fpp_path,
                    color_order='RGB',
                    gamma=None,
                )
                fpp_tmp.write(result_frame)
        except Exception as write_err:
            log(f"recolor_preview write failed: {write_err}", level='WARNING', module="API")
            return jsonify({'error': f'preview write failed: {write_err}'}), 500

        return jsonify({'status': 'preview_pushed'})
    except Exception as e:
        log(f"recolor_preview error: {e}\n{traceback.format_exc()}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/rename', methods=['POST'])
def rename_rendered_video(filename):
    """Rename an existing rendered video (.npz) and its thumbnail."""
    try:
        filename = unquote(filename)
        
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

        # Rename the video file
        file_path.rename(new_path)
        
        # Also rename the thumbnail if it exists
        old_thumbnail = file_path.with_suffix('.png')
        if old_thumbnail.exists():
            new_thumbnail = new_path.with_suffix('.png')
            old_thumbnail.rename(new_thumbnail)
            log(f"Renamed thumbnail {old_thumbnail.name} -> {new_thumbnail.name}", module="API")
        
        log(f"Renamed {filename} -> {new_name}", module="API")

        return jsonify({'status': 'renamed', 'filename': new_name})
    except Exception as e:
        log(f"Rename error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/videos/<filename>/frame/<int:frame_index>', methods=['GET'])
def get_rendered_video_frame(filename, frame_index):
    """Get a single frame from a rendered video (.npz) as a PNG image."""
    try:
        filename = unquote(filename)
        
        if not filename.endswith('.npz'):
            return jsonify({'error': 'Invalid file type'}), 400

        file_path = rendered_videos_dir / filename
        if not file_path.exists():
            fallback_path = Path(__file__).parent / 'dotmatrix' / 'rendered_videos' / filename
            if fallback_path.exists():
                file_path = fallback_path
            else:
                log(f"Frame request 404: {filename} not found in {rendered_videos_dir} or {fallback_path}", level='WARNING', module="API")
                return jsonify({'error': f'Video not found: {filename}'}), 404

        # Load the video data once and reuse it (reduces repeated 90MB allocations)
        try:
            frames = _get_cached_rendered_frames(file_path)
        except MemoryError as mem_err:
            log(f"Frame load memory error for {filename}: {mem_err}", level='ERROR', module="API")
            return jsonify({'error': 'Server is low on memory loading frames'}), 500
        
        # Validate frame index
        if frame_index < 0 or frame_index >= len(frames):
            return jsonify({'error': f'Frame index {frame_index} out of range (0-{len(frames)-1})'}), 400
        
        # Get the frame (RGB format)
        frame = frames[frame_index]
        
        # Convert RGB to BGR for cv2
        bgr_frame = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
        
        # Encode as PNG
        success, buffer = cv2.imencode('.png', bgr_frame)
        if not success:
            return jsonify({'error': 'Failed to encode frame'}), 500
        
        # Return as image
        return send_file(
            io.BytesIO(buffer.tobytes()),
            mimetype='image/png',
            as_attachment=False,
            download_name=f'{filename}_frame_{frame_index}.png'
        )
    except Exception as e:
        log(f"Get frame error: {e}", level='ERROR', module="API")
        log(f"Traceback: {traceback.format_exc()}", level='ERROR', module="API")
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


def render_video_thread(video_path, render_fps, start_time=None, end_time=None, crop_rect=None, output_name=None,
                        brightness=0.0, contrast=1.0, hue=0.0):
    """Thread function to render an uploaded video."""
    filename = Path(video_path).name
    # Use output_name for progress tracking if provided, otherwise use input filename
    progress_key = output_name if output_name else filename
    
    log(f"render_video_thread called with: output_name={output_name}, progress_key={progress_key}", module="API")
    
    try:
        renderer = VideoRenderer()
        log(f"Starting render: {video_path} at {render_fps} FPS", module="API")
        if start_time or end_time:
            log(f"  Trim: {start_time}s to {end_time}s", module="API")
        if crop_rect:
            log(f"  Crop: {crop_rect}", module="API")
        if output_name:
            log(f"  Output name: {output_name}", module="API")
        if brightness != 0.0 or contrast != 1.0 or hue != 0.0:
            log(f"  Color: brightness={brightness:+.0f}, contrast={contrast:.2f}x, hue={hue:+.0f}°", module="API")
        
        # Define progress callback with frame counts for UI display
        def progress_callback(current_frame, total_frames):
            if progress_key in render_progress:
                render_progress[progress_key]['progress'] = current_frame / total_frames if total_frames > 0 else 0.0
                render_progress[progress_key]['frames_rendered'] = current_frame
                render_progress[progress_key]['total_frames'] = total_frames
        
        # Render the video with trim/crop parameters
        output_path = renderer.render_video(
            video_path, 
            output_fps=render_fps,
            start_time=start_time,
            end_time=end_time,
            crop_rect=crop_rect,
            output_name=output_name,
            progress_callback=progress_callback,
            brightness=brightness,
            contrast=contrast,
            hue=hue,
        )
        
        if output_path:
            log(f"Render complete: {output_path}", module="API")
            # Mark as complete
            if progress_key in render_progress:
                render_progress[progress_key]['progress'] = 1.0
                render_progress[progress_key]['status'] = 'complete'

            # Copy YouTube thumbnail (.jpg from uploads dir) → rendered dir if no .png yet
            try:
                import shutil as _shutil
                rendered_stem = Path(output_path).stem
                rendered_png = Path(output_path).with_suffix('.png')
                upload_stem = Path(video_path).stem
                upload_jpg = uploaded_videos_dir / f"{upload_stem}.jpg"
                if upload_jpg.exists() and not rendered_png.exists():
                    dest_jpg = Path(output_path).with_suffix('.jpg')
                    _shutil.copy2(str(upload_jpg), str(dest_jpg))
                    log(f"Copied YouTube thumbnail → {dest_jpg.name}", module="API")
            except Exception as te:
                log(f"Thumbnail copy error: {te}", level='WARNING', module="API")

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
        brightness = float(data.get('brightness', 0.0))
        contrast = float(data.get('contrast', 1.0))
        hue = float(data.get('hue', 0.0))
        
        log(f"Render request: filename={filename}, output_name={output_name}, fps={render_fps}", module="API")
        
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
        render_progress[progress_key] = {
            'progress': 0.0,
            'status': 'rendering',
            'frames_rendered': 0,
            'total_frames': 0,
            'output_name': output_name or filename
        }
        
        # Start rendering in background thread
        render_thread = threading.Thread(
            target=render_video_thread,
            args=(str(video_path), render_fps, start_time, end_time, crop_rect, output_name),
            kwargs={'brightness': brightness, 'contrast': contrast, 'hue': hue},
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
        
    except Exception as e:
        log(f"Render request error: {e}", level='ERROR', module="API")
        return jsonify({'error': str(e)}), 500


@app.route('/api/render/progress/<filename>', methods=['GET'])
def get_render_progress(filename):
    """Get rendering progress for a specific file.
    
    Returns:
        JSON with 'progress' (0.0-1.0), 'status' ('rendering'/'complete'/'error'/'not_found')
    """
    filename = unquote(filename)
    
    if filename in render_progress:
        return jsonify(render_progress[filename]), 200
    else:
        return jsonify({'progress': 0.0, 'status': 'not_found'}), 404


@app.route('/api/play', methods=['POST'])
def play_video():
    """Start playing a video."""
    global playback_active, playback_thread, current_video_name, _playback_generation
    
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
        
        with _playback_lock:
            # Stop any current playback (and idle pattern) — blocks until old thread exits
            stop_current_playback()
            
            # Clear the stop signal so the new thread can run
            _stop_event.clear()
            
            # Bump generation so any lingering old thread won't enter idle
            _playback_generation += 1
            gen = _playback_generation
            
            # Start new playback in a thread
            playback_active = True
            current_video_name = video_name
            playback_thread = threading.Thread(
                target=play_video_thread,
                args=(str(rendered_path), loop, 1.0, brightness, playback_fps, gen),
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
        with _playback_lock:
            stop_current_playback()
            _start_idle()
        return jsonify({'status': 'stopped'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/status', methods=['GET'])
def get_status():
    """Get current playback status."""
    brightness = None
    if current_player:
        brightness = getattr(current_player, 'brightness', None)
    return jsonify({
        'playing': playback_active,
        'video': current_video_name,
        'brightness': brightness,
    })


@app.route('/api/health', methods=['GET'])
def health_check():
    """Diagnostic endpoint — verifies the mmap → fppd pipeline is live."""
    import struct, urllib.request as _ureq, json as _json2
    diag = {'mmap': False, 'overlay': False, 'matrix': bool(current_matrix)}
    try:
        fpp_path = _resolve_fpp_memory_file()
        if os.path.exists(fpp_path):
            diag['mmap'] = True
            diag['mmap_path'] = fpp_path
            diag['mmap_size'] = os.path.getsize(fpp_path)
            diag['mmap_writable'] = os.access(fpp_path, os.W_OK)
            with open(fpp_path, 'rb') as f:
                raw = f.read()
            if raw:
                import numpy as _np
                arr = _np.frombuffer(raw, dtype=_np.uint8)
                diag['mmap_max'] = int(arr.max())
                diag['mmap_mean'] = round(float(arr.mean()), 1)
                diag['mmap_nonzero'] = int(_np.count_nonzero(arr))
                diag['mmap_first12_hex'] = raw[:12].hex()

        if current_matrix and getattr(current_matrix, 'fpp', None):
            fpp = current_matrix.fpp
            diag['overlay'] = True
            diag['overlay_model'] = getattr(fpp, '_overlay_model_name', 'unknown')
            diag['gamma'] = fpp.gamma
            diag['color_order'] = fpp.color_order
            diag['routing_entries'] = int(len(fpp._fast_dest)) if fpp._fast_dest is not None else 0
            diag['frames_written'] = getattr(fpp, '_write_count', 0)

        # Check FPP overlay state via HTTP
        try:
            model = diag.get('overlay_model', 'Light_Wall')
            url = f'http://localhost/api/overlays/model/{model}'
            with _ureq.urlopen(url, timeout=2) as resp:
                ov = _json2.loads(resp.read().decode())
            diag['fpp_overlay_state'] = ov.get('State', ov.get('isActive', '?'))
        except Exception as _oe:
            diag['fpp_overlay_state'] = f'(query failed: {_oe})'

        diag['playback_active'] = playback_active
        diag['current_video'] = current_video_name

    except Exception as e:
        diag['error'] = str(e)
    return jsonify(diag)


@app.route('/api/brightness', methods=['POST'])
def set_brightness():
    """Set brightness dynamically during playback.
    
    Request body: {"brightness": 1.0}  # Range: 0.05 to 2.0 (5% to 200%)
    """
    global current_player
    try:
        data = request.json or {}
        brightness = data.get('brightness')
        
        if brightness is None:
            return jsonify({'error': 'Missing brightness value'}), 400
        
        brightness = float(brightness)
        if brightness < 0.05 or brightness > 2.0:
            return jsonify({'error': 'Brightness must be between 0.05 and 2.0 (5% to 200%)'}), 400
        
        if current_player:
            current_player.brightness = brightness
            print(f"[API] Brightness set to {brightness:.2f} ({brightness*100:.0f}%)")
            return jsonify({'status': 'ok', 'brightness': brightness})
        else:
            return jsonify({'error': 'No active playback'}), 400
            
    except ValueError:
        return jsonify({'error': 'Invalid brightness value'}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------------------------------------
# Playlist CRUD & playback
# ---------------------------------------------------------------------------

def _load_playlist(name: str) -> dict | None:
    path = playlists_dir / f"{name}.json"
    if not path.exists():
        return None
    with open(path, 'r') as f:
        content = f.read()
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        # Recover from concurrent-write corruption (extra / truncated data).
        # Try to extract the first valid JSON object and repair the file.
        try:
            data, _ = json.JSONDecoder().raw_decode(content.lstrip())
            if isinstance(data, dict):
                _save_playlist(name, data)   # repair on disk
                return data
        except Exception:
            pass
        return None


def _save_playlist(name: str, data: dict):
    path = playlists_dir / f"{name}.json"
    # Write to a temp file then rename — atomic on POSIX, prevents readers
    # from ever seeing a partially-written file.
    tmp = path.with_suffix('.tmp')
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
    tmp.rename(path)


def _sanitize_playlist_name(name: str) -> str:
    return secure_filename(name).rsplit('.', 1)[0] or 'untitled'


@app.route('/api/playlists', methods=['GET'])
def list_playlists():
    """Return all saved playlists."""
    try:
        playlists = []
        for p in sorted(playlists_dir.glob('*.json')):
            data = _load_playlist(p.stem)
            if data is None:
                continue
            playlists.append({
                'name': p.stem,
                'entries': data.get('entries', []),
                'transition_duration': data.get('transition_duration', 1.0),
                'color': data.get('color', '#42A5F5'),
                'play_duration': data.get('play_duration', 5.0),
                'shuffle': data.get('shuffle', False),
            })
        return jsonify({'playlists': playlists})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/playlists', methods=['POST'])
def create_playlist():
    """Create a new playlist.

    Body: {"name": "My Playlist", "entries": [{"video": "a.npz", "transition": "fade"}, ...],
           "transition_duration": 1.0}
    """
    try:
        data = request.json or {}
        raw_name = data.get('name', '').strip()
        if not raw_name:
            return jsonify({'error': 'Missing playlist name'}), 400
        name = _sanitize_playlist_name(raw_name)
        if (playlists_dir / f"{name}.json").exists():
            return jsonify({'error': f'Playlist "{name}" already exists'}), 409
        entries = data.get('entries', [])
        playlist_data = {
            'entries': entries,
            'transition_duration': float(data.get('transition_duration', 1.0)),
            'color': data.get('color', '#42A5F5'),
        }
        _save_playlist(name, playlist_data)
        return jsonify({'status': 'created', 'name': name}), 201
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/playlists/<name>', methods=['GET'])
def get_playlist(name):
    """Get a single playlist by name."""
    name = _sanitize_playlist_name(unquote(name))
    data = _load_playlist(name)
    if data is None:
        return jsonify({'error': f'Playlist not found: {name}'}), 404
    return jsonify({'name': name, **data})


@app.route('/api/playlists/<name>', methods=['PUT'])
def update_playlist(name):
    """Update an existing playlist (entries, transition_duration, play_duration, shuffle, color)."""
    try:
        name = _sanitize_playlist_name(unquote(name))
        if not (playlists_dir / f"{name}.json").exists():
            return jsonify({'error': f'Playlist not found: {name}'}), 404
        data = request.json or {}
        existing = _load_playlist(name) or {}
        if 'entries' in data:
            existing['entries'] = data['entries']
        if 'transition_duration' in data:
            existing['transition_duration'] = float(data['transition_duration'])
        if 'color' in data:
            existing['color'] = data['color']
        if 'play_duration' in data:
            existing['play_duration'] = float(data['play_duration'])
        if 'shuffle' in data:
            existing['shuffle'] = bool(data['shuffle'])
        _save_playlist(name, existing)
        return jsonify({'status': 'updated', 'name': name})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/playlists/<name>', methods=['DELETE'])
def delete_playlist(name):
    """Delete a playlist."""
    name = _sanitize_playlist_name(unquote(name))
    path = playlists_dir / f"{name}.json"
    if not path.exists():
        return jsonify({'error': f'Playlist not found: {name}'}), 404
    path.unlink()
    return jsonify({'status': 'deleted', 'name': name})


@app.route('/api/playlist/play', methods=['POST'])
def play_playlist():
    """Play a saved playlist.

    Body: {"name": "My Playlist", "loop": true, "brightness": 1.0, "playback_fps": 20}
    """
    global playback_active, playback_thread, current_video_name, _playback_generation

    try:
        data = request.json or {}
        raw_name = data.get('name', '').strip()
        if not raw_name:
            return jsonify({'error': 'Missing playlist name'}), 400
        name = _sanitize_playlist_name(raw_name)
        playlist_data = _load_playlist(name)
        if playlist_data is None:
            return jsonify({'error': f'Playlist not found: {name}'}), 404

        entries = playlist_data.get('entries', [])
        if not entries:
            return jsonify({'error': 'Playlist is empty'}), 400

        loop = data.get('loop', False)
        brightness = data.get('brightness', None)
        playback_fps = data.get('playback_fps', 20.0)
        transition_duration = playlist_data.get('transition_duration', 1.0)
        folder_play_duration = playlist_data.get('play_duration', 0)
        shuffle = playlist_data.get('shuffle', False)

        # Inject folder-level play_duration as default for entries that have none
        resolved_entries = []
        for entry in entries:
            e = dict(entry)
            if 'duration' not in e or not e['duration']:
                # loop_count overrides duration: play full video N times
                loop_count = int(e.get('loop_count', 0))
                if loop_count > 0:
                    e['loop_count'] = loop_count
                    e['duration'] = 0  # playlist player handles loop_count
                elif folder_play_duration:
                    e['duration'] = folder_play_duration
            resolved_entries.append(e)

        if shuffle:
            import random as _random
            _random.shuffle(resolved_entries)

        with _playback_lock:
            stop_current_playback()
            _stop_event.clear()
            _playback_generation += 1
            gen = _playback_generation

            playback_active = True
            current_video_name = f"playlist:{name}"
            playback_thread = threading.Thread(
                target=play_playlist_thread,
                args=(resolved_entries, loop, brightness, playback_fps, transition_duration, gen),
                daemon=True,
            )
            playback_thread.start()

        return jsonify({'status': 'playing', 'playlist': name, 'entries': len(entries)})

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/transitions', methods=['GET'])
def list_transitions():
    """Return available transition types."""
    return jsonify({'transitions': TRANSITION_NAMES})


@app.route('/api/game/join', methods=['POST'])
def game_join():
    """
    Register a player for a game.
    Request body: {"player_id": "uuid-123", "phone_id": "AlicePhone", "game": "tetris", "gamemode_selection": 0}
    Response: {"status": "ok", "player_id": "...", "count": 1} or error if game is full.
    """
    try:
        data = request.json
        player_id = data.get('player_id')
        phone_id = data.get('phone_id', player_id)
        game = data.get('game', 'tetris')
        gamemode_selection = data.get('gamemode_selection', 0)

        if not player_id:
            return jsonify({'error': 'Missing player_id'}), 400

        # Attempt to join
        log(f"Player {phone_id} ({player_id}) attempting to join {game} with gamemode {gamemode_selection}", module="API")
        success = join_game(player_id, phone_id=phone_id, game=game, gamemode_selection=gamemode_selection)
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
        data = request.json
        player_id = data.get('player_id')

        if not player_id:
            return jsonify({'error': 'Missing player_id'}), 400

        current_game = get_game_for_player(player_id)
        if current_game is None:
            join_game(player_id, phone_id=player_id, game='tetris')
            current_game = 'tetris'

        heartbeat(player_id)

        if 'cmd' in data:
            player_game = get_game_for_player(player_id)
            cmd = data.get('cmd', 'UNKNOWN').strip().upper()
            if cmd in ("DROP", "DROP_HARD", "HARD"):
                cmd = "HARD_DROP"
            data['cmd'] = cmd

            log(f"BUTTON PRESS - Player: {player_id} | Game: {player_game} | Command: {cmd}", level='DEBUG', module="API")
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
        game = request.args.get('game', 'tetris')
        count = player_count_for_game(game)
        players_list = get_active_players_for_game(game)
        full = is_game_full(game)

        return jsonify({
            'game': game,
            'player_count': count,
            'is_full': full,
            'players': [
                {'player_id': p.player_id, 'phone_id': p.phone_id, 'index': i}
                for i, p in enumerate(players_list)
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
    """Write a solid color to the LED wall and HOLD the overlay active.
    
    Acquires the FPP overlay (state 3) then writes the color.
    Call /api/stop to release the overlay afterward.
    Also reads back from mmap to confirm the write succeeded.
    """
    try:
        data = request.get_json(silent=True) or {}
        r = int(data.get('r', data.get('red', 255)))
        g = int(data.get('g', data.get('green', 0)))
        b = int(data.get('b', data.get('blue', 0)))
        matrix = initialize_matrix()
        if getattr(matrix, 'fpp', None):
            # CRITICAL: must acquire overlay (state 3) so fppd forwards our mmap data
            matrix.fpp.acquire_overlay()
            ms = matrix.fpp.write_solid(r, g, b)
            # Read back from mmap to verify the write made it through
            readback_stats = {}
            try:
                import numpy as _np
                fpp_path = _resolve_fpp_memory_file()
                raw = open(fpp_path, 'rb').read()
                arr = _np.frombuffer(raw, dtype=_np.uint8)
                readback_stats = {
                    'mmap_max': int(arr.max()),
                    'mmap_mean': round(float(arr.mean()), 1),
                    'mmap_nonzero': int(_np.count_nonzero(arr)),
                    'mmap_first12_hex': raw[:12].hex(),
                }
                log(f"[TEST_SOLID] rgb=({r},{g},{b}) mmap: max={readback_stats['mmap_max']} "
                    f"mean={readback_stats['mmap_mean']} "
                    f"nonzero={readback_stats['mmap_nonzero']}/13500 "
                    f"first12={readback_stats['mmap_first12_hex']}", module="API")
            except Exception as _rb:
                readback_stats['readback_error'] = str(_rb)
            return jsonify({'status': 'ok', 'ms': ms, 'rgb': [r, g, b],
                            'overlay': 'acquired (state 3)', **readback_stats})
        return jsonify({'error': 'FPP output not enabled'}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/test/black', methods=['POST'])
def test_black():
    try:
        matrix = initialize_matrix()
        if getattr(matrix, 'fpp', None):
            matrix.fpp.acquire_overlay()
            ms = matrix.fpp.write_solid(0, 0, 0)
            return jsonify({'status': 'ok', 'ms': ms})
        return jsonify({'error': 'FPP output not enabled'}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/twinkly/rt', methods=['POST'])
def twinkly_rt():
    """DISABLED — calling Twinkly HTTP API invalidates fppd's auth tokens.

    fppd manages rt mode natively via Twinkly.cpp (subtype=8).
    If lights are dark, restart fppd: sudo systemctl restart fppd
    """
    return jsonify({
        'error': 'Disabled — fppd manages Twinkly auth tokens natively. '
                 'Calling /xled/v1/login from Python invalidates fppd tokens. '
                 'Restart fppd instead: sudo systemctl restart fppd',
        'action': 'restart_fppd',
    }), 409


@app.route('/api/debug/pipeline', methods=['GET'])
def debug_pipeline():
    """Full pipeline diagnostic — shows every stage from matrix→mmap→fppd→controllers.

    Call this while the wall appears dark to capture all relevant state.
    The response is also printed to the service log for journalctl review.
    """
    import struct, glob

    diag = {}

    # ── 1. Matrix / FPPOutput settings ───────────────────────────────────────
    try:
        matrix = initialize_matrix()
        fpp = getattr(matrix, 'fpp', None)
        if fpp:
            diag['matrix'] = {
                'gamma': fpp.gamma,
                'color_order': fpp.color_order,
                'channel_gains': list(fpp.channel_gains),
                'width': fpp.width,
                'height': fpp.height,
                'buffer_size': fpp.buffer_size,
                'routing_entries': int(len(fpp._fast_dest)) if fpp._fast_dest is not None else 0,
                'mmap_open': fpp.memory_map is not None,
            }
            if fpp._fast_dest is not None and len(fpp._fast_dest) > 0:
                diag['matrix']['routing_dest_min'] = int(fpp._fast_dest.min())
                diag['matrix']['routing_dest_max'] = int(fpp._fast_dest.max())
        else:
            diag['matrix'] = {'error': 'FPP output not initialised'}
    except Exception as e:
        diag['matrix'] = {'error': str(e)}

    # ── 2. mmap file stats (raw, before any overlay state change) ───────────
    try:
        fpp_path = _resolve_fpp_memory_file()
        diag['mmap'] = {'path': fpp_path, 'exists': os.path.exists(fpp_path)}
        if os.path.exists(fpp_path):
            diag['mmap']['size'] = os.path.getsize(fpp_path)
            diag['mmap']['writable'] = os.access(fpp_path, os.W_OK)
            raw = open(fpp_path, 'rb').read()
            import numpy as _np
            arr = _np.frombuffer(raw, dtype=_np.uint8)
            diag['mmap']['max_val'] = int(arr.max())
            diag['mmap']['mean_val'] = round(float(arr.mean()), 2)
            diag['mmap']['nonzero'] = int(_np.count_nonzero(arr))
            diag['mmap']['first_12_hex'] = raw[:12].hex()
    except Exception as e:
        diag['mmap'] = {'error': str(e)}

    # ── 3. FPP overlay state via HTTP API ────────────────────────────────────
    try:
        import urllib.request, json as _json
        model_name = getattr(current_matrix.fpp, '_overlay_model_name', 'Light_Wall') if current_matrix and getattr(current_matrix, 'fpp', None) else 'Light_Wall'
        url = f'http://localhost/api/overlays/model/{model_name}'
        with urllib.request.urlopen(url, timeout=3) as resp:
            overlay_info = _json.loads(resp.read().decode())
        diag['fpp_overlay'] = overlay_info
    except Exception as e:
        diag['fpp_overlay'] = {'error': str(e)}

    # ── 4. FPP SHM control file state ────────────────────────────────────────
    try:
        control_file = f'/dev/shm/FPP-PixelOverlay-{model_name}'  # type: ignore[reportPossiblyUnbound]
        if os.path.exists(control_file):
            with open(control_file, 'rb') as cf:
                raw_ctrl = cf.read(4)
            state_val = struct.unpack('<i', raw_ctrl)[0] if len(raw_ctrl) >= 4 else None
            diag['fpp_shm_control'] = {'file': control_file, 'isActive': state_val}
        else:
            shm_files = glob.glob('/dev/shm/FPP-*')
            diag['fpp_shm_control'] = {'not_found': control_file, 'available': shm_files}
    except Exception as e:
        diag['fpp_shm_control'] = {'error': str(e)}

    # ── 5. Write a bright test pattern, hold overlay at 3, read back ─────────
    write_test = {}
    try:
        fpp = getattr(initialize_matrix(), 'fpp', None)
        if fpp:
            # Use bright magenta (255,0,255) — unmistakeable
            fpp.acquire_overlay()
            fpp.write_solid(255, 0, 255)
            import time as _t; _t.sleep(0.05)
            raw2 = open(fpp_path, 'rb').read()  # type: ignore[reportPossiblyUnbound]
            arr2 = _np.frombuffer(raw2, dtype=_np.uint8)
            write_test['wrote_rgb'] = [255, 0, 255]
            write_test['readback_max'] = int(arr2.max())
            write_test['readback_mean'] = round(float(arr2.mean()), 2)
            write_test['readback_nonzero'] = int(_np.count_nonzero(arr2))
            write_test['readback_first12'] = raw2[:12].hex()
            write_test['overlay_state_held'] = 3
            write_test['note'] = 'Overlay held at state 3 — call /api/stop to release'
        else:
            write_test['error'] = 'FPP not initialised'
    except Exception as e:
        write_test['error'] = str(e)
    diag['write_test'] = write_test

    # ── 6. Current playback state ─────────────────────────────────────────────
    diag['playback'] = {
        'active': playback_active,
        'video': current_video_name,
        'has_player': current_player is not None,
        'has_matrix': current_matrix is not None,
    }

    # Print to log so it shows in journalctl
    log(f"[PIPELINE_DIAG] {diag}", module="DEBUG")
    return jsonify(diag)


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

            # Download and save thumbnail from YouTube metadata
            thumbnail_url = info.get('thumbnail')
            thumbnail_saved = False
            if thumbnail_url:
                try:
                    import urllib.request as _ureq
                    stem = filepath.stem
                    thumb_path = uploaded_videos_dir / f"{stem}.jpg"
                    with _ureq.urlopen(thumbnail_url, timeout=10) as resp:
                        thumb_data = resp.read()
                    # Crop to 16:9 if taller (YouTube max-res thumbnails are often letterboxed)
                    if HAS_CV2:
                        img_arr = np.frombuffer(thumb_data, dtype=np.uint8)
                        img = cv2.imdecode(img_arr, cv2.IMREAD_COLOR)
                        if img is not None:
                            h, w = img.shape[:2]
                            target_h = int(w * 9 / 16)
                            if target_h < h:
                                y0 = (h - target_h) // 2
                                img = img[y0:y0 + target_h, :]
                            cv2.imwrite(str(thumb_path), img)
                            thumbnail_saved = True
                            log(f"Saved YouTube thumbnail: {thumb_path.name}", module="API")
                    if not thumbnail_saved:
                        with open(thumb_path, 'wb') as tf:
                            tf.write(thumb_data)
                        thumbnail_saved = True
                except Exception as te:
                    log(f"YouTube thumbnail download failed: {te}", level='WARNING', module="API")

        log(f"Downloaded from YouTube: {filepath.name}", module="API")
        
        return jsonify({
            'status': 'downloaded',
            'filename': filepath.name,
            'url': f'/api/video/{filepath.name}',  # Serve file via HTTP endpoint
            'size_mb': filepath.stat().st_size / (1024*1024),
            'has_thumbnail': thumbnail_saved,
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
    # Release overlay on shutdown so fppd stops sending RT frames when our app exits
    try:
        if current_matrix and getattr(current_matrix, 'fpp', None):
            current_matrix.fpp.release_overlay()
    except Exception:
        pass
    if current_matrix:
        current_matrix.shutdown()


def cleanup_idle_loop():
    """Background thread that periodically removes idle players."""
    while cleanup_active:
        try:
            cleanup_idle_players()
            time.sleep(5)  # Check every 5 seconds
        except Exception as e:
            print(f"Error in cleanup loop: {e}")


# ---------------------------------------------------------------------------
# Schedule helpers
# ---------------------------------------------------------------------------

_scheduler_thread = None
_smart_scheduler_thread = None
_scheduler_last_fired: dict = {}   # schedule_id -> "YYYY-MM-DD HH:MM"
_smart_last_fired: dict = {}       # smart_key  -> "YYYY-MM-DD"
_smart_next_game_cache: dict = {}  # smart_key  -> {'date': str, 'game_time': str|None}


def _schedule_id_safe(sid: str) -> bool:
    import re
    return bool(re.match(r'^[0-9a-f\-]{36}$', sid))


def _load_schedule(sid: str) -> dict | None:
    if not _schedule_id_safe(sid):
        return None
    path = schedules_dir / f"{sid}.json"
    if not path.exists():
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def _save_schedule(sid: str, data: dict):
    path = schedules_dir / f"{sid}.json"
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)


def _scheduler_trigger_video(video_name: str, loop: bool, brightness, play_count: int = 0):
    global playback_active, playback_thread, current_video_name, _playback_generation
    rendered = video_name if video_name.endswith('.npz') else get_video_name_from_source(video_name)
    if not rendered:
        log(f"[SCHEDULER] Video not found: {video_name}", level='WARNING', module="Scheduler")
        return
    rendered_path = rendered_videos_dir / rendered
    if not rendered_path.exists():
        log(f"[SCHEDULER] Rendered file missing: {rendered_path}", level='WARNING', module="Scheduler")
        return
    with _playback_lock:
        stop_current_playback()
        _stop_event.clear()
        _playback_generation += 1
        gen = _playback_generation
        playback_active = True
        current_video_name = video_name
        playback_thread = threading.Thread(
            target=play_video_thread,
            args=(str(rendered_path), loop, 1.0, brightness, 20.0, gen),
            kwargs={'repeat_count': play_count},
            daemon=True,
        )
        playback_thread.start()


def _scheduler_trigger_playlist(name: str, loop: bool, brightness, play_count: int = 0):
    global playback_active, playback_thread, current_video_name, _playback_generation
    playlist_data = _load_playlist(name)
    if playlist_data is None:
        log(f"[SCHEDULER] Playlist not found: {name}", level='WARNING', module="Scheduler")
        return
    entries = playlist_data.get('entries', [])
    if not entries:
        log(f"[SCHEDULER] Playlist {name} is empty", level='WARNING', module="Scheduler")
        return
    transition_duration = playlist_data.get('transition_duration', 1.0)
    with _playback_lock:
        stop_current_playback()
        _stop_event.clear()
        _playback_generation += 1
        gen = _playback_generation
        playback_active = True
        current_video_name = f"playlist:{name}"
        playback_thread = threading.Thread(
            target=play_playlist_thread,
            args=(entries, loop, brightness, 20.0, transition_duration, gen),
            kwargs={'repeat_count': play_count},
            daemon=True,
        )
        playback_thread.start()


def _scheduler_trigger_random_from_playlist(name: str, brightness, play_count: int = 0):
    """Pick a random video from a playlist folder and play it as a single video."""
    import random as _random
    playlist_data = _load_playlist(name)
    if playlist_data is None:
        log(f"[SCHEDULER] Playlist not found for random pick: {name}", level='WARNING', module="Scheduler")
        return
    entries = playlist_data.get('entries', [])
    if not entries:
        log(f"[SCHEDULER] Playlist {name} is empty for random pick", level='WARNING', module="Scheduler")
        return
    entry = _random.choice(entries)
    video_name = entry.get('video', '')
    if not video_name:
        log(f"[SCHEDULER] Random entry has no video field in playlist {name}", level='WARNING', module="Scheduler")
        return
    loop = (play_count == 0)
    log(f"[SCHEDULER] Random pick from '{name}' → '{video_name}'", module="Scheduler")
    _scheduler_trigger_video(video_name, loop, brightness, play_count)


def _scheduler_trigger_action(action_type: str, params: dict):
    """Execute a scheduled special action on the curtain."""
    if action_type == 'turn_off':
        log("[SCHEDULER] Action: turn_off — stopping playback", module="Scheduler")
        with _playback_lock:
            stop_current_playback()
            _start_idle()

    elif action_type == 'set_brightness':
        brightness = float(params.get('brightness', 1.0))
        brightness = max(0.05, min(2.0, brightness))
        log(f"[SCHEDULER] Action: set_brightness → {brightness:.2f} ({brightness * 100:.0f}%)", module="Scheduler")
        if current_player:
            current_player.brightness = brightness
        else:
            log("[SCHEDULER] set_brightness: no active player to adjust", level='WARNING', module="Scheduler")

    else:
        log(f"[SCHEDULER] Unknown action type: '{action_type}'", level='WARNING', module="Scheduler")


def _run_scheduler():
    """Background thread: checks every 30 s and fires matching schedules."""
    log("Schedule runner started", module="Scheduler")
    while True:
        try:
            now = datetime.datetime.now()
            current_time_str = now.strftime('%H:%M')
            current_day = now.weekday()   # 0=Mon … 6=Sun
            today_str = now.strftime('%Y-%m-%d')

            for sched_file in list(schedules_dir.glob('*.json')):
                sid = sched_file.stem
                try:
                    s = _load_schedule(sid)
                    if s is None or not s.get('enabled', True):
                        continue
                    if s.get('time') != current_time_str:
                        continue
                    days = s.get('days', list(range(7)))
                    if current_day not in days:
                        continue
                    fire_key = f"{today_str} {current_time_str}"
                    if _scheduler_last_fired.get(sid) == fire_key:
                        continue
                    _scheduler_last_fired[sid] = fire_key

                    target_type = s.get('target_type', 'video')
                    target = s.get('target', '')
                    play_count = int(s.get('play_count', 0))
                    loop = bool(s.get('loop', play_count == 0))
                    random_pick = bool(s.get('random_pick', False))
                    brightness = s.get('brightness')
                    log(f"[SCHEDULER] Firing '{s.get('name', sid)}' → {target_type}:{target} (play_count={play_count}, random={random_pick})", module="Scheduler")

                    if target_type == 'action':
                        action_params = s.get('action_params', {})
                        _scheduler_trigger_action(target, action_params)
                    elif target_type == 'playlist':
                        if random_pick:
                            _scheduler_trigger_random_from_playlist(target, brightness, play_count)
                        else:
                            _scheduler_trigger_playlist(target, loop, brightness, play_count)
                    else:
                        _scheduler_trigger_video(target, loop, brightness, play_count)

                except Exception as e:
                    log(f"[SCHEDULER] Error on {sid}: {e}", level='ERROR', module="Scheduler")
        except Exception as e:
            log(f"[SCHEDULER] Loop error: {e}", level='ERROR', module="Scheduler")
        time.sleep(30)


# ---------------------------------------------------------------------------
# Schedule CRUD endpoints
# ---------------------------------------------------------------------------

@app.route('/api/schedules', methods=['GET'])
def list_schedules():
    """Return all schedules."""
    try:
        schedules = []
        for f in sorted(schedules_dir.glob('*.json')):
            data = _load_schedule(f.stem)
            if data is not None:
                schedules.append({'id': f.stem, **data})
        return jsonify({'schedules': schedules})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/schedules', methods=['POST'])
def create_schedule():
    """Create a new schedule."""
    try:
        data = request.json or {}
        sid = str(uuid.uuid4())
        sched = {
            'name': str(data.get('name', 'Untitled')),
            'enabled': bool(data.get('enabled', True)),
            'target_type': str(data.get('target_type', 'video')),
            'target': str(data.get('target', '')),
            'time': str(data.get('time', '20:00')),
            'days': [int(d) for d in data.get('days', list(range(7)))],
            'loop': bool(data.get('loop', True)),
            'play_count': int(data.get('play_count', 0)),
            'random_pick': bool(data.get('random_pick', False)),
            'color': str(data.get('color', '#42A5F5')),
            'action_params': data.get('action_params', {}),
        }
        _save_schedule(sid, sched)
        return jsonify({'id': sid, **sched}), 201
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/schedules/<sid>', methods=['PUT'])
def update_schedule(sid):
    """Update an existing schedule."""
    try:
        sid = unquote(sid)
        existing = _load_schedule(sid)
        if existing is None:
            return jsonify({'error': 'Schedule not found'}), 404
        data = request.json or {}
        for field in ('name', 'enabled', 'target_type', 'target', 'time', 'days', 'loop', 'play_count', 'random_pick', 'color', 'action_params'):
            if field in data:
                existing[field] = data[field]
        _save_schedule(sid, existing)
        return jsonify({'id': sid, **existing})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/schedules/<sid>', methods=['DELETE'])
def delete_schedule(sid):
    """Delete a schedule."""
    try:
        sid = unquote(sid)
        path = schedules_dir / f"{sid}.json"
        if not path.exists():
            return jsonify({'error': 'Schedule not found'}), 404
        path.unlink()
        return jsonify({'status': 'deleted'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ---------------------------------------------------------------------------
# Smart Schedules  (real-world event triggers)
# ---------------------------------------------------------------------------

def _load_smart_schedules() -> dict:
    if not smart_schedules_path.exists():
        return {
            'dodger_time': {
                'enabled': False,
                'target_type': 'video',
                'target': '',
                'color': '#1565C0',
                'name': 'Dodger Time',
            },
        }
    try:
        with open(smart_schedules_path) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_smart_schedules(data: dict):
    with open(smart_schedules_path, 'w') as f:
        json.dump(data, f, indent=2)


def _fetch_dodger_next_game(today_str: str) -> 'str | None':
    """Return the ISO UTC game-start string for the first Dodger game today, or None."""
    import urllib.request as _urlreq
    url = (
        f"https://statsapi.mlb.com/api/v1/schedule"
        f"?sportId=1&teamId=119&date={today_str}"
    )
    try:
        with _urlreq.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read().decode())
        dates = data.get('dates', [])
        if not dates:
            return None
        games = dates[0].get('games', [])
        return games[0].get('gameDate') if games else None
    except Exception as e:
        log(f"[SMART] MLB API error: {e}", level='WARNING', module="SmartScheduler")
        return None


def _check_dodger_time():
    """Fire Dodger Time trigger if a game is starting within ±5 min (Mountain Time)."""
    try:
        from zoneinfo import ZoneInfo
    except ImportError:
        try:
            from backports.zoneinfo import ZoneInfo  # Python 3.8 backport
        except ImportError:
            import datetime as _dt
            # Fallback: UTC-6 fixed offset (Mountain Daylight Time)
            mountain_tz = _dt.timezone(_dt.timedelta(hours=-6))
            now_mtn = _dt.datetime.now(mountain_tz)
            today_str = now_mtn.strftime('%Y-%m-%d')
            # Inline the rest without ZoneInfo
            _check_dodger_time_fallback(now_mtn, today_str)
            return
    mountain_tz = ZoneInfo("America/Denver")
    now_mtn = datetime.datetime.now(mountain_tz)
    today_str = now_mtn.strftime('%Y-%m-%d')

    # Refresh next-game cache once per day
    cached = _smart_next_game_cache.get('dodger_time', {})
    if cached.get('date') != today_str:
        game_time = _fetch_dodger_next_game(today_str)
        _smart_next_game_cache['dodger_time'] = {'date': today_str, 'game_time': game_time}

    config = _load_smart_schedules()
    dt_config = config.get('dodger_time', {})
    if not dt_config.get('enabled', False):
        return

    target_type = dt_config.get('target_type', 'video')
    target = dt_config.get('target', '')
    if not target:
        return

    # Avoid double-triggering the same game today
    if _smart_last_fired.get('dodger_time') == today_str:
        return

    game_time_str = _smart_next_game_cache.get('dodger_time', {}).get('game_time')
    if not game_time_str:
        return

    try:
        game_time_utc = datetime.datetime.fromisoformat(game_time_str.replace('Z', '+00:00'))
        game_time_mtn = game_time_utc.astimezone(mountain_tz)
        diff_sec = (game_time_mtn - now_mtn).total_seconds()
        if -300 <= diff_sec <= 300:  # ±5-minute window
            _smart_last_fired['dodger_time'] = today_str
            log(
                f"[SMART] Dodger Time! Game at {game_time_mtn.strftime('%I:%M %p MT')}"
                f" → {target_type}:{target}",
                module="SmartScheduler",
            )
            if target_type == 'playlist':
                _scheduler_trigger_playlist(target, loop=True, brightness=None)
            else:
                _scheduler_trigger_video(target, loop=True, brightness=None)
    except Exception as e:
        log(f"[SMART] Trigger error: {e}", level='ERROR', module="SmartScheduler")


def _check_dodger_time_fallback(now_mtn: 'datetime.datetime', today_str: str):
    """Fallback version of _check_dodger_time when zoneinfo is unavailable."""
    config = _load_smart_schedules()
    dt_config = config.get('dodger_time', {})
    if not dt_config.get('enabled', False):
        return
    target_type = dt_config.get('target_type', 'video')
    target = dt_config.get('target', '')
    if not target:
        return
    if _smart_last_fired.get('dodger_time') == today_str:
        return
    cached = _smart_next_game_cache.get('dodger_time', {})
    if cached.get('date') != today_str:
        game_time = _fetch_dodger_next_game(today_str)
        _smart_next_game_cache['dodger_time'] = {'date': today_str, 'game_time': game_time}
    game_time_str = _smart_next_game_cache.get('dodger_time', {}).get('game_time')
    if not game_time_str:
        return
    try:
        import datetime as _dt
        game_time_utc = _dt.datetime.fromisoformat(game_time_str.replace('Z', '+00:00'))
        offset = _dt.timezone(_dt.timedelta(hours=-6))
        game_time_local = game_time_utc.astimezone(offset)
        diff_sec = (game_time_local - now_mtn).total_seconds()
        if -300 <= diff_sec <= 300:
            _smart_last_fired['dodger_time'] = today_str
            log(f"[SMART] Dodger Time (fallback)! → {target_type}:{target}", module="SmartScheduler")
            if target_type == 'playlist':
                _scheduler_trigger_playlist(target, loop=True, brightness=None)
            else:
                _scheduler_trigger_video(target, loop=True, brightness=None)
    except Exception as e:
        log(f"[SMART] Trigger error (fallback): {e}", level='ERROR', module="SmartScheduler")


def _run_smart_scheduler():
    """Background thread: checks smart-schedule triggers every 60 seconds."""
    log("Smart schedule runner started", module="SmartScheduler")
    while True:
        try:
            _check_dodger_time()
        except Exception as e:
            log(f"[SMART] Unhandled error: {e}", level='ERROR', module="SmartScheduler")
        time.sleep(60)


@app.route('/api/smart-schedules', methods=['GET'])
def get_smart_schedules():
    """Return smart schedule config plus cached next-game info."""
    try:
        config = _load_smart_schedules()
        next_game = {
            key: val.get('game_time')
            for key, val in _smart_next_game_cache.items()
        }
        return jsonify({**config, 'next_game': next_game})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/smart-schedules', methods=['PUT'])
def update_smart_schedules():
    """Update smart schedule config."""
    try:
        data = request.json or {}
        config = _load_smart_schedules()
        if 'dodger_time' in data:
            dt = data['dodger_time']
            existing = config.get('dodger_time', {})
            for field in ('enabled', 'target_type', 'target', 'color', 'name'):
                if field in dt:
                    existing[field] = dt[field]
            config['dodger_time'] = existing
        _save_smart_schedules(config)
        return jsonify(config)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def start_cleanup_thread():
    """Start the background cleanup thread, schedule runner, and smart scheduler."""
    global cleanup_thread, cleanup_active, _scheduler_thread, _smart_scheduler_thread
    cleanup_active = True
    if not (cleanup_thread and cleanup_thread.is_alive()):
        cleanup_thread = threading.Thread(target=cleanup_idle_loop, daemon=True)
        cleanup_thread.start()
    if not (_scheduler_thread and _scheduler_thread.is_alive()):
        _scheduler_thread = threading.Thread(target=_run_scheduler, daemon=True, name='schedule-runner')
        _scheduler_thread.start()
    if not (_smart_scheduler_thread and _smart_scheduler_thread.is_alive()):
        _smart_scheduler_thread = threading.Thread(target=_run_smart_scheduler, daemon=True, name='smart-schedule-runner')
        _smart_scheduler_thread.start()


if __name__ == '__main__':
    atexit.register(cleanup)
    
    # Start background cleanup thread for idle players
    start_cleanup_thread()

    # DO NOT call twinkly_controller here.  fppd manages Twinkly auth natively.
    # Any /xled/v1/login call invalidates fppd's token → lights go dark.

    # Run the Flask server (overlay stays disabled until first playback)
    print("Starting Flask API server on port 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)

