# TwinklyWall

High-performance LED matrix renderer optimized for Raspberry Pi with FPP (Falcon Player Protocol) output.

## Performance

- **516+ FPS** capability on Raspberry Pi 4B
- Vectorized numpy operations for sub-millisecond rendering
- Configurable frame rate capping (default: 20 FPS)
- Real-time performance monitoring

## Features

- Pygame surface to LED matrix conversion
- Luminance-based color blending
- Headless mode for production deployment
- FPP memory-mapped hardware output
- Modular architecture with clean APIs

## Installation

```bash
pip install -e .
```

Or install dependencies directly:
```bash
pip install -r requirements.txt
```

## Quick Start

```python
from dotmatrix import DotMatrix, CanvasSource
import pygame

# Create matrix
matrix = DotMatrix(
    width=90,
    height=50,
    headless=True,
    fpp_output=True,
    max_fps=20
)

# Create canvas
canvas = CanvasSource.from_size(270, 150)

# Render loop
while True:
    # Draw on canvas
    canvas.surface.fill((0, 0, 0))
    pygame.draw.circle(canvas.surface, (255, 0, 0), (135, 75), 30)
    
    # Render to matrix
    matrix.render_frame(canvas)
```

### Direct Color Rendering

For pre-computed color data:

```python
import numpy as np

# Create color array (height x width x 3)
colors = np.random.randint(0, 256, (50, 90, 3), dtype=np.uint8)

# Render directly
matrix.render_colors(colors)
```

## Project Structure

```
TwinklyWall/
├── dotmatrix/              # Core rendering package
│   ├── __init__.py
│   ├── dot_matrix.py       # Main DotMatrix renderer
│   ├── performance.py      # Performance monitoring
│   ├── fpp_output.py       # FPP hardware output
│   ├── source_canvas.py    # Canvas utilities
│   └── light_wall_mapping.py
├── main.py                 # Demo application
├── pyproject.toml          # Project configuration
└── requirements.txt        # Dependencies
```

## Configuration

### DotMatrix Parameters

- `width`, `height`: Matrix dimensions in dots
- `max_fps`: Frame rate cap (default: 20)
- `headless`: Skip pygame window (default: False)
- `fpp_output`: Enable hardware output (default: False)
- `enable_performance_monitor`: Log performance metrics (default: True)
- `blend_power`: Luminance blending exponent (default: 0.2)
- `supersample`: Antialiasing factor (default: 3)

## Performance Monitoring

Performance reports are logged every second:

```
============================================================
Performance Report (Last 1.00s)
Average FPS: 516.79 | Frame Count: 518

Stage Latencies (average):
  scaling             :   0.35ms
  sampling_blend      :   0.92ms
  visualization       :   0.00ms
  fpp_write           :   0.58ms
  total               :   1.87ms

Frame budget: 25.00ms (40 FPS target)
Headroom:  23.13ms
============================================================
```

## Requirements

- Python >= 3.8
- pygame >= 2.5.0
- numpy >= 1.20.0

## License

[Add your license here]
