"""The clipboard, read for the editor: its image saved where the editor can
show it, its text for the plain paste.

    python3 clipboard.py types              -> {"types": ["image/png", …]}
    python3 clipboard.py image <dir>        -> {"path": …, "mime": …, "bytes": n}
    python3 clipboard.py text               -> {"text": "…"}

Wayland keeps the clipboard in the compositor, so this shells out to
`wl-paste`. Only real image types are accepted, the read is bounded, and an
image too large for the backends is scaled down rather than refused — a
pasted screenshot is usually far bigger than anything a note needs.
"""
import json
import os
import subprocess
import sys
import time

# What a backend will accept from us, and what a paste may cost on the way in.
MIME_SUFFIX = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif",
               "image/bmp": ".bmp", "image/tiff": ".tiff"}
MAX_CLIPBOARD = 40 * 1024 * 1024     # what we will read at all
MAX_TEXT = 4 * 1024 * 1024           # a paste of text past this is not a note
MAX_STAGED = 40                      # pasted files kept before the oldest go
MAX_STAGED_AGE = 7 * 24 * 3600       # a paste that never reached a backend
MAX_STORED = 3 * 1024 * 1024         # what fits in one Graph request
MAX_WIDTH = 1600                     # a screenshot is wider than any note needs
MAGICK_TIMEOUT = 10


def out(obj):
    sys.stdout.write(json.dumps(obj))


def types():
    try:
        listed = subprocess.run(["wl-paste", "--list-types"], capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return []
    return [t.strip() for t in listed.stdout.decode("utf-8", "replace").split("\n") if t.strip()]


def image_type(available):
    for mime in MIME_SUFFIX:
        if mime in available:
            return mime
    return ""


def scaled(path, magick):
    """Bring a pasted screenshot down to something a note can carry."""
    if os.path.getsize(path) <= MAX_STORED or not magick:
        return
    scaled_path = path + ".out"
    try:
        subprocess.run([magick, "-limit", "memory", "128MiB", "-limit", "map", "256MiB",
                        "-limit", "area", "50MP", "-limit", "time", str(MAGICK_TIMEOUT),
                        path + "[0]", "-resize", "%dx>" % MAX_WIDTH, "png:" + scaled_path],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=MAGICK_TIMEOUT + 5)
        if os.path.exists(scaled_path) and 0 < os.path.getsize(scaled_path) < os.path.getsize(path):
            os.chmod(scaled_path, 0o600)
            os.replace(scaled_path, path)
    except (subprocess.TimeoutExpired, OSError):
        pass
    finally:
        try:
            os.remove(scaled_path)
        except OSError:
            pass


def prune(directory):
    """A paste is staged only until the backend has it; old ones are ours to
    clear, and the directory must not grow without limit."""
    try:
        names = [n for n in os.listdir(directory) if n.startswith("paste-")]
    except OSError:
        return
    now = time.time()
    files = []
    for name in names:
        path = os.path.join(directory, name)
        try:
            files.append((os.stat(path).st_mtime, path))
        except OSError:
            continue
    files.sort(reverse=True)
    for index, (mtime, path) in enumerate(files):
        if index >= MAX_STAGED or now - mtime > MAX_STAGED_AGE:
            try:
                os.remove(path)
            except OSError:
                pass


def save_image(directory):
    mime = image_type(types())
    if not mime:
        return {"error": "the clipboard holds no image"}
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, "paste-%d%s" % (int(time.time() * 1000), MIME_SUFFIX[mime]))
    try:
        proc = subprocess.run(["wl-paste", "--type", mime], capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as error:
        return {"error": "could not read the clipboard: %s" % error}
    data = proc.stdout
    if not data:
        return {"error": "the clipboard image was empty"}
    if len(data) > MAX_CLIPBOARD:
        return {"error": "the clipboard image is too large"}
    # Owner-only, and never through a path someone else could have replaced.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    import shutil
    scaled(path, shutil.which("magick") or shutil.which("convert"))
    prune(directory)
    return {"path": path, "mime": mime, "bytes": os.path.getsize(path)}


def clipboard_text():
    """The clipboard's text flavour, for the plain paste (Ctrl+Shift+V).
    "text" is wl-paste's own shorthand for any text type on offer; a
    clipboard holding none (an image, nothing) answers with empty text —
    the ordinary case, not a failure."""
    available = types()
    if not any(t.startswith("text/") or t in ("TEXT", "STRING", "UTF8_STRING") for t in available):
        return {"text": ""}
    try:
        proc = subprocess.run(["wl-paste", "--no-newline", "--type", "text"],
                              capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        return {"error": "could not read the clipboard: %s" % error}
    if len(proc.stdout) > MAX_TEXT:
        return {"error": "the clipboard text is too large"}
    return {"text": proc.stdout.decode("utf-8", "replace")}


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "types":
        out({"types": types(), "image": image_type(types())})
    elif command == "image" and len(argv) >= 3:
        out(save_image(argv[2]))
    elif command == "text":
        out(clipboard_text())
    else:
        out({"error": "usage: clipboard.py types | image <dir> | text"})
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
