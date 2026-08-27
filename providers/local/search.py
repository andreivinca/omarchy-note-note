"""Content search over the local notebooks: the path of every note whose
text contains the query, case-insensitively, one per line.

    python3 search.py <notesDir> <query> <maxNoteBytes>

The walk is list.py's exactly — folders are notebooks, only *.md files —
and every read goes through lib/readfile.py (one descriptor, no symlink
following, regular files only, capped, against one shared deadline), so a
search cannot be made to read a single byte the listing would not have. A
refused or oversized file simply does not match. Notes are read whole
(capped) rather than head-only, because the query may sit on the last line.
A spent deadline ends the walk with what matched so far: the host treats
the answer as best-effort either way, on top of its own title matching.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from readfile import read_capped  # noqa: E402

DEADLINE = 10.0     # seconds for the whole search; expired = partial answer
MAX_MATCHES = 1000


def main():
    root, query, max_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
    needle = query.casefold()
    if not needle:
        return
    deadline = time.monotonic() + DEADLINE
    matched = 0

    keys = [""]
    try:
        with os.scandir(root) as it:
            keys += sorted(e.name for e in it
                           if not e.name.startswith(".") and e.is_dir(follow_symlinks=False))
    except OSError:
        return

    for key in keys:
        d = os.path.join(root, key) if key else root
        try:
            with os.scandir(d) as it:
                paths = sorted(os.path.join(d, e.name) for e in it if e.name.endswith(".md"))
        except OSError:
            continue
        for path in paths:
            if matched >= MAX_MATCHES or time.monotonic() > deadline:
                return
            text = read_capped(path, max_bytes, deadline).decode("utf-8", "replace")
            if needle in text.casefold():
                sys.stdout.write(path + "\n")
                matched += 1


if __name__ == "__main__":
    main()
