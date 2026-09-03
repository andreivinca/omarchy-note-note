#!/usr/bin/env python3
"""Tests for providers/local/list.py — the order a notebook's notes come in.

The property is that a note sits where it was created and that editing it
moves nothing. It had never held. `os.stat()` carries `st_birthtime` only
where the platform's own `struct stat` does, which on Linux it does not, so
the birth key was the `getattr` default — 0 for every note — and the order
fell entirely to a tie-break built by formatting size, mtime and name into
one string. A string compares as text, so `100` sorted before `80` sorted
before `9`, and a note changed places as it was typed into. Both halves are
covered here: that a birth time is really read, and that the key is really
numeric.

Ground truth for a birth time is coreutils' `stat -c %W`, which reads one
through a statx(2) call of its own. It shares no struct definition with
list.py, so agreeing with it is what checks the ctypes layout — a layout
wrong by eight bytes still hands back a plausible-looking timestamp, which no
self-consistent test would catch.

Two legs need a birth time to exist. Where the filesystem records none, or
`stat` is not installed, they print a skip rather than fail: falling back to
the modification time is then the module's correct behaviour, not a fault.
Those legs are the ones that distinguish birth time from mtime; everything
else runs everywhere.

Creating notes in a known *order* means creating them in distinct seconds,
and a birth time cannot be set the way `os.utime` sets an mtime, so this
sleeps about a second per note it has to order.

The last test belongs to services/markdown/qthtml/imagesize.py rather than to
this directory. It is here because it is the same shape of property — a
listing that cannot be steered out of the notebook, and an image reference
that cannot be steered out of the note's folder — and because that module has
no cheaper place to assert it from.

    python3 providers/local/selftest.py [-v]
"""
import argparse
import ctypes
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "services", "markdown"))
import list as listing  # noqa: E402
from qthtml.imagesize import local_path  # noqa: E402

FAILURES = []

# A second and a bit: long enough that two files land in different whole
# seconds, which is the resolution list.py sorts on.
TICK = 1.05

# The listing run with statx(2) taken away, which is the only way to reach the
# fallback on a kernel that has it. Nothing in list.py knows about this; the
# child reaches in and clears the entry point the module resolved at import.
NO_STATX = r"""
import sys
sys.path.insert(0, %r)
import list as listing
listing._statx = None
root = sys.argv[1]
sys.argv = ["list.py", root, "1000000"]
listing.main()
""" % HERE


def check(name, ok, detail=""):
    if ok:
        return 0
    FAILURES.append(name + (": " + detail if detail else ""))
    return 1


def skipped(name, reason):
    print("  SKIPPED %s: %s" % (name, reason))
    return 0


def note(root, name, size):
    """A note of exactly `size` bytes. The size is what the old string key
    sorted on, so it is precisely the thing the order must ignore."""
    path = os.path.join(root, name)
    with open(path, "wb") as handle:
        handle.write(b"x" * size)
    return path


def listed(root, statx=True):
    """The note names list.py emits, in the order it emits them — run as the
    child process it really is, so the test sees what Provider.qml sees."""
    argv = ([sys.executable, os.path.join(HERE, "list.py"), root, "1000000"] if statx
            else [sys.executable, "-c", NO_STATX, root])
    done = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.decode()[-400:])
    names = []
    for line in done.stdout.decode().split("\n"):
        fields = line.split("\t")
        if fields[0] == "N":
            names.append(os.path.basename(fields[2]))
    return names


