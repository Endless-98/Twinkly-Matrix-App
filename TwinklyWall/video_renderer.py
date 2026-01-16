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
    
    def __init__(self, matrix_width=90, matrix_height=50, output_dir="dotmatrix/rendered_videos", 
                 downscale_factor=1.0, quantize_bits=8):
        """
        Initialize video renderer.
        
        Args:
            matrix_width: Target LED matrix width
            matrix_height: Target LED matrix height
            output_dir: Directory to save rendered video data
            downscale_factor: Downscale resolution by this factor (e.g., 0.5 = 80x45 from 90x50) to reduce payload
            quantize_bits: Bits per color channel (8=no quantize, 6=reduce to 6-bit per channel for ~25% bandwidth savings)
        """
        if not HAS_CV2:
            raise ImportError("opencv-python is required for video rendering")
        
        self.width = matrix_width
        self.height = matrix_height
        self.downscale_factor = max(0.1, min(1.0, downscale_factor))  # Clamp to 0.1-1.0
        self.quantize_bits = max(1, min(8, quantize_bits))  # Clamp to 1-8
        # Compute actual downscaled dimensions
        self.downscaled_width = max(1, int(matrix_width * self.downscale_factor))
        self.downscaled_height = max(1, int(matrix_height * self.downscale_factor))
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def render_video(self, video_path, output_fps=None, output_name=None, start_time=None, end_time=None, crop_rect=None):
        """
        Render a video file to optimized color data.
        
        Args:
            video_path: Path to input video file (mp4, avi, etc)
            output_fps: Target framerate (None = use source fps)
            output_name: Output filename (None = auto-generate from input)
            start_time: Start time in seconds (None = from beginning)
            end_time: End time in seconds (None = until end)
            crop_rect: Tuple of (left, top, right, bottom) in normalized coordinates 0-1 (None = no crop)
        
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
        video_duration = total_frames / source_fps if source_fps > 0 else 0
        
        # Calculate trim parameters
        start_frame = int((start_time or 0) * source_fps)
        end_frame = int((end_time or video_duration) * source_fps) if end_time else total_frames
        start_frame = max(0, min(start_frame, total_frames))
        end_frame = max(start_frame + 1, min(end_frame, total_frames))
        
        # Calculate crop parameters (normalized 0-1 to pixel coordinates)
        if crop_rect:
            crop_left = int(crop_rect[0] * source_width)
            crop_top = int(crop_rect[1] * source_height)
            crop_right = int(crop_rect[2] * source_width)
            crop_bottom = int(crop_rect[3] * source_height)
            # Ensure valid crop dimensions
            crop_left = max(0, min(crop_left, source_width - 1))
            crop_top = max(0, min(crop_top, source_height - 1))
            crop_right = max(crop_left + 1, min(crop_right, source_width))
            crop_bottom = max(crop_top + 1, min(crop_bottom, source_height))
        else:
            crop_left, crop_top = 0, 0
            crop_right, crop_bottom = source_width, source_height
        
        target_fps = output_fps if output_fps else source_fps
        
        print(f"\nRendering video:")
        print(f"  Source: {video_path}")
        print(f"  Resolution: {source_width}x{source_height} -> {self.downscaled_width}x{self.downscaled_height} (downscale {self.downscale_factor:.2f}x)")
        if crop_rect:
            print(f"  Crop: ({crop_left},{crop_top}) to ({crop_right},{crop_bottom})")
        if start_time or end_time:
            print(f"  Trim: {start_time or 0:.2f}s to {end_time or video_duration:.2f}s (frames {start_frame}-{end_frame})")
        print(f"  Quantization: {self.quantize_bits}-bit per channel" if self.quantize_bits < 8 else "  Quantization: none (8-bit)")
        print(f"  FPS: {source_fps:.2f} -> {target_fps:.2f}")
        print(f"  Total frames: {end_frame - start_frame}")
        print(f"  Payload reduction: {self._estimate_payload_reduction():.1f}%")
        
        # Seek to start frame
        if start_frame > 0:
            cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
        
        # Pre-allocate output array
        frames_to_render = []
        frame_interval = source_fps / target_fps if target_fps < source_fps else 1.0
        
        start_processing_time = time.time()
        frame_idx = start_frame
        rendered_count = 0
        
        while frame_idx < end_frame:
            ret, frame = cap.read()
            if not ret:
                break
            
            # Skip frames if downsampling FPS
            if output_fps and output_fps < source_fps:
                if (frame_idx - start_frame) % int(frame_interval) != 0:
                    frame_idx += 1
                    continue
            
            # Apply crop if specified
            if crop_rect:
                frame = frame[crop_top:crop_bottom, crop_left:crop_right]
            
            # Convert BGR (OpenCV) to RGB
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            
            # Resize to downscaled dimensions using high-quality downsampling
            resized = cv2.resize(frame_rgb, (self.downscaled_width, self.downscaled_height), 
                               interpolation=cv2.INTER_AREA)
            
            # Apply quantization if needed (reduce to 6-bit, 4-bit, etc. per channel)
            if self.quantize_bits < 8:
                quantized = self._quantize_frame(resized)
                frames_to_render.append(quantized.astype(np.uint8))
            else:
                # Store as uint8 numpy array (height, width, 3)
                frames_to_render.append(resized.astype(np.uint8))
            
            rendered_count += 1
            if rendered_count % 100 == 0:
                elapsed = time.time() - start_processing_time
                fps_rate = rendered_count / elapsed if elapsed > 0 else 0
                print(f"  Rendered {rendered_count}/{end_frame - start_frame} frames ({fps_rate:.1f} fps)...", end='\r')
            
            frame_idx += 1
        
        cap.release()
        
        elapsed = time.time() - start_processing_time
        print(f"\n  Rendered {rendered_count} frames in {elapsed:.2f}s ({rendered_count/elapsed:.1f} fps)")
        
        # Save to file
        if output_name is None:
            input_name = Path(video_path).stem
            quant_str = f"_{self.quantize_bits}bit" if self.quantize_bits < 8 else ""
            output_name = f"{input_name}_{self.downscaled_width}x{self.downscaled_height}_{target_fps:.0f}fps{quant_str}.npz"
        
        output_path = self.output_dir / output_name
        
        # Save as compressed numpy archive
        np.savez_compressed(
            output_path,
            frames=np.array(frames_to_render, dtype=np.uint8),
            fps=target_fps,
            width=self.downscaled_width,
            height=self.downscaled_height,
            source_video=video_path,
            downscale_factor=self.downscale_factor,
            quantize_bits=self.quantize_bits
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

    def _quantize_frame(self, frame):
        """Quantize frame to reduce bits per channel while maintaining visual quality."""
        if self.quantize_bits >= 8:
            return frame
        
        # Compute scale and inverse scale for quantization
        max_val = (1 << self.quantize_bits) - 1  # 2^bits - 1
        scale = max_val / 255.0
        inv_scale = 255.0 / max_val
        
        # Quantize: reduce precision, then expand back to 0-255 range
        quantized = (frame * scale).astype(np.uint8)
        expanded = (quantized * inv_scale).astype(np.uint8)
        return expanded

    def _estimate_payload_reduction(self):
        """Estimate payload reduction percentage from downscaling and quantization."""
        # Downscaling reduces pixels by factor^2
        downscale_reduction = (1.0 - self.downscale_factor * self.downscale_factor) * 100.0
        # Quantization reduces bits per pixel by (8 - quantize_bits) / 8
        quantize_reduction = (1.0 - self.quantize_bits / 8.0) * 100.0
        # Combined (roughly additive, not exact due to compression)
        total = min(downscale_reduction + quantize_reduction, 95.0)
        return total


def render_video_cli(video_path, output_fps=None, matrix_width=90, matrix_height=50,
                     downscale_factor=1.0, quantize_bits=8):
    """Convenience function for command-line video rendering."""
    renderer = VideoRenderer(matrix_width, matrix_height, downscale_factor=downscale_factor, 
                            quantize_bits=quantize_bits)
    return renderer.render_video(video_path, output_fps=output_fps)


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 2:
        print("Usage: python video_renderer.py <video_path> [fps] [width] [height] [downscale] [quantize_bits]")
        print("Example: python video_renderer.py demo.mp4 20 90 50 0.889 6")
        print("         (renders 90x50 at 20fps, downscaled to 80x45, 6-bit quantized)")
        sys.exit(1)
    
    video_path = sys.argv[1]
    fps = float(sys.argv[2]) if len(sys.argv) > 2 else None
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 90
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 50
    downscale = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
    quantize = int(sys.argv[6]) if len(sys.argv) > 6 else 8
    
    render_video_cli(video_path, fps, width, height, downscale, quantize)
