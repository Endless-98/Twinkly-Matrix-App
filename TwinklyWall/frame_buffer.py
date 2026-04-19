"""Shared frame buffer for compositing DDP bubble cast over scene playback.

The video player / Tetris / idle pattern publishes each rendered frame here.
When the DDP bridge is actively receiving bubble-cast data from the phone,
it reads the latest scene frame, composites the bubble overlay on top, and
writes the combined result to the FPP mmap — giving the user a bubble window
floating over whatever sequence is currently playing.

When DDP is inactive (no phone casting), the scene writer (video/Tetris)
writes directly to the FPP mmap as before.
"""

import threading
import time

import numpy as np

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

_WIDTH = 90
_HEIGHT = 50

# Latest scene frame published by video player / Tetris / idle.
_bg_frame: np.ndarray = np.zeros((_HEIGHT, _WIDTH, 3), dtype=np.uint8)
_bg_lock = threading.Lock()

# Timestamp of the most recent DDP frame received by the bridge.
_last_ddp_ts: float = 0.0
_ddp_lock = threading.Lock()

# How long after the last DDP packet before we consider DDP "inactive"
# and allow the scene writer to resume direct mmap writes.
_DDP_ACTIVE_TIMEOUT = 1.0  # seconds


# ---------------------------------------------------------------------------
# Scene (background) frame — written by video player / Tetris / idle
# ---------------------------------------------------------------------------

def set_background(frame: np.ndarray) -> None:
    """Store the latest scene frame (H×W×3 uint8)."""
    global _bg_frame
    with _bg_lock:
        if frame.shape == (_HEIGHT, _WIDTH, 3):
            _bg_frame = frame.copy()
        else:
            _bg_frame = np.array(frame, dtype=np.uint8).reshape(_HEIGHT, _WIDTH, 3)


def get_background() -> np.ndarray:
    """Return a copy of the latest scene frame."""
    with _bg_lock:
        return _bg_frame.copy()


def clear_background() -> None:
    """Reset the scene frame to black."""
    global _bg_frame
    with _bg_lock:
        _bg_frame = np.zeros((_HEIGHT, _WIDTH, 3), dtype=np.uint8)


# ---------------------------------------------------------------------------
# DDP active flag — managed by the DDP bridge
# ---------------------------------------------------------------------------

def touch_ddp() -> None:
    """Called by the DDP bridge each time it writes a frame."""
    global _last_ddp_ts
    with _ddp_lock:
        _last_ddp_ts = time.monotonic()


def is_ddp_active() -> bool:
    """True if DDP frames have been received within the timeout window."""
    with _ddp_lock:
        return (time.monotonic() - _last_ddp_ts) < _DDP_ACTIVE_TIMEOUT
