# TwinklyWall - Windows Quick Start

## Running on Windows

When running TwinklyWall on Windows, it sends data to your FPP device over the network using the DDP (Distributed Display Protocol).

### First Time Setup

1. Find your FPP device's IP address (check your router or FPP web interface)
2. Set the environment variable (or use command line):
   ```cmd
   set FPP_IP=192.168.1.68
   ```
   (Replace with your FPP's actual IP address)

### Running the App

#### Option 1: Using Environment Variable
```cmd
set FPP_IP=192.168.1.68
TwinklyWall.exe
```

#### Option 2: Using Command Line Argument
```cmd
TwinklyWall.exe --fpp-ip 192.168.1.68
```

### Modes

#### Video Mode (default)
```cmd
TwinklyWall.exe --mode video
```

#### Tetris Mode
```cmd
TwinklyWall.exe --mode tetris
```

#### API Server Mode (for Flutter app control)
```cmd
TwinklyWall.exe --mode api
```

### Troubleshooting

**Problem: No output on LED wall**
- Verify FPP IP address is correct
- Check that FPP is running and accessible
- Ensure firewall allows UDP port 4048
- Test connectivity: `ping 192.168.1.68`

**Problem: "ddp_host is required" error**
- You need to set FPP_IP environment variable or use --fpp-ip argument
- Example: `TwinklyWall.exe --fpp-ip 192.168.1.68`

**Problem: Performance issues**
- Close other applications
- Try reducing playback FPS: `--playback-fps 15`
- Enable FPS debug to see performance: `--fps-debug`

### Network Configuration

By default, TwinklyWall uses:
- **IP**: `192.168.1.68` (set via FPP_IP)
- **Port**: `4048` (DDP default, change with --ddp-port)

### Advanced Options

```cmd
TwinklyWall.exe --help
```

Shows all available options including:
- `--fpp-ip IP`: FPP device IP address
- `--ddp-port PORT`: DDP port (default: 4048)
- `--mode MODE`: tetris, video, or api
- `--fps-debug`: Show performance statistics
- `--playback-fps FPS`: Target playback FPS

### Example Commands

Play video at 15 FPS:
```cmd
TwinklyWall.exe --fpp-ip 192.168.1.68 --mode video --playback-fps 15
```

Start Tetris:
```cmd
TwinklyWall.exe --fpp-ip 192.168.1.68 --mode tetris --level 5
```

Run API server for Flutter app:
```cmd
TwinklyWall.exe --fpp-ip 192.168.1.68 --mode api
```
