# Packaging for Windows from WSL

This repo contains:
- Flutter desktop app: `led_matrix_controller` (supports Windows, macOS, Linux)
- Python app: `TwinklyWall` (Flask API + pygame-based rendering)

Building native Windows binaries directly inside Linux/WSL is not supported by Flutter or PyInstaller. Use one of these approaches:

## Option A: CI builds on Windows (recommended)
Workflows are provided under `.github/workflows/`:
- `flutter-windows.yml`: Builds the Windows runner for `led_matrix_controller`
- `python-windows.yml`: Packages `TwinklyWall/main.py` into `TwinklyWall.exe` using PyInstaller

Trigger a build:
1. Push a tag like `v1.0.0` or run the workflow via "Run workflow".
2. Download artifacts from the Actions run:
   - Flutter: `led_matrix_controller-windows-release` (contains `led_matrix_controller.exe` and runtime files)
   - Python: `TwinklyWall-exe` (contains `TwinklyWall.exe`)

## Option B: Build on a Windows machine
If you are on Windows (with WSL), you can invoke Windows tooling from WSL using `powershell.exe` or `cmd.exe`, but you still need Windows prerequisites installed.

### Flutter Windows build
Prerequisites on Windows host:
- Visual Studio 2022 with "Desktop development with C++" and Windows SDK
- Flutter SDK (stable channel)

Build steps from project root:
```powershell
# In Windows PowerShell
cd led_matrix_controller
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release
# Output: led_matrix_controller/build/windows/x64/runner/Release/
```

From WSL you can invoke PowerShell (assuming PATH to Windows executables is available):
```bash
# In WSL
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "cd $(wslpath -w ./led_matrix_controller); flutter config --enable-windows-desktop; flutter pub get; flutter build windows --release"
```

### Python EXE via PyInstaller
Prerequisites on Windows host:
- Python 3.11 (or 3.10) installed and on PATH

Build steps from project root:
```powershell
# In Windows PowerShell
python -m pip install --upgrade pip
pip install -r TwinklyWall/requirements.txt
pip install pyinstaller
pyinstaller --onefile TwinklyWall/main.py \`n  --name TwinklyWall \`n  --paths TwinklyWall \`n  --add-data "TwinklyWall/assets;assets" \`n  --add-data "TwinklyWall/dotmatrix/rendered_videos;dotmatrix/rendered_videos" \`n  --add-data "TwinklyWall/dotmatrix/Light Wall Mapping.csv;dotmatrix"
# Output: dist/TwinklyWall.exe
```

Notes:
- If your Python app needs additional data files, add them via `--add-data`.
- Running the Flask API (`--mode api`) starts a local server; ensure Windows firewall allows it.

## Why not cross-compile directly in WSL/Linux?
- Flutter’s Windows desktop build requires Windows toolchains (MSBuild, Windows SDK) and cannot cross-compile from Linux.
- PyInstaller produces platform-specific bootloaders and does not cross-create Windows executables from Linux.

## Troubleshooting
- Flutter build missing SDK: Install Visual Studio components and restart shell.
- PyInstaller missing modules: add `--paths TwinklyWall` or `--hidden-import <module>`.
- Assets not found at runtime: verify `--add-data` paths and relative locations.

If you want, I can wire up release packaging (zip installers) in CI as a next step.