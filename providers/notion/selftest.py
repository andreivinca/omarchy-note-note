#!/usr/bin/env python3
"""Tests for providers/notion/notion.py — what a failed save leaves behind.

One property, and it is about a note that still exists after something went
wrong. `cmd_update` replaces a page's body, and it used to do that by deleting
every top-level block first and only then converting the markdown and sending
it back: a conversion and one round trip per hundred blocks during which the
user's page was empty, and any error in that window — a 400 from a block
Notion will not take, the app being killed — left it empty for good.

So the test is not "an update works". It is **no DELETE is ever issued until
every insert has come back 200**, checked by scripting `api` to fail the first
insert and then looking at what was asked of Notion. The happy path is checked
too, for the other half of the same property: the ids deleted at the end are
exactly the ones recorded before the insert, so appending can never lose a
block it just wrote.

No network: `notion.api` is replaced with a recorder, and nothing here reads
or writes a real token, cache or page.

    python3 providers/notion/selftest.py [-v]
"""
import argparse
import contextlib
import io
import json
import os
import sys
import tempfile

# Point the state and cache directories somewhere harmless before notion.py
# reads them into module constants at import.
WORK = tempfile.mkdtemp(prefix="note-note-notion-selftest-")
os.environ["XDG_STATE_HOME"] = os.path.join(WORK, "state")
os.environ["XDG_CACHE_HOME"] = os.path.join(WORK, "cache")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import notion  # noqa: E402

FAILURES = []

PAGE_ID = "11111111-2222-3333-4444-555555555555"
TITLE = "Shopping"
OLD_IDS = ["block-one", "block-two", "block-three"]
BODY = "# Milk\n\nand bread\n"


def check(name, ok, detail=""):
    if ok:
        return 0
    FAILURES.append(name + (": " + detail if detail else ""))
    return 1


class Notion:
    """A scripted stand-in for `notion.api` that keeps every call it was asked
    to make, in order — the order is the thing under test."""

    def __init__(self, insert_status=200, delete_status=200, create_status=200):
        self.calls = []
        self.gates = []
        self.insert_status = insert_status
        self.delete_status = delete_status
        self.create_status = create_status

    def api(self, method, path, data=None, tok=None, transient_5xx=True):
        self.calls.append((method, path))
        self.gates.append(transient_5xx)
        if method == "PATCH" and path.startswith("/pages/"):
            return 200, {}                      # the title property
        if method == "POST" and path == "/pages":
            return self.create_status, {"id": "made", "properties": {}, "parent": {}}
        if method == "GET" and path.startswith("/pages/"):
            return 200, {"properties": {"Name": {"type": "title",
                                                 "title": [{"plain_text": TITLE}]}}}
        if method == "GET" and path.startswith("/blocks/"):
            return 200, {"results": [{"id": i, "type": "paragraph"} for i in OLD_IDS],
                         "has_more": False}
        if method == "PATCH" and path.endswith("/children"):
            return self.insert_status, {"message": "body failed validation"}
        if method == "DELETE" and path.startswith("/blocks/"):
            return self.delete_status, {}
        raise AssertionError("unscripted call: %s %s" % (method, path))

    def paths(self, method):
        return [path for m, path in self.calls if m == method]

    def deleted(self):
        return [path[len("/blocks/"):] for path in self.paths("DELETE")]

    def inserts(self):
        return [i for i, (m, path) in enumerate(self.calls)
                if m == "PATCH" and path.endswith("/children")]

    def deletes(self):
        return [i for i, (m, _) in enumerate(self.calls) if m == "DELETE"]


def run_update(fake, page_id=PAGE_ID, title=TITLE, body=BODY):
    """`cmd_update` against the stub; gives back (what it printed, exit code)."""
    handle, path = tempfile.mkstemp(dir=WORK, suffix=".json")
    with os.fdopen(handle, "w") as f:
        json.dump({"title": title, "body": body}, f)
    real, printed, code = notion.api, io.StringIO(), None
    notion.api = fake.api
    try:
        with contextlib.redirect_stdout(printed):
            notion.cmd_update(page_id, path)
    except SystemExit as e:
        code = e.code
    finally:
        notion.api = real
        os.remove(path)
    lines = printed.getvalue().splitlines()
    return (json.loads(lines[-1]) if lines else {}), code


