"""
Video Renderer: Pre-renders video files to optimized FPP color data.

Converts video files to cached numpy arrays of color data that can be played back
directly on the LED wall without real-time decoding overhead.
"""

import os
import time
import numpy as np
import pickle
from pathlib import Path

try:
    import cv2
    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False
    print("Warning: opencv-python not installed. Install with: pip install opencv-python")


class VideoRenderer:
    """Renders video files to pre-computed color data for FPP playback."""
    
    def __init__(self, matrix_width=90, matrix_height=50, output_dir="dotmatrix/rendered_videos"):
        """
        Initialize video renderer.
        
        Args:
            matrix_width: Target LED matrix width
            matrix_height: Target LED matrix height
            output_dir: Directory to save rendered video data
        """
        if not HAS_CV2:
            raise ImportError("opencv-python is required for video rendering")
        
        self.width = matrix_width
        self.height = matrix_height
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def render_video(self, video_path, output_fps=None, output_name=None):
        """
        Render a video file to optimized color data.
        
        Args:
            video_path: Path to input video file (mp4, avi, etc)
            output_fps: Target framerate (None = use source fps)
            output_name: Output filename (None = auto-generate from input)
        
        Returns:
            Path to saved render file, or None on error
        """
        if not os.path.exists(video_path):
            print(f"Error: Video file not found: {video_path}")
            return None
        
        # Open video
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            print(f"Error: Could not open video: {video_path}")
            return None
        
        # Get video properties
        source_fps = cap.get(cv2.CAP_PROP_FPS)
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        source_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        source_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        
        target_fps = output_fps if output_fps else source_fps
        
        print(f"\nRendering video:")
        print(f"  Source: {video_path}")
        print(f"  Resolution: {source_width}x{source_height} -> {self.width}x{self.height}")
        print(f"  FPS: {source_fps:.2f} -> {target_fps:.2f}")
        print(f"  Total frames: {total_frames}")
        
        # Pre-allocate output array
        frames_to_render = []
        frame_interval = source_fps / target_fps if target_fps < source_fps else 1.0
        
        start_time = time.time()
        frame_idx = 0
        rendered_count = 0
        
        while True:
            ret, frame = cap.read()
            if not ret:
                break
            
            # Skip frames if downsampling FPS
            if output_fps and output_fps < source_fps:
                if frame_idx % int(frame_interval) != 0:
                    frame_idx += 1
                    continue
            
            # Convert BGR (OpenCV) to RGB
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            
            # Resize to matrix dimensions using high-quality downsampling
            resized = cv2.resize(frame_rgb, (self.width, self.height), 
                               interpolation=cv2.INTER_AREA)
            
            # Store as uint8 numpy array (height, width, 3)
            frames_to_render.append(resized.astype(np.uint8))
            
            rendered_count += 1
            if rendered_count % 100 == 0:
                elapsed = time.time() - start_time
                fps_rate = rendered_count / elapsed if elapsed > 0 else 0
                print(f"  Rendered {rendered_count}/{total_frames} frames ({fps_rate:.1f} fps)...", end='\r')
            
            frame_idx += 1
        
        cap.release()
        
        elapsed = time.time() - start_time
        print(f"\n  Rendered {rendered_count} frames in {elapsed:.2f}s ({rendered_count/elapsed:.1f} fps)")
        
        # Save to file
        if output_name is None:
            input_name = Path(video_path).stem
            output_name = f"{input_name}_{self.width}x{self.height}_{target_fps:.0f}fps.npz"
        
        output_path = self.output_dir / output_name
        
        # Save as compressed numpy archive
        np.savez_compressed(
            output_path,
            frames=np.array(frames_to_render, dtype=np.uint8),
            fps=target_fps,
            width=self.width,
            height=self.height,
            source_video=video_path
        )
        
        file_size_mb = output_path.stat().st_size / (1024 * 1024)
        print(f"  Saved: {output_path} ({file_size_mb:.2f} MB)")
        
        return str(output_path)
    
    def load_rendered_video(self, render_path):
        """
        Load a pre-rendered video file.
        
        Args:
            render_path: Path to .npz render file
        
        Returns:
            dict with 'frames' (numpy array), 'fps', 'width', 'height'
        """
        if not os.path.exists(render_path):
            print(f"Error: Render file not found: {render_path}")
            return None
        
        data = np.load(render_path)
        return {
            'frames': data['frames'],
            'fps': float(data['fps']),
            'width': int(data['width']),
            'height': int(data['height']),
            'source_video': str(data['source_video'])
        }
    
    def play_rendered_video(self, render_path, matrix, loop=False):
        """
        Play a pre-rendered video on the matrix.
        
        Args:
            render_path: Path to .npz render file
            matrix: DotMatrix instance to render to
            loop: Loop playback
        
        Returns:
            Number of frames played
        """
        video_data = self.load_rendered_video(render_path)
        if not video_data:
            return 0
        
        frames = video_data['frames']
        target_fps = video_data['fps']
        frame_time = 1.0 / target_fps
        
        print(f"\nPlaying: {render_path}")
        print(f"  Frames: {len(frames)}, FPS: {target_fps:.2f}")
        
        frames_played = 0
        try:
            while True:
                for frame_data in frames:
                    frame_start = time.time()
                    
                    # Render directly using pre-computed colors
                    matrix.render_colors(frame_data)
                    
                    # Frame timing
                    elapsed = time.time() - frame_start
                    sleep_time = frame_time - elapsed
                    if sleep_time > 0:
                        time.sleep(sleep_time)
                    
                    frames_played += 1
                
                if not loop:
                    break
        
        except KeyboardInterrupt:
            print(f"\nPlayback stopped at frame {frames_played}")
        
        return frames_played


def render_video_cli(video_path, output_fps=None, matrix_width=90, matrix_height=50):
    """Convenience function for command-line video rendering."""
    renderer = VideoRenderer(matrix_width, matrix_height)
    return renderer.render_video(video_path, output_fps=output_fps)


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 2:
        print("Usage: python video_renderer.py <video_path> [fps] [width] [height]")
        print("Example: python video_renderer.py demo.mp4 20 90 50")
        sys.exit(1)
    
    video_path = sys.argv[1]
    fps = float(sys.argv[2]) if len(sys.argv) > 2 else None
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 90
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 50
    
    render_video_cli(video_path, fps, width, height)
