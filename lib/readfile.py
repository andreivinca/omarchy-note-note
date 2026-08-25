"""Read one regular file, bounded: no symlinks, no special files, no waiting.

The safe shape of "read a user-writable path" (docs/security.md, rule 9):
open once with O_NOFOLLOW — a symlink is refused by the kernel, so the bytes
can only be the named file's own — and O_NONBLOCK, so opening a FIFO returns
instead of blocking until a writer appears; then fstat the descriptor and
refuse anything that is not a regular file; then read at most `cap` bytes
from that same descriptor against a wall-clock deadline. The caller passes
cap+1 and treats a full read as "too large" (rule 1).

    python3 readfile.py <path> <capBytes>       # bytes on stdout; empty on
                                                # missing/refused/expired

Also imported by providers/local/list.py for every file the listing touches.
"""
import os
import stat
import sys
import time

DEADLINE = 5.0  # seconds; a regular file that cannot be read in this is gone


def read_capped(path, cap, deadline=None):
    """At most `cap` bytes of the regular file at `path`, or b"" when it is
    missing, a symlink, not a regular file, or cannot be read before
    `deadline` (an absolute time.monotonic() value)."""
    if deadline is None:
        deadline = time.monotonic() + DEADLINE
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return b""
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return b""
        out = bytearray()
        while len(out) < cap:
            if time.monotonic() > deadline:
                return b""          # a read that cannot finish is no read
            chunk = os.read(fd, min(65536, cap - len(out)))
            if not chunk:
                break
            out += chunk
        return bytes(out)
    except OSError:
        return b""
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.stdout.buffer.write(read_capped(sys.argv[1], int(sys.argv[2])))
