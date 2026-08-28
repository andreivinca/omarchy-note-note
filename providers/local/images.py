"""Pasted images moved into the notebook, before a note is written.

The editor pastes a picture as `![](file:///…/note-note-paste/…)` — a file
staged in the cache, pruned after a while (services/clipboard). A local note
has to outlive that, so on save every image link that points into the staging
directory is copied to `.assets/` beside the note and the link becomes
relative (`.assets/name.png`), which the editor resolves through the
document's base URL. Links pointing anywhere else are the note's own
business and are left exactly as written.

    python3 images.py <notesDir> <noteFile>      # body on stdin, JSON out:
                                                 # {"body": …[, "warning": …]}

The body arrives on stdin, never argv (docs/security.md rule 2). Staged
files are read through readfile.py (no symlinks, regular files only, capped,
against a deadline) and written with O_EXCL, so a name in `.assets` is never
overwritten: the same bytes reuse it, different bytes take the next name.
Re-copying is idempotent on purpose — autosave runs this every few hundred
milliseconds while the staged link is still in the editor's document.
"""
import json
import os
import re
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from readfile import read_capped  # noqa: E402

# Where the clipboard service stages pastes (services/clipboard/Clipboard.qml).
STAGING = os.path.join(os.path.expanduser("~"), ".cache", "omarchy", "note-note-paste")
ASSETS = ".assets"
MAX_BODY = 4 * 1024 * 1024        # over the provider's own note cap
MAX_IMAGE = 40 * 1024 * 1024      # what the clipboard stages at most
MAX_SAME_NAME = 100               # distinct contents under one pasted name
DEADLINE = 15.0                   # seconds for the whole save's copies

# An image link whose target is a file:// URL. The alt text sits outside the
# parentheses and is not touched; neither is a `{width=N}` after the link.
FILE_LINK = re.compile(r"\]\((file://[^)\s]+)\)")


def fail(message):
    json.dump({"error": message}, sys.stdout)
    sys.exit(0)


def place(data, name, assets):
    """The name `data` is stored under in `assets`: the given name when it is
    free or already holds these very bytes, the next numbered one otherwise.
    Returns "" when nothing fits (all names taken by other bytes)."""
    base, ext = os.path.splitext(name)
    candidates = [name] + ["%s-%d%s" % (base, n, ext) for n in range(2, MAX_SAME_NAME)]
    for candidate in candidates:
        dest = os.path.join(assets, candidate)
        try:
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o644)
        except FileExistsError:
            if read_capped(dest, len(data) + 1) == data:
                return candidate                 # an earlier save already put it here
            continue
        except OSError:
            return ""
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        return candidate
    return ""


def main():
    if len(sys.argv) < 3:
        fail("usage: images.py <notesDir> <noteFile>")
    notes_dir = os.path.realpath(sys.argv[1])
    note_file = os.path.realpath(sys.argv[2])
    if os.path.commonpath([notes_dir, note_file]) != notes_dir:
        fail("the note is not inside the notes directory")
    body = sys.stdin.buffer.read(MAX_BODY + 1)
    if len(body) > MAX_BODY:
        fail("the note is too large")
    body = body.decode("utf-8", "replace")

    note_dir = os.path.dirname(note_file)
    deadline = time.monotonic() + DEADLINE
    moved = {}                                   # staged url -> relative link
    failed = []

    def replace(match):
        url = match.group(1)
        path = urllib.parse.unquote(url[len("file://"):])
        if os.path.dirname(path) != STAGING:
            return match.group(0)                # not staged: not ours to move
        if url in moved:
            return "](%s)" % moved[url] if moved[url] else match.group(0)
        name = ""
        data = read_capped(path, MAX_IMAGE, deadline)
        if data:
            assets = os.path.join(note_dir, ASSETS)
            try:
                os.makedirs(assets, exist_ok=True)
            except OSError:
                data = b""
            else:
                name = place(data, os.path.basename(path), assets)
        moved[url] = "%s/%s" % (ASSETS, name) if name else ""
        if not name:
            failed.append(path)
            return match.group(0)                # the staged link still shows
        return "](%s)" % moved[url]

    result = {"body": FILE_LINK.sub(replace, body)}
    if failed:
        result["warning"] = "a pasted image could not be copied into the notebook"
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
