"""
Video Player: Plays pre-rendered videos on the DotMatrix.

Loads .npz files produced by video_renderer and streams frames to the matrix
with accurate timing, looping, and optional playback controls.
"""

import os
import time
from pathlib import Path
from typing import Optional, Union

import numpy as np


class VideoPlayer:
    """Optimized player for rendered videos (.npz) targeting DotMatrix."""

    def __init__(self, matrix, base_dir: Union[str, Path] = "dotmatrix/rendered_videos"):
        """
        Args:
            matrix: A DotMatrix instance to render to
            base_dir: Base folder where rendered videos are stored
        """
        self.matrix = matrix
        self.base_dir = Path(base_dir)
        self._stop = False

    def stop(self):
        """Request playback to stop after current frame."""
        self._stop = True

    def _resolve_path(self, name_or_path: Union[str, Path]) -> Optional[Path]:
        p = Path(name_or_path)
        if p.suffix == "":
            # Bare name: try in base_dir with .npz
            candidate = self.base_dir / f"{p.name}.npz"
            return candidate if candidate.exists() else None
        if p.exists():
            return p
        # Try relative to base_dir
        candidate = self.base_dir / p.name
        return candidate if candidate.exists() else None

    def load(self, name_or_path: Union[str, Path]):
        """Load a rendered video (.npz) from disk into memory.

        Returns a dict with keys: frames (H x W x 3 x N or N x H x W x 3), fps, width, height
        """
        path = self._resolve_path(name_or_path)
        if not path:
            raise FileNotFoundError(f"Render not found: {name_or_path}")
        data = np.load(path)
        frames = data["frames"]
        fps = float(data["fps"]) if "fps" in data else 20.0
        width = int(data["width"]) if "width" in data else frames.shape[2]
        height = int(data["height"]) if "height" in data else frames.shape[1]
        # Ensure dtype and shape (N, H, W, 3)
        if frames.dtype != np.uint8:
            frames = frames.astype(np.uint8, copy=False)
        if frames.ndim == 3:
            # Fallback unexpected shape
            frames = frames.reshape((-1, height, width, 3))
        return {
            "path": str(path),
            "frames": frames,
            "fps": fps,
            "width": width,
            "height": height,
        }

    def play(
        self,
        name_or_path: Union[str, Path],
        loop: bool = False,
        repeat: Optional[int] = None,
        speed: float = 1.0,
        start_frame: int = 0,
        end_frame: Optional[int] = None,
        brightness: Optional[float] = None,
        playback_fps: Optional[float] = None,
    ) -> int:
        """Play a rendered video on the matrix.

        Args:
            name_or_path: Path or base-name of .npz file (searched under base_dir)
            loop: If True, loop indefinitely (ignored if repeat is provided)
            repeat: Number of times to repeat playback (None = 1 pass, 0 = infinite)
            speed: Playback speed multiplier (e.g., 0.5 = half speed, 2.0 = double)
            start_frame: First frame index to play
            end_frame: One past the last frame to play (None = end of video)
            brightness: Optional scalar (0-1 or 0-255) to scale brightness for playback

        Returns:
            Total frames rendered
        """
        self._stop = False
        clip = self.load(name_or_path)
        frames = clip["frames"]
        fps = clip["fps"]
        total = frames.shape[0]
        if end_frame is None or end_frame > total:
            end_frame = total
        if start_frame < 0:
            start_frame = 0
        if start_frame >= end_frame:
            return 0

        # Compute target playback fps
        target_fps = playback_fps if playback_fps is not None else fps * max(1e-3, speed)
        target_fps = max(1e-3, target_fps)
        frame_dt = 1.0 / target_fps

        # Logging: playback configuration (reflects actual target_fps)
        target_label = "FPP" if getattr(self.matrix, "fpp", None) else "Preview"
        print("\n[VideoPlayer] Starting playback")
        print(f"  Target: {target_label}, Headless: {getattr(self.matrix, 'headless', None)}")
        print(f"  Render file: {clip['path']}")
        print(f"  Render fps: {fps:.2f}")
        print(f"  Playback fps: {target_fps:.2f}")
        print(f"  Speed multiplier: {speed:.3f}")
        print(f"  Frames: start={start_frame}, end={end_frame}, total={total}")
        print(f"  Loop: {loop}, Repeat: {repeat if repeat is not None else 1 if not loop else 'inf'}")
        if brightness is not None:
            print(f"  Brightness scale: {brightness}")

        # Optional brightness scaling (numpy, in-place on a view copy per frame)
        scale_0_255 = None
        if brightness is not None:
            scale_0_255 = float(brightness)
            if scale_0_255 <= 1.0:
                scale_0_255 *= 255.0

        def render_frame(arr_uint8: np.ndarray):
            if scale_0_255 is not None:
                # Fast scalar multiply using float32 then clip/cast; avoid modifying original frames
                scaled = np.minimum(255.0, (arr_uint8.astype(np.float32) * (scale_0_255 / 255.0))).astype(np.uint8)
                self.matrix.render_colors(scaled)
            else:
                self.matrix.render_colors(arr_uint8)

        frames_rendered = 0

        # Determine repetition behavior
        infinite = loop or (repeat == 0)
        remaining = repeat if (repeat is not None and repeat > 0) else (None if infinite else 1)

        try:
            while infinite or (remaining is None or remaining > 0):
                t_loop_start = time.perf_counter()
                for idx in range(start_frame, end_frame):
                    if self._stop:
                        return frames_rendered
                    t0 = time.perf_counter()
                    render_frame(frames[idx])
                    # Accurate frame pacing
                    elapsed = time.perf_counter() - t0
                    sleep_time = frame_dt - elapsed
                    if sleep_time > 0:
                        time.sleep(sleep_time)
                    frames_rendered += 1
                    if frames_rendered % 200 == 0:
                        print(f"  Progress: {frames_rendered} frames rendered")
                if not infinite:
                    if remaining is None:
                        remaining = 0
                    else:
                        remaining -= 1
        except KeyboardInterrupt:
            pass

        print(f"[VideoPlayer] Playback finished, frames rendered: {frames_rendered}")

        return frames_rendered


def video_player_cli(path: str, loop: bool = False):
    """Simple CLI to play a render file using a windowed DotMatrix."""
    # Lazy import to avoid circular imports when used as a library
    from dotmatrix import DotMatrix

    m = DotMatrix(headless=False, fpp_output=False, show_source_preview=False, disable_blending=True)
    player = VideoPlayer(m)
    player.play(path, loop=loop)


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Play a rendered .npz video on the DotMatrix")
    p.add_argument("path", help="Path or base name of the .npz in dotmatrix/rendered_videos")
    p.add_argument("--loop", action="store_true", help="Loop playback")
    p.add_argument("--speed", type=float, default=1.0, help="Playback speed multiplier")
    p.add_argument("--start", type=int, default=0, help="Start frame index")
    p.add_argument("--end", type=int, default=None, help="End frame index (exclusive)")
    p.add_argument("--brightness", type=float, default=None, help="Optional brightness scalar (0-1 or 0-255)")
    args = p.parse_args()

    from dotmatrix import DotMatrix

    matrix = DotMatrix(headless=False, fpp_output=False, show_source_preview=False, disable_blending=True)
    player = VideoPlayer(matrix)
    player.play(args.path, loop=args.loop, speed=args.speed, start_frame=args.start, end_frame=args.end, brightness=args.brightness)
