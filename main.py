import os
import time

# Check if a display is available (e.g., monitor connected)
# On systems with X11/Wayland, DISPLAY environment variable indicates display availability
HEADLESS = 'DISPLAY' not in os.environ
if HEADLESS:
    # No display detected, run in headless mode with framebuffer
    os.environ['SDL_VIDEODRIVER'] = 'dummy'

# Suppress pygame welcome message
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

import dotmatrix.dot_matrix as DotMatrix

friendly_current_time = time.time()
sleep_duration_secs = 1

def master_loop():
    while True:
        friendly_current_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        print(f"Current Time: {friendly_current_time}")
        time.sleep(sleep_duration_secs)

def main():
    # master_loop()
    # Disable preview window in headless mode to avoid segfaults
    matrix = DotMatrix.DotMatrix(
        show_source_preview=(not HEADLESS),
        headless=HEADLESS
    )
    matrix.render_sample_pattern()
    # time.sleep(1)
    # matrix.render_image("assets/sample_image.jpg")

    matrix.wait_for_exit()

if __name__ == "__main__":
    main()