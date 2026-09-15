"""Package an existing Release build and the Omarchy plugin into versioned archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ROOTS = {"assets", "cpp", "design", "lib", "providers", "services", "ui"}
PLUGIN_FILES = {"manifest.json", "Workspace.qml", "LICENSE", "NOTICE.md"}


def run(command, **kwargs):
    return subprocess.run(command, check=True, cwd=ROOT, **kwargs)


def output(command):
    return run(command, capture_output=True, text=True).stdout.strip()


def tracked_files():
    return [Path(name) for name in output(["git", "ls-files", "-z"]).split("\0") if name]


def plugin_file(path):
    if path.name.startswith(".") or "selftest" in path.name:
        return False
    if path.parts[:2] == ("services", "theme"):
        return False
    return path.name in PLUGIN_FILES or path.parts[0] in PLUGIN_ROOTS or path.parts[:2] == ("hosts", "omarchy")


def archive(directory, destination, timestamp):
    # Sorted members and normalized ownership/timestamps keep identical
    # staged contents independent of the build user's home and identity.
    with tarfile.open(destination, "w:xz", format=tarfile.PAX_FORMAT) as package:
        for path in [directory] + sorted(directory.rglob("*")):
            info = package.gettarinfo(str(path), str(path.relative_to(directory.parent)))
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = timestamp
            if info.isfile():
                with path.open("rb") as source:
                    package.addfile(info, source)
            else:
                package.addfile(info)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/release")
    parser.add_argument("--output", type=Path, default=ROOT / "build/dist")
    args = parser.parse_args()
    build = args.build_dir.resolve()
    metadata = json.loads((build / "note-note-build.json").read_text())
    cache = (build / "CMakeCache.txt").read_text()
    if "CMAKE_BUILD_TYPE:STRING=Release\n" not in cache:
        parser.error("configure --build-dir with -DCMAKE_BUILD_TYPE=Release first")
    manifest = json.loads((ROOT / "manifest.json").read_text())
    version = manifest["version"]
    binary_version = run([str(build / "note-note"), "--version"], capture_output=True, text=True,
                         env=dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic")).stdout.strip()
    if binary_version != "note-note " + version:
        parser.error("the executable and manifest versions do not match")
    commit = output(["git", "rev-parse", "HEAD"])
    timestamp = int(os.environ.get("SOURCE_DATE_EPOCH", output(["git", "show", "-s", "--format=%ct", "HEAD"])))
    destination = args.output.resolve() / version
    destination.mkdir(parents=True, exist_ok=True)
    native_name = f"note-note-{version}-linux-{metadata['architecture']}"
    plugin_name = f"note-note-{version}-omarchy"
    metadata.update({
        "commit": commit,
        "working_tree_modified": bool(output(["git", "diff", "HEAD", "--name-only"])),
    })
    with tempfile.TemporaryDirectory(prefix="package-", dir=destination) as temporary:
        stage = Path(temporary)
        native = stage / native_name
        run(["cmake", "--install", str(build), "--prefix", str(native), "--strip"], stdout=subprocess.DEVNULL)
        (native / "BUILD-INFO.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (native / "INSTALL.md").write_text(
            "# Note Note standalone\n\n"
            f"Release {version}, built with Qt {metadata['qt_version']} on {metadata['architecture']}.\n\n"
            "Run `./bin/note-note` from this directory, or copy `bin/` and `share/`\n"
            "into the same installation prefix, such as `~/.local/`. Keep both together.\n\n"
            "This native build uses your system libraries. It needs a compatible\n"
            "Qt runtime (Quick, Quick Controls 2, Network, DBus, SVG and Wayland/X11),\n"
            "Python 3.9+ and inotify-tools. ImageMagick is optional for large images.\n"
            "It is not a self-contained cross-distribution bundle.\n\n"
            f"Sources: https://github.com/andreivinca/note-note/tree/{commit}\n")
        # Test the installed, stripped layout, including resource lookup,
        # clipboard, saves, window-close handling and activation.
        run(["python3", "tests/standalone_selftest.py", str(native / "bin/note-note"),
             "--resources", str(native / "share/note-note")],
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        plugin = stage / plugin_name
        for path in tracked_files():
            if plugin_file(path):
                target = plugin / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / path, target)
        (plugin / "INSTALL.md").write_text(
            "# Note Note Omarchy plugin\n\n"
            f"Release {version}. Requires Omarchy 4 / Quickshell, Python 3.9+,\n"
            "inotify-tools and wl-clipboard.\n\n"
            f"Place this directory at `~/.config/omarchy/plugins/{manifest['id']}`\n"
            f"and enable it with `omarchy plugin enable {manifest['id']}`.\n\n"
            "The archive contains the shared application and Omarchy host, without\n"
            "a standalone executable. To enable the optional native text inspector,\n"
            "run `sh cpp/build.sh` inside the plugin directory using your system Qt\n"
            "development packages, then restart the shell. The editor has a script\n"
            "fallback when the module is not built.\n\n"
            "For managed updates, install from the Git repository instead of this archive.\n")
        run(["omarchy", "plugin", "validate", str(plugin)])
        artifacts = []
        for directory in (native, plugin):
            target = destination / (directory.name + ".tar.xz")
            archive(directory, target, timestamp)
            artifacts.append(target)
        checksums = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n" for path in artifacts)
        (destination / "SHA256SUMS").write_text(checksums)
        (destination / "BUILD-INFO.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for path in artifacts:
        print(path)
    print(destination / "SHA256SUMS")


if __name__ == "__main__":
    main()
