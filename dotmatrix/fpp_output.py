import mmap
import time
import os
from .light_wall_mapping import load_light_wall_mapping, create_fpp_buffer_from_grid


class FPPOutput:
    def __init__(self, width=90, height=50, fpp_file="/dev/shm/FPP-Model-Data-Light_Wall"):
        self.width = width
        self.height = height
        self.fpp_file = fpp_file
        self.buffer_size = width * height * 3
        self.mm = None
        self.file = None
        self.mapping = load_light_wall_mapping()
        self._initialize_mmap()
    
    def _initialize_mmap(self):
        try:
            if not os.path.exists(self.fpp_file):
                try:
                    with open(self.fpp_file, 'wb') as f:
                        f.write(b'\x00' * self.buffer_size)
                except PermissionError:
                    print(f"Permission denied creating {self.fpp_file}")
                    print("Try running: sudo touch {}".format(self.fpp_file))
                    print("          sudo chmod 666 {}".format(self.fpp_file))
                    raise
            
            self.file = open(self.fpp_file, 'r+b')
            self.mm = mmap.mmap(self.file.fileno(), self.buffer_size)
        except PermissionError as e:
            print(f"Permission denied accessing {self.fpp_file}")
            print("Fix with: sudo chmod 666 {}".format(self.fpp_file))
            if self.file:
                self.file.close()
            self.mm = None
            self.file = None
        except Exception as e:
            print(f"Failed to initialize FPP output: {e}")
            if self.file:
                self.file.close()
            self.mm = None
            self.file = None
    
    def write_matrix(self, dot_colors):
        if not self.mm:
            return
        
        buffer = create_fpp_buffer_from_grid(dot_colors, self.mapping)
        
        self.mm.seek(0)
        self.mm.write(buffer)
        self.mm.flush()
    
    def verify_write(self):
        """Verify data is being written to shared memory"""
        if not self.mm:
            print("FPP output not initialized")
            return False
        
        test_buffer = bytearray(self.buffer_size)
        test_buffer[0:3] = b'\xFF\x00\x00'  # Red for first pixel
        
        self.mm.seek(0)
        self.mm.write(test_buffer)
        self.mm.flush()
        
        self.mm.seek(0)
        read_back = self.mm.read(3)
        
        if read_back == b'\xFF\x00\x00':
            print("✓ FPP shared memory is writable and readable")
            return True
        else:
            print("✗ FPP shared memory write verification failed")
            print(f"  Expected: b'\\xFF\\x00\\x00', got: {read_back}")
            return False

    
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
