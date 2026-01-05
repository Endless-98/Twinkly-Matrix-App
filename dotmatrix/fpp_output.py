import mmap
import time
import os


class FPPOutput:
    def __init__(self, width=87, height=50, fpp_file="/dev/shm/FPP-Model-Data-Light_Wall"):
        self.width = width
        self.height = height
        self.fpp_file = fpp_file
        self.buffer_size = width * height * 3
        self.mm = None
        self.file = None
        self._initialize_mmap()
    
    def _initialize_mmap(self):
        try:
            if not os.path.exists(self.fpp_file):
                with open(self.fpp_file, 'wb') as f:
                    f.write(b'\x00' * self.buffer_size)
            
            self.file = open(self.fpp_file, 'r+b')
            self.mm = mmap.mmap(self.file.fileno(), self.buffer_size)
        except Exception as e:
            print(f"Failed to initialize FPP output: {e}")
            if self.file:
                self.file.close()
            self.mm = None
            self.file = None
    
    def write_matrix(self, dot_colors):
        if not self.mm:
            return
        
        buffer = bytearray(self.buffer_size)
        idx = 0
        
        for row in range(self.height):
            for col in range(self.width):
                r, g, b = dot_colors[row][col]
                buffer[idx] = r
                buffer[idx + 1] = g
                buffer[idx + 2] = b
                idx += 3
        
        self.mm.seek(0)
        self.mm.write(buffer)
        self.mm.flush()
    
    def test_color_wash(self, fps=40):
        if not self.mm:
            print("FPP output not initialized")
            return
        
        colors = [
            (255, 0, 0),    # Red
            (0, 255, 0),    # Green
            (0, 0, 255),    # Blue
            (255, 255, 0),  # Yellow
            (255, 0, 255),  # Magenta
            (0, 255, 255),  # Cyan
        ]
        
        frame_delay = 1.0 / fps
        color_idx = 0
        
        try:
            while True:
                color = colors[color_idx % len(colors)]
                buffer = bytearray(color * (self.width * self.height))
                
                self.mm.seek(0)
                self.mm.write(buffer)
                self.mm.flush()
                
                color_idx += 1
                time.sleep(frame_delay)
        except KeyboardInterrupt:
            print("\nStopping color wash")
            self.clear()
    
    def clear(self):
        if self.mm:
            self.mm.seek(0)
            self.mm.write(b'\x00' * self.buffer_size)
            self.mm.flush()
    
    def close(self):
        if self.mm:
            self.mm.close()
        if self.file:
            self.file.close()
