#!/usr/bin/env python3
"""
Windows build automation script for TwinklyWall project.

Builds:
  - led_matrix_controller (Flutter desktop app)
  - TwinklyWall (Python exe via PyInstaller)

Supports:
  - Local Windows builds (requires Windows host with prerequisites)
  - GitHub Actions CI trigger (recommended for WSL)

Usage:
  python build_windows.py --flutter         # Build Flutter only
  python build_windows.py --python          # Build Python exe only
  python build_windows.py --all             # Build both
  python build_windows.py --ci              # Trigger GitHub Actions (default)
  python build_windows.py --ci --flutter    # Trigger CI for Flutter only
  python build_windows.py --local --flutter # Local Windows build
"""

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple

# Colors for terminal output
class Color:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

    @staticmethod
    def disable():
        Color.HEADER = ''
        Color.OKBLUE = ''
        Color.OKCYAN = ''
        Color.OKGREEN = ''
        Color.WARNING = ''
        Color.FAIL = ''
        Color.ENDC = ''
        Color.BOLD = ''
        Color.UNDERLINE = ''


def log(msg: str, color: str = ''):
    """Print colored log message."""
    print(f"{color}{msg}{Color.ENDC}")


def run_cmd(cmd: list, cwd: Optional[str] = None, check: bool = True) -> Tuple[int, str, str]:
    """Run shell command and capture output."""
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode, result.stdout, result.stderr
    except Exception as e:
        log(f"Error running command: {' '.join(cmd)}", Color.FAIL)
        log(str(e), Color.FAIL)
        if check:
            sys.exit(1)
        return 1, '', str(e)


def check_flutter() -> bool:
    """Check if Flutter is installed."""
    flutter_cmd = 'flutter.bat' if platform.system() == 'Windows' else 'flutter'
    code, out, err = run_cmd([flutter_cmd, '--version'], check=False)
    if code == 0:
        log("✓ Flutter SDK found", Color.OKGREEN)
        print(out)
        return True
    else:
        log("✗ Flutter SDK not found", Color.FAIL)
        log("Install from https://flutter.dev/docs/get-started/install", Color.WARNING)
        return False


def check_python() -> bool:
    """Check if Python is available."""
    code, out, err = run_cmd([sys.executable, '--version'], check=False)
    if code == 0:
        log(f"✓ Python found: {out.strip()}", Color.OKGREEN)
        return True
    else:
        log("✗ Python not found", Color.FAIL)
        return False


def check_git() -> bool:
    """Check if git is available."""
    code, out, err = run_cmd(['git', '--version'], check=False)
    if code == 0:
        log(f"✓ Git found: {out.strip()}", Color.OKGREEN)
        return True
    else:
        log("✗ Git not found", Color.FAIL)
        return False


def check_chocolate() -> bool:
    """Check if Chocolatey package manager is installed."""
    code, out, err = run_cmd(['choco', '--version'], check=False)
    if code == 0:
        log("✓ Chocolatey found", Color.OKGREEN)
        return True
    else:
        log("✗ Chocolatey not found", Color.FAIL)
        return False


def install_chocolatey() -> bool:
    """Install Chocolatey package manager."""
    if check_chocolate():
        return True
    
    log("\nInstalling Chocolatey...", Color.OKCYAN)
    log("This requires administrator privileges", Color.WARNING)
    
    cmd = '''powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"'''
    code, out, err = run_cmd(cmd.split(), check=False)
    
    if code == 0:
        log("✓ Chocolatey installed successfully", Color.OKGREEN)
        return True
    else:
        log("✗ Failed to install Chocolatey", Color.FAIL)
        log("Install manually from https://chocolatey.org/install or run PowerShell as Administrator", Color.WARNING)
        return False


def install_ffmpeg() -> bool:
    """Install FFmpeg for screen capture."""
    code, _, _ = run_cmd(['ffmpeg', '-version'], check=False)
    if code == 0:
        log("✓ FFmpeg already installed", Color.OKGREEN)
        return True
    
    log("\nInstalling FFmpeg via Chocolatey...", Color.OKCYAN)
    code, out, err = run_cmd(['choco', 'install', 'ffmpeg', '-y'], check=False)
    
    if code == 0:
        log("✓ FFmpeg installed successfully", Color.OKGREEN)
        # Refresh PATH
        run_cmd(['refreshenv'], check=False)
        return True
    else:
        log("✗ Failed to install FFmpeg via Chocolatey", Color.FAIL)
        log("Install manually: https://ffmpeg.org/download.html", Color.WARNING)
        return False


