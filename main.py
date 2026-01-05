import os
import platform
from dotmatrix import DotMatrix

# Auto-detect if running on Raspberry Pi and force headless mode
# On Pi: headless for performance. On laptop: show visualization window
def is_raspberry_pi():
    try:
        with open('/proc/device-tree/model', 'r') as f:
            return 'raspberry pi' in f.read().lower()
    except:
        return False

FORCE_HEADLESS = is_raspberry_pi()
HEADLESS = FORCE_HEADLESS or ('DISPLAY' not in os.environ)

if HEADLESS:
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
    os.environ['SDL_AUDIODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

print(f"Running on Pi: {is_raspberry_pi()}")
print(f"Headless mode: {HEADLESS}")


def main():
    matrix = DotMatrix(
        show_source_preview=False,
        headless=HEADLESS,
        fpp_output=True
    )
    matrix.animated_bouncing_ball()
    matrix.wait_for_exit()


if __name__ == "__main__":
    main()