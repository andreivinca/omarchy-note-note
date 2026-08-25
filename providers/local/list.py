"""The local provider's listing: notebooks (folders) and their notes,
oldest-first by birth time, as the tab-separated stream Provider.qml parses:

    B<TAB>key                                        notebook order (.notebooks)
    D<TAB>key                                        a notebook ("" = root)
    O<TAB>key<TAB>name                               saved note order (.order)
    N<TAB>key<TAB>path<TAB>title<TAB>preview<TAB>size<TAB>mtime

Every file is read through lib/readfile.py — one descriptor, no symlink
following, regular files only, capped, against one shared deadline — so a
FIFO named *.md cannot hang the listing and a symlink cannot put another
file's bytes into a title or preview. The same policy is applied to what is
listed at all: a symlinked note or notebook is not ours and does not appear.

    python3 list.py <notesDir> <maxOutputBytes>
"""
import os
import re
import stat
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from readfile import read_capped  # noqa: E402

HEAD_BYTES = 4096          # of a note: the front matter and the first content line
ORDER_BYTES = 256 * 1024   # .order / .notebooks hold file names, one per line
DEADLINE = 10.0            # seconds for the whole listing; expired = partial list


def head_of(path, deadline):
    """(title, preview) from a note's first bytes: `title:` inside the ---
    front matter, and the first non-empty content line, markers stripped."""
    text = read_capped(path, HEAD_BYTES, deadline).decode("utf-8", "replace")
    title, preview, fm = "", "", False
    for i, line in enumerate(text.split("\n")):
        if i == 0 and line == "---":
            fm = True
        elif fm and line == "---":
            fm = False
        elif fm and line.startswith("title:"):
            title = line[len("title:"):]
        elif not fm and not preview and line.strip():
            preview = re.sub(r"^[#>*\- \t]+", "", line[:200])
            preview = re.sub(r"[*_`]", "", preview)
    return title.replace("\t", " ").lstrip(" "), preview.replace("\t", " ")


def main():
    root, budget = sys.argv[1], int(sys.argv[2])
    deadline = time.monotonic() + DEADLINE
    os.makedirs(root, exist_ok=True)
    out = sys.stdout.buffer

    left = budget

    def emit(*fields):
        # The output cap cuts between lines, never through one: the parser
        # must not see half an N record.
        nonlocal left
        line = ("\t".join(fields) + "\n").encode()
        if len(line) > left:
            return False
        left -= len(line)
        out.write(line)
        return True

    def lines_of(path):
        raw = read_capped(path, ORDER_BYTES, deadline)
        return [l for l in raw.decode("utf-8", "replace").split("\n") if l]

    for name in lines_of(os.path.join(root, ".notebooks")):
        emit("B", name)

    keys = [""]
    try:
        with os.scandir(root) as it:
            keys += sorted(e.name for e in it
                           if not e.name.startswith(".") and e.is_dir(follow_symlinks=False))
    except OSError:
        return

    for key in keys:
        d = os.path.join(root, key) if key else root
        emit("D", key)
        for name in lines_of(os.path.join(d, ".order")):
            emit("O", key, name)
        notes = []
        try:
            with os.scandir(d) as it:
                for entry in it:
                    if not entry.name.endswith(".md"):
                        continue
                    try:
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    born = int(getattr(st, "st_birthtime", 0) or 0)
                    # Same-second ties break the way `sort -n` used to: on the
                    # rest of the line as text, so an update reorders nothing.
                    notes.append((born, "%s\t%s\t%s" % (st.st_size, int(st.st_mtime), entry.name),
                                  st.st_size, int(st.st_mtime), os.path.join(d, entry.name)))
        except OSError:
            continue
        for born, _, size, mtime, path in sorted(notes):
            if time.monotonic() > deadline:
                return
            title, preview = head_of(path, deadline)
            emit("N", key, path, title, preview, str(size), str(mtime))


if __name__ == "__main__":
    main()
