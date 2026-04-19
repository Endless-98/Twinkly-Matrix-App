"""
Playlist Player: plays an ordered list of rendered videos with transitions.

Each playlist entry specifies a video name and the transition to use *before*
it plays:
  • entries[1..n].transition  — transition played between the previous clip and
                                this one.
  • entries[0].transition     — loop-back transition played between the last clip
                                and the first clip when the playlist loops.
                                Ignored on the first play-through.
"""

import time
from pathlib import Path
from typing import Optional, Union

import numpy as np

from transitions import TRANSITIONS
from video_player import VideoPlayer


class PlaylistPlayer:
    """Plays a sequence of .npz videos with configurable transitions."""

    def __init__(self, matrix, base_dir: Union[str, Path],
                 stop_event=None):
        self.matrix = matrix
        self.base_dir = Path(base_dir)
        self._stop = False
        self._stop_event = stop_event
        self._brightness: Optional[float] = None

    @property
    def brightness(self) -> Optional[float]:
        return self._brightness

    @brightness.setter
    def brightness(self, value: Optional[float]):
        if value is not None:
            value = max(0.05, min(3.0, float(value)))
        self._brightness = value

    def stop(self):
        self._stop = True

    @property
    def _should_stop(self):
        return self._stop or (self._stop_event is not None and self._stop_event.is_set())

    def _render_frame(self, arr: np.ndarray):
        """Apply contrast + brightness then push to matrix."""
        arr_f = arr.astype(np.float32)
        arr_f = np.clip(128.0 + (arr_f - 128.0) * 1.20, 0.0, 255.0)
        br = self._brightness
        if br is not None and br != 1.0:
            arr_f = np.minimum(255.0, arr_f * float(br))
        self.matrix.render_colors(arr_f.astype(np.uint8))

    def play(
        self,
        entries: list[dict],
        loop: bool = False,
        brightness: Optional[float] = None,
        playback_fps: Optional[float] = None,
        transition_duration: float = 1.0,
    ) -> int:
        """Play a playlist.

        Args:
            entries: List of {"video": "name", "transition": "fade"|"slide"|...}
            loop: Loop the entire playlist
            brightness: Initial brightness (0.05–3.0)
            playback_fps: Override per-clip fps
            transition_duration: Seconds for each transition

        Returns:
            Total frames rendered across all clips
        """
        self._stop = False
        if brightness is not None:
            self._brightness = brightness

        if not entries:
            return 0

        loader = VideoPlayer(self.matrix, self.base_dir, self._stop_event)
        total_rendered = 0

        print(f"\n[PlaylistPlayer] Starting playlist ({len(entries)} entries, loop={loop})")

        # last frame carried across loop iterations for the loop-back transition
        loop_last_frame: Optional[np.ndarray] = None

        while True:
            # On subsequent loop iterations prev_last_frame starts as the last
            # frame of the previous run so the loop-back transition can fire.
            prev_last_frame: Optional[np.ndarray] = loop_last_frame

            for idx, entry in enumerate(entries):
                if self._should_stop:
                    return total_rendered

                video_name = entry.get("video", "")
                transition_name = entry.get("transition", "none")
                trans_fn = TRANSITIONS.get(transition_name, TRANSITIONS["none"])

                # Load clip
                try:
                    clip = loader.load(video_name)
                except FileNotFoundError:
                    print(f"  [PlaylistPlayer] Skipping missing video: {video_name}")
                    continue

                frames = clip["frames"]
                if frames.shape[0] == 0:
                    continue

                fps = playback_fps if playback_fps else clip["fps"]
                fps = max(1e-3, fps)
                frame_dt = 1.0 / fps
                trans_frames = max(1, int(transition_duration * fps))

                first_frame = frames[0]
                print(f"  [{idx + 1}/{len(entries)}] {video_name}  "
                      f"({frames.shape[0]} frames, transition={transition_name})")

                # --- Transition from previous clip (or loop-back if idx==0) ---
                # prev_last_frame is None only on the very first clip of the very
                # first play-through, so no transition fires then.
                # The incoming clip starts playing immediately — we blend its
                # advancing frames over the outgoing clip's last frame.
                if prev_last_frame is not None and transition_name != "none":
                    for ti in range(trans_frames):
                        if self._should_stop:
                            return total_rendered
                        t = (ti + 1) / trans_frames
                        # Use advancing frames of incoming clip during transition
                        in_fi = min(ti, frames.shape[0] - 1)
                        blended = trans_fn(prev_last_frame, frames[in_fi], t)
                        t0 = time.perf_counter()
                        self._render_frame(blended)
                        total_rendered += 1
                        elapsed = time.perf_counter() - t0
                        if frame_dt - elapsed > 0:
                            time.sleep(frame_dt - elapsed)
                    # Skip the frames already shown during transition
                    clip_start_frame = min(trans_frames, frames.shape[0])
                else:
                    clip_start_frame = 0

                # --- Play remaining clip frames ---
                for fi in range(clip_start_frame, frames.shape[0]):
                    if self._should_stop:
                        return total_rendered
                    t0 = time.perf_counter()
                    self._render_frame(frames[fi])
                    total_rendered += 1
                    elapsed = time.perf_counter() - t0
                    if frame_dt - elapsed > 0:
                        time.sleep(frame_dt - elapsed)

                prev_last_frame = frames[-1].copy()

            # Carry the last frame into the next loop iteration for loop-back
            loop_last_frame = prev_last_frame

            if not loop:
                break

        print(f"[PlaylistPlayer] Finished ({total_rendered} frames)")
        return total_rendered
