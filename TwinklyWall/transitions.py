"""
Transition effects for playlist playback.

Each transition function takes two frames (outgoing and incoming, both H×W×3 uint8)
and a progress value t (0.0 = fully outgoing, 1.0 = fully incoming), returning
the blended frame as H×W×3 uint8.
"""

import numpy as np
from typing import Callable

# Type alias: (frame_out, frame_in, t) -> blended_frame
TransitionFn = Callable[[np.ndarray, np.ndarray, float], np.ndarray]


def fade(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Cross-fade between two frames."""
    return np.clip(
        frame_out.astype(np.float32) * (1.0 - t) + frame_in.astype(np.float32) * t,
        0, 255
    ).astype(np.uint8)


def slide_left(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Slide the incoming frame in from the right."""
    h, w, c = frame_out.shape
    offset = int(round(t * w))
    result = np.zeros_like(frame_out)
    # Outgoing slides left
    if w - offset > 0:
        result[:, :w - offset] = frame_out[:, offset:]
    # Incoming slides in from right
    if offset > 0:
        result[:, w - offset:] = frame_in[:, :offset]
    return result


def slide_up(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Slide the incoming frame in from the bottom."""
    h, w, c = frame_out.shape
    offset = int(round(t * h))
    result = np.zeros_like(frame_out)
    if h - offset > 0:
        result[:h - offset] = frame_out[offset:]
    if offset > 0:
        result[h - offset:] = frame_in[:offset]
    return result


def wipe_right(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Hard wipe revealing incoming from left to right."""
    h, w, c = frame_out.shape
    col = int(round(t * w))
    result = frame_out.copy()
    if col > 0:
        result[:, :col] = frame_in[:, :col]
    return result


def dissolve(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Random pixel dissolve: pixels randomly flip to incoming frame."""
    rng = np.random.RandomState(42)
    mask = rng.random(frame_out.shape[:2]) < t
    result = frame_out.copy()
    result[mask] = frame_in[mask]
    return result


def zoom_in(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Incoming frame zooms up from center over outgoing."""
    h, w, c = frame_out.shape
    # Scale goes from 0.05 → 1.0
    scale = max(0.05, t)
    new_h = max(1, int(h * scale))
    new_w = max(1, int(w * scale))
    # Resize incoming to the scaled size then paste centered
    # Use simple nearest-neighbour slicing for speed (90×50 is tiny)
    y_indices = np.linspace(0, h - 1, new_h).astype(np.intp)
    x_indices = np.linspace(0, w - 1, new_w).astype(np.intp)
    small = frame_in[np.ix_(y_indices, x_indices)]
    top = (h - new_h) // 2
    left = (w - new_w) // 2
    result = frame_out.copy()
    result[top:top + new_h, left:left + new_w] = small
    return result


def iris_circle(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Circular iris wipe expanding from center."""
    h, w, c = frame_out.shape
    cy, cx = h / 2.0, w / 2.0
    max_r = np.sqrt(cx * cx + cy * cy)
    radius = t * max_r
    y_coords, x_coords = np.mgrid[0:h, 0:w].astype(np.float32)
    dist = np.sqrt((x_coords - cx) ** 2 + (y_coords - cy) ** 2)
    mask = dist <= radius
    result = frame_out.copy()
    result[mask] = frame_in[mask]
    return result


def fisheye_swirl(frame_out: np.ndarray, frame_in: np.ndarray, t: float) -> np.ndarray:
    """Fisheye swirl distortion that morphs from outgoing to incoming.

    First half (t<0.5): outgoing frame swirls inward with increasing distortion.
    Second half (t>=0.5): incoming frame unswirls from max distortion.
    """
    h, w, c = frame_out.shape
    # Build coordinate grids (cached via shape — small 90×50 so cheap to recreate)
    cy, cx = h / 2.0, w / 2.0
    y_coords, x_coords = np.mgrid[0:h, 0:w].astype(np.float32)

    # Normalize to [-1, 1]
    nx = (x_coords - cx) / cx
    ny = (y_coords - cy) / cy
    r = np.sqrt(nx * nx + ny * ny)
    r = np.clip(r, 1e-6, None)
    theta = np.arctan2(ny, nx)

    if t < 0.5:
        src = frame_out
        # Swirl strength ramps up in first half (0→1)
        strength = t * 2.0
    else:
        src = frame_in
        # Swirl strength ramps down in second half (1→0)
        strength = (1.0 - t) * 2.0

    # Fisheye: warp radius with power curve
    fisheye_power = 1.0 + strength * 1.5
    r_warped = np.power(r, fisheye_power)

    # Swirl: rotate by angle proportional to distance and strength
    swirl_angle = strength * 3.0 * (1.0 - r)
    theta_warped = theta + swirl_angle

    # Back to pixel coordinates
    src_x = (r_warped * np.cos(theta_warped) * cx + cx).astype(np.float32)
    src_y = (r_warped * np.sin(theta_warped) * cy + cy).astype(np.float32)

    # Clamp and sample (nearest-neighbour — fine at 90×50)
    src_x = np.clip(src_x, 0, w - 1).astype(np.intp)
    src_y = np.clip(src_y, 0, h - 1).astype(np.intp)

    warped = src[src_y, src_x]

    # Cross-fade at the midpoint to smooth the source switch
    if 0.35 < t < 0.65:
        blend = (t - 0.35) / 0.30  # 0→1 over the overlap zone
        if t < 0.5:
            other_src = frame_in
        else:
            other_src = frame_out
        other_warped = other_src[src_y, src_x]
        warped = np.clip(
            warped.astype(np.float32) * (1.0 - blend * 0.5)
            + other_warped.astype(np.float32) * (blend * 0.5),
            0, 255
        ).astype(np.uint8)

    return warped


# Registry: name → function
TRANSITIONS: dict[str, TransitionFn] = {
    "none": lambda a, b, t: b if t >= 0.5 else a,
    "fade": fade,
    "slide": slide_left,
    "slide_up": slide_up,
    "wipe": wipe_right,
    "dissolve": dissolve,
    "zoom": zoom_in,
    "iris": iris_circle,
    "fisheye_swirl": fisheye_swirl,
}

TRANSITION_NAMES = list(TRANSITIONS.keys())
