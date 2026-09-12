"""Exercise the status bar and custom controls in an isolated offscreen shell."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="note-note-statusbar-") as directory:
        work = Path(directory)
        (work / "app").symlink_to(ROOT, target_is_directory=True)
        shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
        for name in ("Commons", "Ui", "Services"):
            (work / name).symlink_to(shell / name, target_is_directory=True)
        (work / "shell.qml").write_text((ROOT / "tests/statusbar.qml").read_text())
        runtime = work / "runtime"
        runtime.mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(work), XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(work / "config"), XDG_CACHE_HOME=str(work / "cache"),
                   XDG_STATE_HOME=str(work / "state"), QT_QPA_PLATFORM="offscreen",
                   QT_QPA_PLATFORMTHEME="generic", QT_FORCE_STDERR_LOGGING="1")
        env.pop("WAYLAND_DISPLAY", None)
        try:
            proc = subprocess.run(["qs", "-p", str(work / "shell.qml"), "--no-color"],
                                  env=env, capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError) as error:
            print("FAILED:", error)
            return 1
        output = proc.stdout + proc.stderr
        if proc.returncode or "<<<RESULT>>>" not in output:
            print("FAILED: QML runtime\n" + output)
            return 1
        try:
            results = json.loads(output.split("<<<RESULT>>>")[1].split("<<<END>>>")[0])
        except (ValueError, IndexError) as error:
            print("FAILED: invalid QML result", error)
            return 1
        failed = [result for result in results if not result["ok"]]
        for result in failed:
            print("FAIL:", result["name"], result.get("detail", ""))
        noise = [line for line in output.splitlines()
                 if any(marker in line for marker in ("TypeError:", "ReferenceError:", "Binding loop",
                                                       "Unable to assign", "Error:", "ERROR", "QML"))
                 and "<<<RESULT>>>" not in line]
        if noise:
            failed.append({"name": "unexpected QML warnings or errors"})
            print("FAILED: unexpected QML diagnostics\n" + "\n".join(noise))
        if "-v" in sys.argv:
            print(output)
        print("%d/%d status bar scenarios passed" % (len(results) - len(failed), len(results)))
        return int(bool(failed))


if __name__ == "__main__":
    sys.exit(main())