def install_github_cli() -> bool:
    """Install GitHub CLI for CI triggering."""
    code, _, _ = run_cmd(['gh', '--version'], check=False)
    if code == 0:
        log("✓ GitHub CLI already installed", Color.OKGREEN)
        return True
    
    log("\nInstalling GitHub CLI via Chocolatey...", Color.OKCYAN)
    code, out, err = run_cmd(['choco', 'install', 'gh', '-y'], check=False)
    
    if code == 0:
        log("✓ GitHub CLI installed successfully", Color.OKGREEN)
        return True
    else:
        log("✗ Failed to install GitHub CLI", Color.FAIL)
        log("Install manually: https://cli.github.com/", Color.WARNING)
        return False


def check_visual_studio_windows() -> bool:
    """Check if Visual Studio is installed (Windows only)."""
    if platform.system() != 'Windows':
        return False
    
    # Check for MSBuild in known locations
    msbuild_paths = [
        r"C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        r"C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        r"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        r"C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        r"C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        r"C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
    ]
    
    for path in msbuild_paths:
        if Path(path).exists():
            log("✓ Visual Studio (MSBuild) found", Color.OKGREEN)
            return True
    
    log("✗ Visual Studio not found", Color.FAIL)
    log("Install Visual Studio 2022 with 'Desktop development with C++'", Color.WARNING)
    return False


def enable_flutter_windows() -> bool:
    """Enable Flutter Windows desktop support."""
    log("\nEnabling Flutter Windows desktop support...", Color.OKCYAN)
    flutter_cmd = 'flutter.bat' if platform.system() == 'Windows' else 'flutter'
    code, out, err = run_cmd([flutter_cmd, 'config', '--enable-windows-desktop'], check=False)
    if code == 0:
        log("✓ Windows desktop enabled", Color.OKGREEN)
        return True
    else:
        log("✗ Failed to enable Windows desktop", Color.FAIL)
        log(err, Color.WARNING)
        return False


def build_flutter_local(app_dir: str = 'led_matrix_controller') -> bool:
    """Build Flutter app locally on Windows."""
    app_path = Path(app_dir)
    if not app_path.exists():
        log(f"✗ App directory not found: {app_dir}", Color.FAIL)
        return False
    
    log(f"\n{Color.HEADER}Building Flutter app locally: {app_dir}{Color.ENDC}", Color.HEADER)
    
    flutter_cmd = 'flutter.bat' if platform.system() == 'Windows' else 'flutter'
    
    # Step 1: Get dependencies
    log("\n1. Fetching dependencies...", Color.OKCYAN)
    code, out, err = run_cmd([flutter_cmd, 'pub', 'get'], cwd=str(app_path), check=False)
    if code != 0:
        log("✗ Failed to fetch dependencies", Color.FAIL)
        log(err, Color.WARNING)
        return False
    log("✓ Dependencies fetched", Color.OKGREEN)
    
    # Step 2: Build release
    log("\n2. Building Windows release...", Color.OKCYAN)
    code, out, err = run_cmd(
        [flutter_cmd, 'build', 'windows', '--release'],
        cwd=str(app_path),
        check=False
    )
    if code != 0:
        log("✗ Build failed", Color.FAIL)
        log(err, Color.WARNING)
        return False
    
    log("✓ Build successful", Color.OKGREEN)
    output_dir = app_path / 'build' / 'windows' / 'x64' / 'runner' / 'Release'
    log(f"\nOutput directory: {output_dir}", Color.OKBLUE)
    
    if output_dir.exists():
        exe = output_dir / 'led_matrix_controller.exe'
        if exe.exists():
            log(f"✓ Executable found: {exe}", Color.OKGREEN)
        else:
            log(f"⚠ Executable not found at expected location", Color.WARNING)
    
    return True