def coreutils_birth(path):
    """The birth time `stat` reports, whole seconds, or 0 when there is none
    to report — an older filesystem, or no `stat` on this machine. Like the
    module under test, it does not follow a symlink."""
    try:
        done = subprocess.run(["stat", "-c", "%W", "--", path], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return 0
    text = done.stdout.decode().strip()
    return int(text) if text.isdigit() else 0


def test_struct_layout(directory, verbose):
    """The ctypes `struct statx` against the one the kernel writes."""
    failures = 0
    failures += check("struct statx is 256 bytes", ctypes.sizeof(listing._Statx) == 256,
                      "%d" % ctypes.sizeof(listing._Statx))
    failures += check("stx_atime at 64", listing._Statx.stx_atime.offset == 64,
                      "%d" % listing._Statx.stx_atime.offset)
    failures += check("stx_btime at 80", listing._Statx.stx_btime.offset == 80,
                      "%d" % listing._Statx.stx_btime.offset)

    # The fields ahead of stx_btime are what place it at its offset, so
    # reading them back from a real call and finding os.stat's own answers
    # there is the check that matters: if these three landed, so did the
    # birth time.
    if listing._statx is None:
        failures += skipped("live layout", "no statx(2) to call on this machine")
    else:
        path = note(directory, "layout.md", 41)
        info = listing._Statx()
        rc = listing._statx(listing.AT_FDCWD, os.fsencode(path),
                            listing.AT_SYMLINK_NOFOLLOW, listing.STATX_BTIME,
                            ctypes.byref(info))
        st = os.stat(path)
        failures += check("statx returns 0", rc == 0, "errno %d" % ctypes.get_errno())
        failures += check("stx_size lands", info.stx_size == st.st_size,
                          "%d vs %d" % (info.stx_size, st.st_size))
        failures += check("stx_ino lands", info.stx_ino == st.st_ino,
                          "%d vs %d" % (info.stx_ino, st.st_ino))
        failures += check("stx_mode lands", info.stx_mode == st.st_mode,
                          "%o vs %o" % (info.stx_mode, st.st_mode))
        if verbose:
            print("  mask %#x, btime %d.%09d" % (info.stx_mask, info.stx_btime.tv_sec,
                                                 info.stx_btime.tv_nsec))
    print("struct statx layout")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_birth_time(directory, verbose):
    """birth_time() against `stat`, and against a symlink it must not follow."""
    failures = 0
    root = os.path.join(directory, "birth")
    os.makedirs(root)

    target = note(root, "target.md", 10)
    truth = coreutils_birth(target)
    if not truth:
        return skipped("birth time", "nothing records one here (%s)" % root) or failures
    failures += check("birth_time agrees with stat", listing.birth_time(target) == truth,
                      "%d vs %d" % (listing.birth_time(target), truth))
    if verbose:
        print("  birth_time %d, stat -c %%W %d" % (listing.birth_time(target), truth))

    # The listing refuses symlinked notes precisely so that another file's
    # bytes cannot reach it. Reading a birth time must not be the one call
    # that walks through one, so the link's own time is the answer.
    time.sleep(TICK)
    link = os.path.join(root, "link.md")
    os.symlink(target, link)
    failures += check("symlink is not followed", listing.birth_time(link) == coreutils_birth(link),
                      "%d vs %d" % (listing.birth_time(link), coreutils_birth(link)))
    failures += check("symlink has its own birth time", listing.birth_time(link) != truth,
                      "both %d" % truth)

    failures += check("a missing file has no birth time",
                      listing.birth_time(os.path.join(root, "gone.md")) == 0)
    print("birth_time against stat")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_listing_order(directory, verbose):
    """The finding itself: three notes, listed where they were created."""
    failures = 0
    root = os.path.join(directory, "order")
    os.makedirs(root)

    # Sizes 9, 80 and 100, dealt out so that creation order matches nothing
    # else: not the names (a, m, z), not ascending size (a, m, z), and not the
    # old key's text order, which put "100" before "80" before "9" and so
    # answered z, m, a.
    order = [("m.md", 80), ("a.md", 9), ("z.md", 100)]
    for i, (name, size) in enumerate(order):
        if i:
            time.sleep(TICK)
        note(root, name, size)
    want = [name for name, _ in order]

    got = listed(root)
    failures += check("listed in creation order", got == want, "%r" % got)
    if verbose:
        print("  created %r, listed %r" % (want, got))

    # Now make the modification times run backwards. Only a real birth time
    # can still answer the creation order, so this is the leg that says the
    # statx read is doing the work rather than mtime standing in for it.
    if not coreutils_birth(os.path.join(root, "m.md")):
        failures += skipped("birth time outranks mtime", "no birth time on this filesystem")
    else:
        base = time.time()
        for i, name in enumerate(reversed(want)):
            stamp = base + i
            os.utime(os.path.join(root, name), (stamp, stamp))
        got = listed(root)
        failures += check("birth time outranks mtime", got == want, "%r" % got)
    print("three notes in creation order")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_numeric_key(directory, verbose):
    """Two sizes across a digit boundary: 9 and 80, which text sorts wrong."""
    failures = 0
    root = os.path.join(directory, "numeric")
    os.makedirs(root)

    small = note(root, "p.md", 9)
    time.sleep(TICK)
    note(root, "q.md", 80)

    # Under the old key these came back q, p, because "80" sorts under "9".
    got = listed(root)
    failures += check("9 bytes before 80 bytes", got == ["p.md", "q.md"], "%r" % got)

    # Typing into the smaller note carries it across the boundary — 9 to 200 —
    # which is what used to move it. Its birth time has not changed, so its
    # place must not either.
    with open(small, "wb") as handle:
        handle.write(b"x" * 200)
    if not coreutils_birth(small):
        failures += skipped("an edit moves nothing", "no birth time on this filesystem")
    else:
        got = listed(root)
        failures += check("an edit moves nothing", got == ["p.md", "q.md"], "%r" % got)
    if verbose:
        print("  after growing p.md from 9 to 200 bytes: %r" % got)
    print("a numeric sort key")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_fallback(directory, verbose):
    """With no statx(2) at all: an order, not an exception."""
    failures = 0
    root = os.path.join(directory, "fallback")
    os.makedirs(root)

    # Explicit modification times, so this leg needs no sleeping and holds the
    # same on a machine where every note really was created in one second.
    base = time.time()
    for i, (name, size) in enumerate([("z.md", 9), ("m.md", 100), ("a.md", 80)]):
        note(root, name, size)
        os.utime(os.path.join(root, name), (base + i, base + i))
    want = ["z.md", "m.md", "a.md"]

    got = listed(root, statx=False)
    failures += check("fallback lists in mtime order", got == want, "%r" % got)
    if verbose:
        print("  without statx: %r" % got)

    kept = listing._statx
    try:
        listing._statx = None
        failures += check("birth_time answers 0 rather than raising",
                          listing.birth_time(os.path.join(root, "z.md")) == 0)
    finally:
        listing._statx = kept
    print("the fallback to mtime")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_image_escape(directory, verbose):
    """An `<img src>` that climbs out of the note's folder measures nothing."""
    failures = 0
    base = os.path.join(directory, "notebook")
    cases = [
        ("../../x.png", ""),
        ("../x.png", ""),
        ("a/../../x.png", ""),
        ("..", ""),
        ("%2Fetc%2Fpasswd", ""),                       # absolute only once unquoted
        (".assets/paste-1.png", os.path.join(base, ".assets/paste-1.png")),
        ("shot.png", os.path.join(base, "shot.png")),
    ]
    for url, want in cases:
        got = local_path(url, base)
        failures += check("local_path(%r)" % url, got == want, "%r" % got)

    # A relative base still resolves: the containment is decided on the src,
    # so it never depends on the base being absolute.
    failures += check("a relative base still resolves", local_path("x.png", ".") == "./x.png",
                      "%r" % local_path("x.png", "."))
    failures += check("a file:// url is untouched",
                      local_path("file:///tmp/a.png") == "/tmp/a.png")
    print("an image reference stays in the note's folder")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="note-note-local-selftest-") as directory:
        total = 0
        total += test_struct_layout(directory, args.verbose)
        total += test_birth_time(directory, args.verbose)
        total += test_listing_order(directory, args.verbose)
        total += test_numeric_key(directory, args.verbose)
        total += test_fallback(directory, args.verbose)
        total += test_image_escape(directory, args.verbose)

    if FAILURES:
        print("\n%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  - " + line)
        return 1
    print("\nall green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
