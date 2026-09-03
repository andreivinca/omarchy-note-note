#!/usr/bin/env python3
"""Tests for providers/onenote/onenote.py — which failures may be run again.

`graph_raw` is a second implementation of the two decisions `msgraph.http`
makes, and it holds the only `transient_5xx=False` calls in the tree. That
combination is what this file exists for: `services/microsoft/selftest.py`
covers the shared classification and would stay green while this copy drifted
away from it, or while the one flag that matters was wired backwards.

Two properties.

**A 401 is a revoked grant until a refresh says otherwise** (§3b of
docs/future/python-review-fixes.md) — one forced refresh, one repeat of the
request, carrying the new token.

**A job is re-run only when running it twice is the same as running it once.**
`kind="transient"` re-runs the whole job three times, so it belongs to a page
fetch or a body replace and to nothing that creates. The gates are read off
the calls themselves rather than inferred from behaviour, because the failure
being guarded against is somebody adding a create without one:

- the title replace, whose 500 arrives *every* time on some pages and whose
  body has already been saved by the time it happens;
- a page create and a section create, where a 502 is the gateway losing the
  answer to a page Graph may already have made;
- a save carrying image uploads, which would put the same pictures up twice.

No network and no real state: `urlopen` is scripted and every directory these
modules read is redirected into a temporary one before they are imported.

    python3 providers/onenote/selftest.py [-v]
"""
import argparse
import contextlib
import email.message
import io
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Both modules read these into constants at import, so they are set first: a
# test that ran against the real ones would sign the user out.
WORK = tempfile.mkdtemp(prefix="note-note-onenote-selftest-")
CLIENT_ID = "00000000-0000-0000-0000-0000000005e1"
os.environ["XDG_CONFIG_HOME"] = os.path.join(WORK, "config")
os.environ["XDG_STATE_HOME"] = os.path.join(WORK, "state")
os.environ["XDG_CACHE_HOME"] = os.path.join(WORK, "cache")
os.environ["NOTE_NOTE_RATE_DIR"] = os.path.join(WORK, "rate")
os.environ["NOTE_NOTE_MS_TOKEN"] = os.path.join(WORK, "token.json")
os.environ["NOTE_NOTE_MS_CLIENT_ID"] = CLIENT_ID
os.environ["NOTE_NOTE_MS_ACCOUNT"] = "selftest"

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "services", "microsoft"))
sys.path.insert(0, HERE)
import msgraph  # noqa: E402
import onenote  # noqa: E402

FAILURES = []

PAGE = "/me/onenote/pages/1-abc/content"


def check(name, ok, detail=""):
    if ok:
        return 0
    FAILURES.append(name + (": " + detail if detail else ""))
    return 1


def headers(**fields):
    msg = email.message.Message()
    for key, value in fields.items():
        msg[key.replace("_", "-")] = value
    return msg


class Response:
    def __init__(self, status, body):
        self.status, self.body = status, body

    def read(self, size=-1):
        return self.body if size < 0 else self.body[:size]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Endpoint:
    """A scripted Graph and sign-in endpoint, keeping every call in order."""

    def __init__(self, graph=(), token=()):
        self.calls = []
        self.queues = {"graph": list(graph), "token": list(token)}

    def urlopen(self, req, timeout=None):
        url = req.full_url
        where = "token" if "login.microsoftonline.com" in url else "graph"
        self.calls.append((where, req.get_method(), url, req.get_header("Authorization")))
        queue = self.queues[where]
        if not queue:
            raise AssertionError("unscripted %s request: %s" % (where, url))
        status, body, hdrs = queue.pop(0)
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        if status >= 400:
            raise urllib.error.HTTPError(url, status, "", hdrs, io.BytesIO(body))
        return Response(status, body)

    def to(self, where):
        return [c for c in self.calls if c[0] == where]


@contextlib.contextmanager
def scripted(endpoint):
    real, printed = urllib.request.urlopen, io.StringIO()
    urllib.request.urlopen = endpoint.urlopen
    try:
        with contextlib.redirect_stdout(printed):
            yield printed
    finally:
        urllib.request.urlopen = real


def answered(printed):
    lines = printed.getvalue().splitlines()
    return json.loads(lines[-1]) if lines else {}


def sign_in(access="old"):
    """A token file as a signed-in provider would have left it."""
    msgraph.save_private(msgraph.TOKENS, {
        "access_token": access, "refresh_token": "refresh-me",
        "expires_at": time.time() + 3600, "client_id": CLIENT_ID,
        "account": "someone@example.com",
    })


@contextlib.contextmanager
def recorded_graph_raw():
    """`graph_raw` replaced by a recorder, for the callers whose interesting
    property is the flag they pass rather than what comes back."""
    real, seen = onenote.graph_raw, []

    def fake(method, path, data=None, content_type=None, extra_headers=None,
             max_bytes=onenote.MAX_PAGE_HTML, transient_5xx=True):
        seen.append({"method": method, "path": path, "transient_5xx": transient_5xx})
        if method == "POST":
            # A create reads the answer back as the page resource it made.
            return 201, json.dumps({"id": "1-made", "title": "New page",
                                    "lastModifiedDateTime": "2026-01-01T00:00:00Z",
                                    "parentSection": {"id": "section-1"}})
        return 200, '<html><head><title>t</title></head><body><div id="x"></div></body></html>'

    onenote.graph_raw = fake
    try:
        yield seen
    finally:
        onenote.graph_raw = real


