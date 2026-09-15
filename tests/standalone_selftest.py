"""Exercise native Qt transport, the shared workspace and safe shutdown."""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for_marker(stream, marker, timeout=5):
    """Wait through startup diagnostics without buffering unread pipe output."""
    deadline = time.monotonic() + timeout
    output = b""
    while marker.encode() not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise RuntimeError("fixture did not become ready: " + output.decode(errors="replace"))
        chunk = os.read(stream.fileno(), 4096)
        if not chunk:
            raise RuntimeError("fixture exited before becoming ready: " + output.decode(errors="replace"))
        output += chunk
        if len(output) > 65536:
            raise RuntimeError("fixture produced excessive startup output: " + output[-4096:].decode(errors="replace"))
    return output.decode(errors="replace")


def check_window_close(binary, harness, env, host):
    command = [str(binary), "--qml", str(harness)]
    if not host:
        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
    display = os.environ.get("WAYLAND_DISPLAY")
    if not display:
        raise RuntimeError("--host requires a Wayland compositor")
    native_env = dict(env, QT_QPA_PLATFORM="wayland", NOTE_NOTE_TEST_WM_CLOSE="1",
                      WAYLAND_DISPLAY=str(Path(os.environ["XDG_RUNTIME_DIR"]) / display))
    with subprocess.Popen(command, env=native_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        try:
            startup = wait_for_marker(process.stderr, "<<<WM_CLOSE_READY>>>")
            clients = json.loads(subprocess.check_output(["hyprctl", "-j", "clients"], text=True, timeout=5))
            window = next((client for client in clients if client["pid"] == process.pid and client["mapped"]), None)
            if not window:
                raise RuntimeError("the close fixture has no mapped Wayland window")
            target = json.dumps("address:" + window["address"])
            # The same dispatcher as Omarchy's Super+W, scoped to our fixture.
            subprocess.run(["hyprctl", "dispatch", f"hl.dsp.window.close({{ window = {target} }})"],
                           check=True, capture_output=True, text=True, timeout=5)
            output, errors = process.communicate(timeout=5)
            return subprocess.CompletedProcess(command, process.returncode, output, startup + errors)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


def check_activation(launcher, work, env):
    """Use the real entry point and socket with a payload-free test window."""
    resources = work / "activation-resources"
    host = resources / "hosts/standalone"
    host.mkdir(parents=True)
    (resources / "Workspace.qml").write_text("// Resource directory marker for this launcher test.\n")
    (host / "Main.qml").write_text('''import QtQuick
import NoteNote.Native
QtObject {
  property var connection: Connections {
    target: Desktop
    function onActivationRequested() {
      console.error("<<<ACTIVATED>>>")
      Qt.quit()
    }
  }
  Component.onCompleted: console.error("<<<READY>>>")
}
''')
    command = [*launcher, "--data-dir", str(resources)]
    with subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as first:
        try:
            wait_for_marker(first.stderr, "<<<READY>>>")
            second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
            output, errors = first.communicate(timeout=5)
            if second.returncode or first.returncode or "<<<ACTIVATED>>>" not in errors:
                raise RuntimeError("second launch did not activate the first instance: " + output + errors + second.stderr)
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path, default=ROOT / "build/note-note")
    parser.add_argument("--resources", type=Path, default=ROOT)
    parser.add_argument("--host", action="store_true", help="also exercise Hyprland's window-close dispatcher on Wayland")
    args = parser.parse_args()
    binary = args.binary.resolve()
    resources = args.resources.resolve()
    with tempfile.TemporaryDirectory(prefix="note-note-standalone-") as directory:
        work = Path(directory)
        runtime = work / "runtime"
        runtime.mkdir(mode=0o700)
        notes = work / "notes"
        notes.mkdir()
        note = notes / "example.md"
        note.write_text("---\ntitle: Example\n---\nOriginal body\n")
        config = work / "config/notenote"
        config.mkdir(parents=True)
        (config / "config.json").write_text(json.dumps({"providers": {
            "local": {"enabled": True, "notesDir": str(notes)},
            "onenote": {"enabled": False}, "sticky": {"enabled": False}, "notion": {"enabled": False}}}))
        source = (ROOT / "tests/standalone.qml").read_text()
        source = source.replace('"app"', json.dumps(resources.as_uri()))
        source = source.replace('"app/', '"' + resources.as_uri() + '/')
        harness = work / "standalone.qml"
        harness.write_text(source)
        env = dict(os.environ, NOTE_NOTE_TEST_ROOT=str(resources), HOME=str(work), XDG_CONFIG_HOME=str(work / "config"),
                   XDG_STATE_HOME=str(work / "state"), XDG_CACHE_HOME=str(work / "cache"),
                   HOST_XDG_CONFIG_HOME=str(work / "config"), HOST_XDG_STATE_HOME=str(work / "state"),
                   XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM="offscreen",
                   DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(work / "no-session-bus"),
                   QT_QPA_PLATFORMTHEME="generic", QT_FORCE_STDERR_LOGGING="1", QT_QUICK_BACKEND="software")
        try:
            proc = subprocess.run([str(binary), "--qml", str(harness)], env=env,
                                  capture_output=True, text=True, timeout=45)
        except (OSError, subprocess.SubprocessError) as error:
            print("FAIL:", error)
            if isinstance(error, subprocess.TimeoutExpired):
                print(error.stdout, error.stderr)
            return 1
        output = proc.stdout + proc.stderr
        failed = proc.returncode != 0 or "<<<STANDALONE_DONE>>>" not in output or "FAIL!" in output
        diagnostics = [line for line in output.splitlines() if any(marker in line for marker in
                       ("TypeError:", "ReferenceError:", "Binding loop", "Unable to assign", "QML ", "Error:"))]
        if failed or diagnostics:
            print(output)
            return 1
        if "kept after failure" not in note.read_text():
            print("FAIL: the final close did not commit the draft")
            return 1
        state = work / "state/notenote/note-note.json"
        if not state.is_file() or state.stat().st_mode & 0o077:
            print("FAIL: private layout state was not saved")
            return 1
        if (work / "state/omarchy").exists() or (work / "cache/omarchy").exists():
            print("FAIL: standalone wrote into Omarchy storage")
            return 1
        shutil.copytree(ROOT / "examples/hello", config / "providers/hello")
        theme = work / "state/omarchy/current/theme"
        theme.mkdir(parents=True)
        (theme / "colors.toml").write_text("background='#182736'\nforeground='#e0e4e8'\naccent='#6090d0'\n")
        env["XDG_CURRENT_DESKTOP"] = "Hyprland"
        source = (ROOT / "tests/standalone_launch.qml").read_text()
        harness.write_text(source.replace('"app/', '"' + resources.as_uri() + '/'))
        try:
            proc = subprocess.run([str(binary), "--qml", str(harness)], env=env,
                                  capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError) as error:
            print("FAIL: application launch:", error)
            if isinstance(error, subprocess.TimeoutExpired):
                print(error.stdout, error.stderr)
            return 1
        output = proc.stdout + proc.stderr
        if proc.returncode or "<<<LAUNCH_DONE>>>" not in output or any(marker in output for marker in
                ("FAIL!", "TypeError:", "ReferenceError:", "Binding loop", "Unable to assign", "QML ", "Error:")):
            print(output)
            return 1
        try:
            source = (ROOT / "tests/standalone_close.qml").read_text()
            harness.write_text(source.replace('"app/', '"' + resources.as_uri() + '/'))
            proc = check_window_close(binary, harness, env, args.host)
            output = proc.stdout + proc.stderr
            if proc.returncode or "<<<CLOSE_DONE>>>" not in output or any(marker in output for marker in
                    ("FAIL!", "TypeError:", "ReferenceError:", "Binding loop", "Unable to assign", "QML ", "Error:")):
                print("FAIL: close during a background read:", output)
                return 1
            if "onenote" not in json.loads(state.read_text())["providers"]:
                print("FAIL: provider disposal overwrote the saved session")
                return 1
            check_activation([str(binary)], work, env)
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            print("FAIL: window close or instance activation:", error)
            return 1
        print("PASS: native process, clipboard, workspace, external provider, launcher, activation and shutdown checks")
        return 0


if __name__ == "__main__":
    sys.exit(main())
