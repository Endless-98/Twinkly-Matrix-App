# Quick Start: Windows Build

Use `build_windows.py` to automate Flutter and Python packaging for Windows.

## Installation
```bash
# Script is ready—no extra setup needed
python build_windows.py --help
```

## Common Commands

### From WSL (recommended)
Trigger GitHub Actions CI builds:
```bash
# Build Flutter app for Windows
python build_windows.py --flutter

# Package Python app as .exe
python build_windows.py --python

# Build both
python build_windows.py --all
```

All workflows run on GitHub's Windows runners. **Download artifacts from Actions.**

### From Windows (if you have prerequisites)
Local builds on Windows host:
```bash
# Check prerequisites
python build_windows.py --local

# Build Flutter locally
python build_windows.py --local --flutter

# Build Python exe locally
python build_windows.py --local --python

# Build both locally
python build_windows.py --local --all
```

## What it Does

| Step | Command | Output |
|------|---------|--------|
| **Prerequisite Check** | Verifies Flutter, Python, Git, Visual Studio (Windows) | Fails early if missing |
| **Flutter Setup** | `flutter config --enable-windows-desktop` | Enables Windows target |
| **Get Dependencies** | `flutter pub get` in led_matrix_controller/ | Installs packages |
| **Build Release** | `flutter build windows --release` | Generates exe + runtime |
| **Install Deps** | `pip install -r TwinklyWall/requirements.txt` | Installs pygame, flask, etc. |
| **Build EXE** | `pyinstaller --onefile TwinklyWall/main.py` | Single-file executable |

## Output Locations

### Local Build
- **Flutter**: `led_matrix_controller/build/windows/x64/runner/Release/led_matrix_controller.exe`
- **Python**: `dist/TwinklyWall.exe`

### CI Build
- Download from GitHub Actions Artifacts:
  - `led_matrix_controller-windows-release/` (Flutter)
  - `TwinklyWall-exe/` (Python exe)

## Troubleshooting

**"Flutter SDK not found"**
- Install Flutter: https://flutter.dev/docs/get-started/install
- Add to PATH

**"Visual Studio not found"**
- Install Visual Studio 2022 with "Desktop development with C++"
- MSBuild must be on PATH

**"PyInstaller build failed"**
- Check `build/pyinstaller/` logs
- Run with `--debug` or `--verbose` flag (future enhancement)

**"GitHub Actions doesn't exist"**
- Workflows are in `.github/workflows/`
- Manually trigger: go to Actions → select workflow → Run workflow

## Next Steps
- Automate release artifacts (zip, signing)
- Add version tagging (`v1.0.0`)
- Sign exe files with certificates