def test_revoked_grant_refreshes_once(verbose):
    """§3b, through this module's own copy of the retry."""
    sign_in()
    endpoint = Endpoint(
        graph=[(401, b"InvalidAuthenticationToken", headers()),
               (200, b"<html>ok</html>", headers())],
        token=[(200, {"access_token": "new", "refresh_token": "r2", "expires_in": 3600}, headers())])
    with scripted(endpoint):
        status, body = onenote.graph_raw("GET", PAGE)
    failures = 0
    failures += check("the retry succeeds", status == 200 and "ok" in body,
                      "%r %r" % (status, body))
    failures += check("refreshed exactly once", len(endpoint.to("token")) == 1,
                      "%d refreshes" % len(endpoint.to("token")))
    sent = [call[3] for call in endpoint.to("graph")]
    failures += check("the retry carries the new token", sent == ["Bearer old", "Bearer new"],
                      "%r" % (sent,))
    if verbose:
        print("  %r" % (sent,))
    print("graph_raw meets a 401 with one refresh and one retry")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_the_transient_gate(verbose):
    """The flag decides, in both positions, and the default is the open one."""
    failures = 0
    for status in msgraph.TRANSIENT_STATUSES:
        sign_in()
        endpoint = Endpoint(graph=[(status, b"Transient error", headers())])
        with scripted(endpoint) as printed:
            try:
                onenote.graph_raw("GET", PAGE)
                exited = False
            except SystemExit:
                exited = True
        answer = answered(printed)
        failures += check("%d is transient by default" % status,
                          exited and answer.get("kind") == "transient", "%r" % (answer,))

        sign_in()
        endpoint = Endpoint(graph=[(status, b"Transient error", headers())])
        with scripted(endpoint):
            got, body = onenote.graph_raw("GET", PAGE, transient_5xx=False)
        failures += check("%d is the caller's when the gate is shut" % status,
                          got == status and "Transient error" in body, "%r %r" % (got, body))
    if verbose:
        print("  %r gated both ways" % (list(msgraph.TRANSIENT_STATUSES),))
    print("the transient gate decides, and only it")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_writes_that_must_not_repeat(verbose):
    """Which callers shut the gate — read off the calls, not inferred."""
    failures = 0

    with recorded_graph_raw() as seen:
        onenote.patch_page("/me/onenote/pages/x/content", [{"target": "body"}], [])
        onenote.patch_page("/me/onenote/pages/x/content", [{"target": "body"}],
                           [("img", "image/png", b"bytes")])
    failures += check("a text-only save may be re-run", seen[0]["transient_5xx"] is True,
                      "%r" % (seen[0],))
    failures += check("a save carrying an upload may not", seen[1]["transient_5xx"] is False,
                      "%r" % (seen[1],))

    payload = os.path.join(WORK, "note.json")
    with open(payload, "w") as f:
        json.dump({"title": "New page", "body": "hello\n"}, f)
    with recorded_graph_raw() as seen:
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                onenote.cmd_onenote_create("section-1", payload)
            except (SystemExit, KeyError, TypeError, ValueError):
                pass          # the recorder answers a create only loosely
    creates = [c for c in seen if c["method"] == "POST"]
    failures += check("a page create may not be re-run",
                      creates and all(c["transient_5xx"] is False for c in creates),
                      "%r" % (creates,))

    if verbose:
        print("  %r" % (seen,))
    print("only the repeatable writes accept a re-run")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_the_title_replace_keeps_its_warning(verbose):
    """The one call the write-up got backwards.

    Its 500 arrives every time on the affected pages and the body has already
    been saved when it does, so `cmd_onenote_update` puts it in a `warning`
    and still answers `{"ok": true}`. Turning the gate on here would re-run a
    save that had already succeeded, three times, and then fail it — which is
    why the flag is asserted rather than left to a comment.
    """
    source = open(os.path.join(HERE, "onenote.py")).read()
    marker = ('graph_raw("PATCH", url, json.dumps(ops).encode(), "application/json",\n'
              '                                transient_5xx=False)')
    failures = check("the title replace shuts the gate", marker in source,
                     "the call no longer reads as it did")
    if verbose:
        print("  gated title replace %s" % ("found" if not failures else "NOT found"))
    print("the title replace stays a warning, not a re-run")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    total = 0
    try:
        total += test_revoked_grant_refreshes_once(args.verbose)
        total += test_the_transient_gate(args.verbose)
        total += test_writes_that_must_not_repeat(args.verbose)
        total += test_the_title_replace_keeps_its_warning(args.verbose)
    finally:
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