def build_python_local(app_name: str = 'TwinklyWall') -> bool:
    """Build Python exe locally using PyInstaller."""
    app_dir = 'TwinklyWall'
    app_path = Path(app_dir)
    
    if not (app_path / 'main.py').exists():
        log(f"✗ main.py not found in {app_dir}", Color.FAIL)
        return False
    
    log(f"\n{Color.HEADER}Building Python exe: {app_name}{Color.ENDC}", Color.HEADER)
    
    # Step 1: Install dependencies
    log("\n1. Installing dependencies...", Color.OKCYAN)
    reqs = app_path / 'requirements.txt'
    if reqs.exists():
        code, out, err = run_cmd(
            [sys.executable, '-m', 'pip', 'install', '-r', str(reqs)],
            check=False
        )
        if code != 0:
            log("✗ Failed to install dependencies", Color.FAIL)
            log(err, Color.WARNING)
            return False
        log("✓ Dependencies installed", Color.OKGREEN)
    
    # Step 2: Install PyInstaller
    log("\n2. Installing PyInstaller...", Color.OKCYAN)
    code, out, err = run_cmd(
        [sys.executable, '-m', 'pip', 'install', 'pyinstaller'],
        check=False
    )
    if code != 0:
        log("✗ Failed to install PyInstaller", Color.FAIL)
        log(err, Color.WARNING)
        return False
    log("✓ PyInstaller installed", Color.OKGREEN)
    
    # Step 3: Build exe
    log("\n3. Building executable with PyInstaller...", Color.OKCYAN)
    cmd = [
        sys.executable, '-m', 'PyInstaller',
        '--onefile',
        f'{app_dir}/main.py',
        f'--name', app_name,
        f'--paths', app_dir,
        f'--add-data', f'{app_dir}/assets{os.pathsep}assets',
        f'--add-data', f'{app_dir}/dotmatrix/rendered_videos{os.pathsep}dotmatrix/rendered_videos',
        f'--add-data', f'{app_dir}/dotmatrix/Light Wall Mapping.csv{os.pathsep}dotmatrix',
    ]
    
    code, out, err = run_cmd(cmd, check=False)
    if code != 0:
        log("✗ PyInstaller build failed", Color.FAIL)
        log(err, Color.WARNING)
        return False
    
    log("✓ Build successful", Color.OKGREEN)
    exe_path = Path('dist') / f'{app_name}.exe'
    if exe_path.exists():
        size_mb = exe_path.stat().st_size / (1024 * 1024)
        log(f"✓ Executable created: {exe_path} ({size_mb:.1f} MB)", Color.OKGREEN)
    else:
        log(f"⚠ Executable not found at {exe_path}", Color.WARNING)
    
    return True


def get_repo_info():
    """Get GitHub repo owner and name from git remote."""
    code, out, err = run_cmd(['git', 'remote', 'get-url', 'origin'], check=False)
    if code != 0:
        log("✗ Could not get git remote URL", Color.FAIL)
        return None, None
    
    url = out.strip()
    # Handle SSH and HTTPS URLs
    if url.startswith('git@github.com:'):
        repo_path = url.split('git@github.com:')[1].rstrip('.git')
    elif url.startswith('https://github.com/'):
        repo_path = url.split('https://github.com/')[1].rstrip('.git')
    else:
        log(f"✗ Unsupported git remote URL format: {url}", Color.FAIL)
        return None, None
    
    if '/' not in repo_path:
        log(f"✗ Invalid repo path: {repo_path}", Color.FAIL)
        return None, None
    
    owner, repo = repo_path.split('/', 1)
    return owner, repo


