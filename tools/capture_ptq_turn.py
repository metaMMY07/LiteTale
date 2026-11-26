"""Capture the native curl while ADB holds a landscape drag in progress.

Run after installing tools/ptq_visual_demo.dart on emulator-5554.
"""

import argparse
import re
import subprocess
import time
from pathlib import Path


ADB = r"D:\Codex-Migrated\Android\Sdk\platform-tools\adb.exe"
OUT = Path(__file__).resolve().parents[1] / "build" / "qa"


def dimensions():
    size = subprocess.check_output([ADB, "shell", "wm", "size"], text=True)
    match = re.search(r"(\d+)x(\d+)", size.splitlines()[-1])
    if match is None:
        raise RuntimeError(size)
    return sorted(map(int, match.groups()), reverse=True)


def capture(name):
    path = OUT / f"curl-{name}.png"
    with path.open("wb") as stream:
        subprocess.run([ADB, "exec-out", "screencap", "-p"], stdout=stream, check=True)
    print(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-y", type=float, default=0.78)
    parser.add_argument("--end-y", type=float, default=0.32)
    parser.add_argument("--label", default="bottom")
    parser.add_argument("--capture-delay", type=float, default=1.4)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    width, height = dimensions()
    time.sleep(3)
    capture(f"{args.label}-before")
    drag = subprocess.Popen(
        [
            ADB, "shell", "input", "swipe",
            str(int(width * 0.92)), str(int(height * args.start_y)),
            str(int(width * 0.20)), str(int(height * args.end_y)),
            "3000",
        ]
    )
    time.sleep(args.capture_delay)
    capture(f"{args.label}-mid")
    drag.wait(timeout=10)
    time.sleep(0.6)
    capture(f"{args.label}-after")


if __name__ == "__main__":
    main()
