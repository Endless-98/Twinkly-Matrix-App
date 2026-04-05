"""Idle twinkle pattern — ambient animation shown when no video or game is active.

Renders a soft twinkling star-field to the LED matrix so the wall shows
life when the app is running but nothing is explicitly playing.
"""

import math
import random
import threading
import time

import numpy as np


class IdlePattern:
    """Generates a slow twinkling star-field on the LED matrix."""

    def __init__(self, matrix, fps=10):
        self._matrix = matrix
        self._fps = fps
        self._thread = None
        self._stop_event = threading.Event()

        w, h = matrix.width, matrix.height
        # Each star: (x, y, phase_offset, speed, peak_brightness, r_ratio, g_ratio, b_ratio)
        num_stars = max(20, int(w * h * 0.04))
        self._stars = []
        for _ in range(num_stars):
            self._stars.append(self._make_star(w, h))

    @staticmethod
    def _make_star(w, h):
        # Warm-white palette with slight colour variation
        temp = random.uniform(0.0, 1.0)
        if temp < 0.5:
            r, g, b = 1.0, 0.85, 0.6   # warm white
        elif temp < 0.8:
            r, g, b = 0.7, 0.85, 1.0   # cool white
        else:
            r, g, b = 1.0, 0.7, 0.4    # amber

        return {
            "x": random.randint(0, w - 1),
            "y": random.randint(0, h - 1),
            "phase": random.uniform(0, 2 * math.pi),
            "speed": random.uniform(0.3, 1.2),
            "peak": random.randint(30, 90),
            "r": r, "g": g, "b": b,
        }

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="idle-pattern")
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=2)
            self._thread = None

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def _loop(self):
        interval = 1.0 / self._fps
        t0 = time.monotonic()

        while not self._stop_event.is_set():
            t = time.monotonic() - t0
            frame = np.zeros((self._matrix.height, self._matrix.width, 3), dtype=np.uint8)

            for s in self._stars:
                brightness = (math.sin(t * s["speed"] + s["phase"]) + 1.0) / 2.0
                val = brightness * s["peak"]
                frame[s["y"], s["x"]] = (
                    int(val * s["r"]),
                    int(val * s["g"]),
                    int(val * s["b"]),
                )

            try:
                self._matrix.render_colors(frame)
            except Exception:
                break

            elapsed = time.monotonic() - t0 - t
            remaining = interval - elapsed
            if remaining > 0:
                self._stop_event.wait(remaining)