def trigger_github_ci(target: str = 'all') -> bool:
    """Trigger GitHub Actions workflows."""
    log(f"\n{Color.HEADER}Triggering GitHub Actions CI{Color.ENDC}", Color.HEADER)
    
    workflows = {
        'flutter': 'flutter-windows.yml',
        'python': 'python-windows.yml',
        'all': None,  # Both
    }
    
    if target not in workflows:
        log(f"✗ Invalid target: {target}", Color.FAIL)
        return False
    
    # Get repo info
    owner, repo = get_repo_info()
    if not owner or not repo:
        return False
    
    actions_url = f"https://github.com/{owner}/{repo}/actions"
    
    # Check if gh CLI is available
    code, _, _ = run_cmd(['gh', '--version'], check=False)
    if code != 0:
        log("✗ GitHub CLI (gh) not found", Color.FAIL)
        log("Install from https://cli.github.com/ or trigger workflows manually in GitHub UI", Color.WARNING)
        log("\nTo install on Ubuntu/Debian:", Color.OKCYAN)
        log("curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg", Color.OKBLUE)
        log("sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg", Color.OKBLUE)
        log("echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null", Color.OKBLUE)
        log("sudo apt update && sudo apt install gh", Color.OKBLUE)
        log("\nThen authenticate: gh auth login", Color.OKBLUE)
        log(f"\nTo trigger manually:", Color.OKCYAN)
        log(f"1. Go to {actions_url}", Color.OKBLUE)
        log("2. Select 'Build Windows Flutter App' or 'Package TwinklyWall (Windows)'", Color.OKBLUE)
        log("3. Click 'Run workflow'", Color.OKBLUE)
        return False
    
    # Check if gh is authenticated
    code, out, err = run_cmd(['gh', 'auth', 'status'], check=False)
    if code != 0:
        log("✗ GitHub CLI not authenticated", Color.FAIL)
        log("Run: gh auth login", Color.WARNING)
        log("Then re-run this script", Color.WARNING)
        return False
    
    to_trigger = ['flutter-windows.yml', 'python-windows.yml'] if target == 'all' else [workflows[target]]
    
    for workflow in to_trigger:
        log(f"\nTriggering {workflow}...", Color.OKCYAN)
        cmd = ['gh', 'workflow', 'run', workflow]
        code, out, err = run_cmd(cmd, check=False)
        if code == 0:
            log(f"✓ Triggered {workflow}", Color.OKGREEN)
            log(out, Color.OKBLUE)
        else:
            log(f"✗ Failed to trigger {workflow}", Color.FAIL)
            log(err, Color.WARNING)
            return False
    
    log("\n✓ Workflows triggered! Monitor progress at:", Color.OKGREEN)
    log(actions_url, Color.OKBLUE)
    
    return True


def check_prerequisites_windows() -> bool:
    """Check all prerequisites for Windows builds."""
    log(f"\n{Color.HEADER}Checking prerequisites...{Color.ENDC}", Color.HEADER)
    
    checks = [
        ('Git', check_git),
        ('Python', check_python),
        ('Flutter SDK', check_flutter),
    ]
    
    if platform.system() == 'Windows':
        checks.append(('FFmpeg', lambda: run_cmd(['ffmpeg', '-version'], check=False)[0] == 0))
    
    results = {}
    for name, check_fn in checks:
        if check_fn():
            results[name] = True
        else:
            results[name] = False
    
    return all(results.values())


