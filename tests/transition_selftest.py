"""Run the actual QML controllers, editor and local provider in an isolated shell."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="note-note-transitions-") as directory:
        work = Path(directory)
        (work / "app").symlink_to(ROOT, target_is_directory=True)
        tool_ui = work / "ui"
        shutil.copytree(ROOT / "ui/tools", tool_ui / "tools")
        (tool_ui / "editing").symlink_to(ROOT / "ui/editing", target_is_directory=True)
        (tool_ui / "Dialect.js").symlink_to(ROOT / "ui/Dialect.js")
        greeting = (ROOT / "tests/InsertGreeting.qml").read_text().replace('"../ui/editing"', '"../editing"')
        (tool_ui / "tools/InsertGreeting.qml").write_text(greeting)
        invalid_tools = tool_ui / "invalid-tools"
        invalid_tools.mkdir()
        definitions = {
            "Good": 'toolId: "okay"; label: "Okay"',
            "DuplicateOne": 'toolId: "duplicate"; label: "First"',
            "DuplicateTwo": 'toolId: "duplicate"; label: "Second"',
            "ReservedShortcut": 'toolId: "reserved"; label: "Reserved"; shortcutKey: Qt.Key_N; '
                                'shortcutModifiers: Qt.ControlModifier; shortcutLabel: "ctrl+n"',
            "ReservedUndo": 'toolId: "undo"; label: "Undo"; shortcutKey: Qt.Key_Z; '
                            'shortcutModifiers: Qt.ControlModifier; shortcutLabel: "ctrl+z"',
            "MenuShortcut": 'toolId: "menuShortcut"; label: "Menu"; isMenu: true; '
                            'shortcutKey: Qt.Key_G; shortcutLabel: "g"',
            "Incomplete": 'label: "Incomplete"',
        }
        for name, properties in definitions.items():
            (invalid_tools / (name + ".qml")).write_text(
                'import QtQuick\nimport "../editing"\nTool {\n  ' + properties + '\n}\n')
        shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
        for name in ("Commons", "Ui", "Services"):
            if (shell / name).is_dir():
                (work / name).symlink_to(shell / name, target_is_directory=True)
        source = (ROOT / "tests/transitions.qml").read_text()
        source = source.replace('"app/', '"file:' + str(ROOT) + '/')
        (work / "shell.qml").write_text(source)
        config = work / ".config/notenote"
        config.mkdir(parents=True)
        (config / "config.json").write_text(json.dumps({"providers": {
            name: {"enabled": False} for name in ("local", "notion", "onenote", "sticky")}}))
        (work / "notes").mkdir()
        (work / "notes/Broken").write_text("a file, not a notebook")
        (work / "notes/External.md").write_text("---\ntitle: External original\n---\noriginal")
        (work / "notes/Large.md").write_text("漢" * 700000, encoding="utf-8")
        staging = work / ".cache/omarchy/note-note-paste"
        staging.mkdir(parents=True)
        (staging / "image.png").write_bytes(b"synthetic image bytes")
        runtime = work / "runtime"
        runtime.mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(work), XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(work / "config"), XDG_CACHE_HOME=str(work / "cache"),
                   XDG_STATE_HOME=str(work / "state"), NOTE_NOTE_TEST_DIR=str(work / "notes"),
                   NOTE_NOTE_TEST_TOOLS=(tool_ui / "tools").as_uri(),
                   NOTE_NOTE_TEST_INVALID_TOOLS=invalid_tools.as_uri(),
                   NOTE_NOTE_TEST_TOOLS_ONLY="1" if "--tools" in sys.argv else "",
                   QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic", QT_FORCE_STDERR_LOGGING="1")
        env.pop("WAYLAND_DISPLAY", None)
        if "--host" in sys.argv:
            display = os.environ.get("WAYLAND_DISPLAY")
            if not display:
                print("FAILED: --host requires a Wayland compositor")
                return 1
            env["WAYLAND_DISPLAY"] = str(Path(os.environ["XDG_RUNTIME_DIR"]) / display)
            env["QT_QPA_PLATFORM"] = "wayland"
            env["NOTE_NOTE_TEST_HOST"] = "1"
        try:
            proc = subprocess.run(["qs", "-p", str(work / "shell.qml"), "--no-color"],
                                  env=env, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired as error:
            print("FAILED:", error)
            for captured in (error.stdout, error.stderr):
                if captured:
                    text = captured.decode(errors="replace") if isinstance(captured, bytes) else captured
                    print(text[-8000:])
            return 1
        except (OSError, subprocess.SubprocessError) as error:
            print("FAILED:", error)
            return 1
        output = proc.stdout + proc.stderr
        if proc.returncode or "<<<RESULT>>>" not in output:
            print("FAILED: QML runtime\n" + output[-8000:])
            return 1
        try:
            results = json.loads(output.split("<<<RESULT>>>")[1].split("<<<END>>>")[0])
        except (ValueError, IndexError) as error:
            print("FAILED: invalid QML result", error)
            return 1
        failed = [result for result in results if not result["ok"]]
        for result in failed:
            print("FAIL:", result["name"], result["detail"])
        noise = [line for line in output.splitlines()
                 if any(marker in line for marker in ("TypeError:", "ReferenceError:", "Binding loop", "Unable to assign", "Error:", "ERROR"))
                 and "<<<RESULT>>>" not in line]
        if noise:
            failed.append({"name": "unexpected QML errors"})
            print("FAILED: unexpected QML errors\n" + "\n".join(noise))
        if failed or "-v" in sys.argv:
            print(output[-8000:])
        print("%d/%d transition checks" % (len(results) - len(failed), len(results)))
        return int(bool(failed))


if __name__ == "__main__":
    sys.exit(main())
