"""Performance monitoring utilities for DotMatrix rendering."""

import time

class PerformanceMonitor:
    """Tracks and reports rendering performance metrics."""

    def __init__(self, enabled=True, target_fps=None):
        self.enabled = enabled
        self.target_fps = target_fps
        self.frame_count = 0
        self.last_log_time = time.time()
        self.stage_timings = {
            'scaling': [],
            'sampling_blend': [],
            'visualization': [],
            'fpp_write': [],
            'total': []
        }

    def record(self, stage, duration_ms):
        """Record timing for a stage."""
        if self.enabled:
            self.stage_timings[stage].append(duration_ms)

    def frame_complete(self):
        """Mark frame as complete and log if needed."""
        if not self.enabled:
            return

        self.frame_count += 1
        current_time = time.time()
        elapsed = current_time - self.last_log_time

        if elapsed >= 1.0:
            self._log_performance(elapsed)
            self._reset()
            self.last_log_time = current_time

    def _log_performance(self, elapsed):
        """Print performance report."""
        if self.frame_count == 0:
            return

        fps = self.frame_count / elapsed
        print(f"\n{'='*60}")
        print(f"Performance Report (Last {elapsed:.2f}s)")
        print(f"Average FPS: {fps:.2f} | Frame Count: {self.frame_count}")
        print(f"\nStage Latencies (average):")

        for stage, times in self.stage_timings.items():
            if times:
                avg = sum(times) / len(times)
                min_t = min(times)
                max_t = max(times)
                print(f"  {stage:20s}: {avg:6.2f}ms (min: {min_t:5.2f}ms, max: {max_t:5.2f}ms)")

        if self.stage_timings['total']:
            avg_total = sum(self.stage_timings['total']) / len(self.stage_timings['total'])
            if self.target_fps:
                frame_budget = 1000.0 / float(self.target_fps)
                print(f"\nFrame budget: {frame_budget:5.2f}ms ({self.target_fps:.0f} FPS target)")
                print(f"Headroom: {frame_budget - avg_total:6.2f}ms")
        print(f"{'='*60}\n")

    def _reset(self):
        """Reset counters for next period."""
        self.frame_count = 0
        for stage in self.stage_timings:
            self.stage_timings[stage].clear()