def install_prerequisites_windows() -> bool:
    """Install missing prerequisites for Windows builds."""
    if not platform.system() == 'Windows':
        log("\n✗ This function is for Windows only", Color.FAIL)
        return False
    
    log(f"\n{Color.HEADER}Installing missing prerequisites...{Color.ENDC}", Color.HEADER)
    
    # Check Chocolatey first
    if not check_chocolate():
        if not install_chocolatey():
            log("\n⚠ Chocolatey not available. Some installations may fail.", Color.WARNING)
            log("You can still try manual installations.", Color.WARNING)
    
    # Install FFmpeg
    if run_cmd(['ffmpeg', '-version'], check=False)[0] != 0:
        if not install_ffmpeg():
            log("⚠ FFmpeg installation failed. Screen capture will not work.", Color.WARNING)
    
    # GitHub CLI is optional
    if run_cmd(['gh', '--version'], check=False)[0] != 0:
        log("\nGitHub CLI is optional (for CI triggering). Install it?", Color.OKCYAN)
        log("Run 'choco install gh' manually if you want it later", Color.OKBLUE)
    
    # Visual Studio requires manual installation
    code, _, _ = run_cmd(['where', 'MSBuild.exe'], check=False)
    if code != 0:
        log("\n⚠ Visual Studio not found", Color.WARNING)
        log("Install Visual Studio 2022 with 'Desktop development with C++' component", Color.WARNING)
        log("Download from: https://visualstudio.microsoft.com/vs/", Color.OKBLUE)
        log("After installation, restart your terminal for changes to take effect", Color.WARNING)
        return False
    
    # Flutter requires manual installation
    if not check_flutter():
        log("\n⚠ Flutter SDK not found", Color.WARNING)
        log("Install from: https://flutter.dev/docs/get-started/install", Color.OKBLUE)
        log("After installation, add Flutter to PATH and restart your terminal", Color.WARNING)
        return False
    
    log("\n✓ Prerequisite checks complete", Color.OKGREEN)
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Build Windows binaries for TwinklyWall project',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  python build_windows.py --ci              # Trigger GitHub Actions (default for WSL)
  python build_windows.py --local --all     # Build both locally on Windows
  python build_windows.py --local --install-deps --all  # Install deps + build
  python build_windows.py --flutter         # Build Flutter only (CI)
  python build_windows.py --local --install-deps  # Just install prerequisites
        '''
    )
    
    parser.add_argument(
        '--ci',
        action='store_true',
        help='Trigger GitHub Actions workflows (default if not on Windows)'
    )
    parser.add_argument(
        '--local',
        action='store_true',
        help='Build locally on Windows (requires Windows host)'
    )
    parser.add_argument(
        '--flutter',
        action='store_true',
        help='Build Flutter app only'
    )
    parser.add_argument(
        '--python',
        action='store_true',
        help='Build Python exe only'
    )
    parser.add_argument(
        '--all',
        action='store_true',
        help='Build both Flutter and Python (default if neither --flutter nor --python)'
    )
    parser.add_argument(
        '--no-color',
        action='store_true',
        help='Disable colored output'
    )
    parser.add_argument(
        '--install-deps',
        action='store_true',
        help='Install missing prerequisites (Windows only)'
    )
    
    args = parser.parse_args()
    
    if args.no_color:
        Color.disable()
    
    # Determine build mode
    is_windows = platform.system() == 'Windows'
    use_local = args.local and is_windows
    use_ci = args.ci or not is_windows
    
    # Determine targets
    has_target = args.flutter or args.python
    build_flutter = args.flutter or args.all or not has_target
    build_python = args.python or args.all or not has_target
    
    log(f"\n{Color.BOLD}TwinklyWall Windows Build{Color.ENDC}", Color.HEADER)
    log(f"Platform: {platform.system()}", Color.OKBLUE)
    log(f"Build mode: {'Local (Windows)' if use_local else 'CI (GitHub Actions)'}", Color.OKBLUE)
    log(f"Targets: {', '.join([t for t, b in [('Flutter', build_flutter), ('Python', build_python)] if b])}", Color.OKBLUE)
    
    # Validate prerequisites
    if use_local:
        if not is_windows:
            log("\n✗ Local build only works on Windows", Color.FAIL)
            log("Use --ci to trigger GitHub Actions from WSL", Color.WARNING)
            sys.exit(1)
        
        # Install missing dependencies if requested
        if args.install_deps:
            if not install_prerequisites_windows():
                log("\n⚠ Some prerequisites are missing. Attempting build anyway...", Color.WARNING)
        elif not check_prerequisites_windows():
            log("\n💡 Tip: Use --install-deps to automatically install missing prerequisites", Color.OKCYAN)
            sys.exit(1)
        
        if not enable_flutter_windows():
            sys.exit(1)
    else:
        # Just check git for CI
        if not check_git():
            sys.exit(1)
    
    # Execute builds
    success = True
    
    if use_local:
        if build_flutter:
            if not build_flutter_local():
                success = False
        if build_python:
            if not build_python_local():
                success = False
    else:
        # CI mode
        target = 'all'
        if build_flutter and not build_python:
            target = 'flutter'
        elif build_python and not build_flutter:
            target = 'python'
        
        if not trigger_github_ci(target):
            success = False
    
    # Summary
    if success:
        log(f"\n{Color.BOLD}✓ Build process complete!{Color.ENDC}", Color.OKGREEN)
        if use_ci:
            log("Check GitHub Actions for build artifacts: https://github.com/your-org/TwinklyWall_Project/actions", Color.OKBLUE)
        else:
            log("Check 'build/' and 'dist/' directories for artifacts", Color.OKBLUE)
        return 0
    else:
        log(f"\n{Color.BOLD}✗ Build failed{Color.ENDC}", Color.FAIL)
        return 1


if __name__ == '__main__':
    sys.exit(main())
