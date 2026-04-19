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
    "fisheye_swirl": fisheye_swirl,
}

TRANSITION_NAMES = list(TRANSITIONS.keys())