def test_failed_insert_keeps_the_page(verbose):
    """The §1 property: Notion refuses the new body, and the old one is still
    there because nothing was deleted."""
    fake = Notion(insert_status=400)
    answer, code = run_update(fake)
    failures = 0
    failures += check("failed insert reports the failure", code == 1 and "error" in answer,
                      "exit %r, answered %r" % (code, answer))
    failures += check("failed insert deletes nothing", fake.deleted() == [],
                      "deleted %r" % (fake.deleted(),))
    failures += check("failed insert had read the old ids first",
                      any(p.startswith("/blocks/") for p in fake.paths("GET")),
                      "read %r" % (fake.paths("GET"),))
    if verbose:
        print("  after a 400 on the first insert: %r" % (fake.calls,))
    print("a refused insert leaves the page alone")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_happy_path_deletes_what_it_recorded(verbose):
    """And the other half: the ids removed at the end are the ones captured
    before the insert, never anything the insert itself appended."""
    fake = Notion()
    answer, code = run_update(fake)
    failures = 0
    failures += check("update succeeds", code is None and answer == {"ok": True},
                      "exit %r, answered %r" % (code, answer))
    failures += check("deletes exactly the recorded ids", fake.deleted() == OLD_IDS,
                      "deleted %r" % (fake.deleted(),))
    failures += check("every delete comes after every insert",
                      bool(fake.inserts()) and bool(fake.deletes())
                      and min(fake.deletes()) > max(fake.inserts()),
                      "inserts at %r, deletes at %r" % (fake.inserts(), fake.deletes()))
    if verbose:
        print("  calls: %r" % (fake.calls,))
    print("a successful insert removes the blocks it replaced")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_conversion_failure_writes_nothing(verbose):
    """A body the converter cannot turn into blocks must abort before the
    *body* is touched — which is the reason the conversion moved up front.

    The title is deliberately not part of that claim: `cmd_update` writes it
    first, in its own small request, and it is the one write that survives a
    failed conversion. So the title is changed here on purpose, to prove the
    body is untouched even on the run where a write did happen — an earlier
    version of this test left the title alone, which meant it never issued a
    PATCH at all and would have passed against almost anything.
    """
    fake = Notion()
    real = notion.notion_md.markdown_to_blocks

    def explode(_body):
        raise ValueError("no blocks for you")

    notion.notion_md.markdown_to_blocks = explode
    try:
        try:
            answer, _ = run_update(fake, title="Something else")
            raised = False
        except ValueError:
            answer, raised = {}, True
    finally:
        notion.notion_md.markdown_to_blocks = real
    failures = 0
    failures += check("a broken conversion stops the update", raised,
                      "answered %r" % (answer,))
    failures += check("a broken conversion leaves the body alone",
                      not fake.paths("DELETE")
                      and not [p for p in fake.paths("PATCH") if p.endswith("/children")],
                      "wrote %r" % (fake.calls,))
    failures += check("and it got as far as the title, so the test is not vacuous",
                      [p for p in fake.paths("PATCH") if p.startswith("/pages/")],
                      "no title write attempted: %r" % (fake.calls,))
    if verbose:
        print("  calls: %r" % (fake.calls,))
    print("a body that will not convert never reaches the page")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_path_segments_are_quoted(verbose):
    """§4: ids reach the request path through `quote(..., safe="")`, the way
    onenote.py has always sent them, so an id can never open a path of its own."""
    fake = Notion()
    awkward = "a b/c?d"
    run_update(fake, page_id=awkward)
    quoted = "a%20b%2Fc%3Fd"
    failures = 0
    failures += check("the page id is quoted in every path",
                      all(quoted in path for path in fake.paths("GET") + fake.paths("PATCH")),
                      "%r" % (fake.paths("GET") + fake.paths("PATCH"),))
    failures += check("the raw id reaches no path",
                      not any(awkward in path for _, path in fake.calls),
                      "%r" % (fake.calls,))
    if verbose:
        print("  calls: %r" % (fake.calls,))
    print("ids are quoted into request paths")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def run_create(fake, parent_id="parent-page", title="New", body=BODY):
    """`cmd_create` against the stub; gives back (what it printed, exit code)."""
    handle, path = tempfile.mkstemp(dir=WORK, suffix=".json")
    with os.fdopen(handle, "w") as f:
        json.dump({"title": title, "body": body}, f)
    real, printed, code = notion.api, io.StringIO(), None
    notion.api = fake.api
    try:
        with contextlib.redirect_stdout(printed):
            notion.cmd_create(parent_id, path)
    except SystemExit as e:
        code = e.code
    finally:
        notion.api = real
        os.remove(path)
    lines = printed.getvalue().splitlines()
    return (json.loads(lines[-1]) if lines else {}), code


def test_a_create_is_never_repeated(verbose):
    """A create must refuse the "transient" re-run, and a save must accept it.

    `kind: "transient"` re-runs the whole job three times. That is right for a
    body replace, which lands on known ids and is the same operation however
    often it runs — and wrong for `POST /pages`, because a 502 or a 504 is the
    gateway losing the *answer* to a page Notion may already have created. Run
    that again and the user has the same note two or three times.

    So the gate is asserted per request rather than per script: it is the flag
    that decides, and reading it here is what stops a later create being added
    without it.
    """
    made = Notion()
    run_create(made)
    saved = Notion()
    run_update(saved)

    def gate(fake, method, wanted):
        return [g for (m, path), g in zip(fake.calls, fake.gates)
                if m == method and wanted(path)]

    failures = 0
    creates = gate(made, "POST", lambda p: p == "/pages")
    failures += check("a create is asked once and refuses the re-run",
                      creates == [False], "gates %r" % (creates,))
    inserts = gate(saved, "PATCH", lambda p: p.endswith("/children"))
    failures += check("a body replace still allows it",
                      inserts and all(inserts), "gates %r" % (inserts,))
    if verbose:
        print("  create %r, body replace %r" % (creates, inserts))
    print("a create is never repeated, a body replace still may be")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    total = 0
    try:
        total += test_failed_insert_keeps_the_page(args.verbose)
        total += test_happy_path_deletes_what_it_recorded(args.verbose)
        total += test_conversion_failure_writes_nothing(args.verbose)
        total += test_path_segments_are_quoted(args.verbose)
        total += test_a_create_is_never_repeated(args.verbose)
    finally:
        import shutil
        shutil.rmtree(WORK, ignore_errors=True)

    if FAILURES:
        print("\n%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  - " + line)
        return 1
    print("\nall green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
