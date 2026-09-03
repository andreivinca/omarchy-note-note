"""The local provider's listing: notebooks (folders) and their notes,
oldest-first by birth time, as the tab-separated stream Provider.qml parses:

    B<TAB>key                                        notebook order (.notebooks)
    D<TAB>key                                        a notebook ("" = root)
    O<TAB>key<TAB>name                               saved note order (.order)
    N<TAB>key<TAB>path<TAB>title<TAB>preview<TAB>size<TAB>mtime

The birth time comes from statx(2), not from os.stat(): a stat_result only
carries st_birthtime where the platform's own struct stat does, which on Linux
it does not, so asking os.stat() for one answers whatever default the caller
supplied — the same value for every note, leaving the order to whatever the
tie-break happened to be. The filesystem has the field (btrfs, ext4, xfs and
f2fs record it); nothing but statx will hand it over.

Where no birth time is recorded — an older filesystem, a kernel without
statx(2) — the modification time stands in. That is the one case where the
order is not creation order: editing a note in a notebook on such a
filesystem moves it. Nothing is compared as text, so a note's length never
decides where it sits.

Every file is read through lib/readfile.py — one descriptor, no symlink
following, regular files only, capped, against one shared deadline — so a
FIFO named *.md cannot hang the listing and a symlink cannot put another
file's bytes into a title or preview. The same policy is applied to what is
listed at all: a symlinked note or notebook is not ours and does not appear,
and the statx call takes AT_SYMLINK_NOFOLLOW so that reading a birth time is
not the one lookup in this module that follows a link.

    python3 list.py <notesDir> <maxOutputBytes>
"""
import ctypes
import errno
import os
import re
import stat
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from notewalk import notebook_keys  # noqa: E402
from readfile import read_capped  # noqa: E402

HEAD_BYTES = 4096          # of a note: the front matter and the first content line
ORDER_BYTES = 256 * 1024   # .order / .notebooks hold file names, one per line
DEADLINE = 10.0            # seconds for the whole listing; expired = partial list

AT_FDCWD = -100            # statx: resolve a relative path against the cwd
AT_SYMLINK_NOFOLLOW = 0x100
STATX_BTIME = 0x00000800   # the one field of the structure this module wants


class _StatxTimestamp(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_int64),
                ("tv_nsec", ctypes.c_uint32),
                ("_reserved", ctypes.c_int32)]


class _Statx(ctypes.Structure):
    """`struct statx` as far as the birth time, and padding for the rest.

    The kernel writes all 256 bytes whatever the mask asked for, so the tail
    has to be there or the write runs off the end of the buffer; only the
    fields ahead of stx_btime need names, since they are what place it at its
    offset. selftest.py checks the size and that offset, because a layout
    wrong by eight bytes still hands back a plausible-looking timestamp.
    """
    _fields_ = [("stx_mask", ctypes.c_uint32),
                ("stx_blksize", ctypes.c_uint32),
                ("stx_attributes", ctypes.c_uint64),
                ("stx_nlink", ctypes.c_uint32),
                ("stx_uid", ctypes.c_uint32),
                ("stx_gid", ctypes.c_uint32),
                ("stx_mode", ctypes.c_uint16),
                ("_spare0", ctypes.c_uint16),
                ("stx_ino", ctypes.c_uint64),
                ("stx_size", ctypes.c_uint64),
                ("stx_blocks", ctypes.c_uint64),
                ("stx_attributes_mask", ctypes.c_uint64),
                ("stx_atime", _StatxTimestamp),
                ("stx_btime", _StatxTimestamp),
                ("_tail", ctypes.c_uint8 * 160)]


def _load_statx():
    """libc's statx(2), or None where there is none to call: not Linux, or a
    libc that predates it (glibc has exposed it since 2.28). Answered once at
    import, because a listing walks every note in the directory and must not
    pay a symbol lookup, or a failed one, for each."""
    if not sys.platform.startswith("linux"):
        return None
    try:
        entry = ctypes.CDLL(None, use_errno=True).statx
    except (OSError, AttributeError):
        return None
    entry.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint,
                      ctypes.POINTER(_Statx)]
    entry.restype = ctypes.c_int
    return entry


_statx = _load_statx()


def birth_time(path):
    """When the file was created, in whole seconds, or 0 when nothing
    recorded it — no statx(2) at all, or a filesystem that keeps no such
    field. A kernel too old for the call answers ENOSYS once and is then
    taken at its word for the rest of the run."""
    global _statx
    if _statx is None:
        return 0
    info = _Statx()
    if _statx(AT_FDCWD, os.fsencode(path), AT_SYMLINK_NOFOLLOW, STATX_BTIME,
              ctypes.byref(info)) != 0:
        if ctypes.get_errno() == errno.ENOSYS:
            _statx = None
        return 0
    # The mask is the kernel reporting what it actually filled in. It stays a
    # per-file question rather than a per-run one, because a notes directory
    # can span mounts and only some of them record a birth time; an unset bit
    # leaves stx_btime zeroed, which would sort every such note to the front.
    return int(info.stx_btime.tv_sec) if info.stx_mask & STATX_BTIME else 0


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

    for key in notebook_keys(root):
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
                    path = os.path.join(d, entry.name)
                    # Same-second ties break on the modification time and then
                    # on the name, all three compared as the numbers and the
                    # string they are. Nothing here is formatted first: a key
                    # built as text sorted a 9-byte note after an 80-byte one
                    # and reshuffled the list as a note was typed into.
                    notes.append(((birth_time(path) or int(st.st_mtime),
                                   int(st.st_mtime), entry.name),
                                  st.st_size, int(st.st_mtime), path))
        except OSError:
            continue
        for _, size, mtime, path in sorted(notes):
            if time.monotonic() > deadline:
                return
            title, preview = head_of(path, deadline)
            emit("N", key, path, title, preview, str(size), str(mtime))


if __name__ == "__main__":
    main()
