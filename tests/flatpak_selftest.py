"""Verify the installed Flatpak runtime and activation across separate sandboxes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from standalone_selftest import check_activation

ROOT = Path(__file__).resolve().parents[1]
APP_ID = json.loads((ROOT / "packaging/io.github.andreivinca.note-note.json").read_text())["app-id"]


def main():
    try:
        running = subprocess.check_output(["flatpak", "ps", "--columns=application"], text=True, timeout=10)
        if APP_ID in running.splitlines():
            print("FAIL: close the running Note Note Flatpak before testing activation")
            return 1
        subprocess.run([
            "flatpak", "run", "--command=python3", f"--filesystem={ROOT}:ro",
            "--nofilesystem=~/Notes", "--unshare=network", "--env=PYTHONDONTWRITEBYTECODE=1",
            APP_ID, str(ROOT / "tests/standalone_selftest.py"),
            "/app/bin/note-note", "--resources", "/app/share/note-note",
        ], check=True, timeout=120)
        with tempfile.TemporaryDirectory(prefix="note-note-flatpak-") as directory:
            work = Path(directory)
            # Each invocation creates a separate Flatpak sandbox. The test
            # entry point has no workspace, notes, settings or account access.
            launcher = [
                "flatpak", "run", f"--filesystem={work}:ro", "--nofilesystem=~/Notes",
                "--unshare=network", "--env=QT_QPA_PLATFORM=offscreen",
                "--env=QT_QPA_PLATFORMTHEME=generic", "--env=QT_QUICK_BACKEND=software", APP_ID,
            ]
            check_activation(launcher, work, os.environ.copy())
        print("PASS: Flatpak runtime and activation across separate launches")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("FAIL:", error)
        return 1


if __name__ == "__main__":
    sys.exit(main())
