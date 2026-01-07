#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import urlopen


def run(cmd, cwd=None, check=True, capture=False, sudo=False):
    if sudo and os.geteuid() != 0:
        cmd = ["sudo"] + cmd
    print("$", " ".join(cmd))
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def ensure_git_sync(repo_dir: Path, remote: str = "origin", branch: str = "master"):
    try:
        run(["git", "rev-parse", "--is-inside-work-tree"], cwd=repo_dir)
    except subprocess.CalledProcessError:
        print(f"Warning: {repo_dir} is not a git repo; skipping pull")
        return
    run(["git", "fetch", "--all", "--prune"], cwd=repo_dir)
    # Fast-forward only to avoid merge prompts while script runs
    run(["git", "pull", "--ff-only", remote, branch], cwd=repo_dir, check=False)


def ensure_venv(tw_dir: Path, python_bin: str = sys.executable):
    venv_dir = tw_dir / ".venv"
    if not venv_dir.exists():
        run([python_bin, "-m", "venv", ".venv"], cwd=tw_dir)
    pip = venv_dir / "bin" / "pip"
    run([str(pip), "install", "--upgrade", "pip"], cwd=tw_dir)
    req = tw_dir / "requirements.txt"
    if req.exists():
        run([str(pip), "install", "-r", str(req)], cwd=tw_dir)
    else:
        print("No requirements.txt found; skipping dependency install")
    return venv_dir


def install_service(tw_dir: Path, service_name: str = "twinklywall"):
    unit_src = tw_dir / "twinklywall.service"
    unit_dst = Path("/etc/systemd/system") / f"{service_name}.service"
    if not unit_src.exists():
        raise FileNotFoundError(f"Missing service file: {unit_src}")
    # Copy unit and reload systemd
    run(["cp", str(unit_src), str(unit_dst)], sudo=True)
    run(["systemctl", "daemon-reload"], sudo=True)
    run(["systemctl", "enable", service_name], sudo=True, check=False)


def install_ddp_bridge_service(tw_dir: Path, service_name: str = "ddp_bridge"):
    unit_src = tw_dir / "ddp_bridge.service"
    unit_dst = Path("/etc/systemd/system") / f"{service_name}.service"
    if not unit_src.exists():
        raise FileNotFoundError(f"Missing service file: {unit_src}")
    run(["cp", str(unit_src), str(unit_dst)], sudo=True)
    run(["systemctl", "daemon-reload"], sudo=True)
    run(["systemctl", "enable", service_name], sudo=True, check=False)


def restart_service(service_name: str = "twinklywall"):
    run(["systemctl", "restart", service_name], sudo=True)
    # Small delay for Flask to bind
    time.sleep(2)


def wait_for_health(timeout_sec: int = 20, url: str = "http://localhost:5000/api/health"):
    start = time.time()
    last_err = None
    while time.time() - start < timeout_sec:
        try:
            with urlopen(url, timeout=2) as r:
                body = r.read().decode("utf-8", errors="ignore")
                if "ok" in body:
                    print("Health check OK:", body)
                    return True
        except Exception as e:
            last_err = e
        time.sleep(1)
    if last_err:
        print("Health check failed:", last_err)
    return False


def has_rendered_videos(tw_dir: Path) -> bool:
    rendered = list((tw_dir / "dotmatrix" / "rendered_videos").glob("*.npz"))
    return len(rendered) > 0


def render_all_sources(tw_dir: Path, venv_dir: Path, width: int = 90, height: int = 50, fps: int = 20):
    src_dir = tw_dir / "assets" / "source_videos"
    if not src_dir.exists():
        print(f"No source_videos directory at {src_dir}; skipping render")
        return
    videos = sorted([p for p in src_dir.iterdir() if p.is_file()])
    if not videos:
        print("No source videos found; skipping render")
        return
    py = venv_dir / "bin" / "python"
    for p in videos:
        print(f"Rendering: {p.name}")
        run([str(py), "video_renderer.py", str(p), str(fps), str(width), str(height)], cwd=tw_dir)


def main():
    parser = argparse.ArgumentParser(description="Setup/Restart TwinklyWall on FPP")
    parser.add_argument("--branch", default="master", help="Git branch to pull")
    parser.add_argument("--service", default="twinklywall", help="systemd service name")
    parser.add_argument("--render-all", action="store_true", help="Render all assets if none are rendered")
    parser.add_argument("--skip-pull", action="store_true", help="Skip git pull step")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]  # TwinklyWall_Project
    tw_dir = Path(__file__).resolve().parent         # TwinklyWall

    print("== Ensuring repository is up to date ==")
    if not args.skip_pull:
        ensure_git_sync(repo_root, branch=args.branch)
    else:
        print("Skipping git pull as requested")

    print("\n== Ensuring Python venv and dependencies ==")
    venv_dir = ensure_venv(tw_dir)

    print("\n== Installing/Updating systemd service ==")
    install_service(tw_dir, service_name=args.service)

    print("\n== Installing/Updating DDP bridge service ==")
    install_ddp_bridge_service(tw_dir, service_name="ddp_bridge")

    print("\n== Restarting service ==")
    restart_service(service_name=args.service)

    print("\n== Restarting DDP bridge service ==")
    restart_service(service_name="ddp_bridge")

    print("\n== Waiting for API health ==")
    ok = wait_for_health()
    if not ok:
        print("ERROR: API did not become healthy; run 'journalctl -u' for details")
        sys.exit(1)

    if args.render_all and not has_rendered_videos(tw_dir):
        print("\n== Rendering all source videos (none detected) ==")
        render_all_sources(tw_dir, venv_dir)
        print("Render step complete.")
    else:
        print("\nRendered videos present or render step skipped.")

    print("\nAll set. API is running at http://localhost:5000")
    print("DDP bridge listening on UDP :4049 → Pixel Overlay Light_Wall")
    print("Tip: You can target the bridge by sending DDP frames to port 4049.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Interrupted.")
        sys.exit(130)
