"""Read one regular file, bounded: no symlinks, no special files, no waiting.

The safe shape of "read a user-writable path" (docs/security.md, rule 9):
open once with O_NOFOLLOW — a symlink is refused by the kernel, so the bytes
can only be the named file's own — and O_NONBLOCK, so opening a FIFO returns
instead of blocking until a writer appears; then fstat the descriptor and
refuse anything that is not a regular file; then read at most `cap` bytes
from that same descriptor against a wall-clock deadline. The caller passes
a cap in bytes. Editable documents use read_document, which rejects overflow
and preserves errors; best-effort listing/search prefixes use read_capped.

    python3 readfile.py --json <path> <capBytes>  # complete document or error
    python3 readfile.py <path> <capBytes>         # best-effort raw prefix

Also imported by providers/local/list.py for every file the listing touches.
"""
import contextlib
import json
import os
import stat
import sys
import time

DEADLINE = 5.0  # seconds; a regular file that cannot be read in this is gone


@contextlib.contextmanager
def open_regular(path):
    """Open a regular file without following a symlink or waiting on a FIFO."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        with os.fdopen(fd, "rb") as handle:
            fd = None
            yield handle
    finally:
        if fd is not None:
            os.close(fd)


def read_bytes(handle, cap, deadline):
    out = bytearray()
    while len(out) < cap:
        if time.monotonic() > deadline:
            raise TimeoutError("file read timed out")
        chunk = handle.read(min(65536, cap - len(out)))
        if not chunk:
            break
        out += chunk
    return bytes(out)


def read_capped(path, cap, deadline=None):
    """Best-effort prefix for listings and searches; never use to load a note.

    Call read_document when an empty file must be distinguished from failure.
    """
    if deadline is None:
        deadline = time.monotonic() + DEADLINE
    try:
        with open_regular(path) as handle:
            return read_bytes(handle, cap, deadline)
    except OSError:
        return b""


def read_document(path, cap):
    """A complete UTF-8 document, with failures and byte limits kept explicit."""
    try:
        with open_regular(path) as handle:
            before = os.fstat(handle.fileno())
            raw = read_bytes(handle, cap + 1, time.monotonic() + DEADLINE)
            after = os.fstat(handle.fileno())
        if len(raw) > cap:
            return {"error": "file exceeds the %d byte limit" % cap, "kind": "too-large"}
        if (before.st_mtime_ns, before.st_size) != (after.st_mtime_ns, after.st_size):
            return {"error": "file changed while it was being read", "kind": "changed"}
        return {"ok": True, "text": raw.decode("utf-8"), "bytes": len(raw),
                "version": str(after.st_mtime_ns)}
    except FileNotFoundError:
        return {"error": "file does not exist", "kind": "missing"}
    except UnicodeError:
        return {"error": "file is not valid UTF-8", "kind": "invalid-encoding"}
    except OSError as error:
        return {"error": str(error), "kind": "unreadable"}


if __name__ == "__main__":
    if sys.argv[1] == "--json":
        json.dump(read_document(sys.argv[2], int(sys.argv[3])), sys.stdout)
    else:
        sys.stdout.buffer.write(read_capped(sys.argv[1], int(sys.argv[2])))
