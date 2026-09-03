"""The error and IO shape every provider script answers with.

`out`, `fail`, `load_json`, `save_private` and `read_payload` existed twice,
byte for byte: once in `services/microsoft/msgraph.py`, which onenote.py and
sticky.py import from, and once in `providers/notion/notion.py`, which had
its own. Identical copies are how a correction stops travelling — the next
fix to `save_private`'s atomic write would have been made in one of them and
believed to be everywhere. There is one of each here instead, and msgraph.py
re-exports them so its importers never had to learn a new name.

The two HTTP status groups are here for the same reason. `msgraph.http()`,
`onenote.graph_raw()` and `notion.api()` each decided on their own which
failures were worth another attempt, and by the time anyone compared them the
three answers disagreed and none of them covered a 500
(docs/future/python-review-fixes.md). They now read the same two names.

Standard library only, and `lib/` is already on the path of every script that
imports this.
"""
import json, os, sys


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def fail(msg, code=1, kind=None, retry_after=None):
    """The one error shape every provider script answers with.

    `kind` is what the queue in the host reads (providers/PROVIDERS.md):
    "throttled" parks that provider's lane until `retryAfter` seconds have
    passed and then re-runs the job, "transient" re-runs the job a few times
    on its own, and anything else — including no kind at all, which is every
    error this plugin had before — is shown to the user as it stands.
    """
    payload = {"error": msg}
    if kind:
        payload["kind"] = kind
    if retry_after is not None:
        payload["retryAfter"] = round(float(retry_after), 3)
    out(payload)
    sys.exit(code)


def fail_throttled(error):
    """A `ratelimit.Throttled` as the queue expects to read it."""
    fail("rate limited — retrying in %ds" % max(1, round(error.retry_after)),
         kind="throttled", retry_after=error.retry_after)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_private(path, obj):
    """Write a private file atomically: a fresh O_EXCL temp file (mkstemp,
    0600, never a pre-existing path or symlink), then rename over the target."""
    import tempfile
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)   # the files themselves are 0600
    fd, tmp = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def read_payload(path):
    """A JSON payload: from stdin when path is "-" (how the plugin passes
    secrets and note bodies — nothing touches a shared temp directory)."""
    if path == "-":
        raw = sys.stdin.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024:
            fail("payload too large")
        try:
            return json.loads(raw)
        except ValueError:
            return None
    return load_json(path, None)


# ------------------------------------------------------- HTTP classification

# A 429 or a 503 is the service telling this account to stop for a while, and
# both carry a `Retry-After` saying how long. They become a `ratelimit.Retry`,
# then a `Throttled`, then a "throttled" failure that parks the provider's
# whole lane — which is right, because nothing else this provider asks for
# will be answered either.
THROTTLED_STATUSES = (429, 503)
# A 500, a 502 or a 504 is one request going wrong at the far end, not the
# account being cut off, and it carries no `Retry-After` to park a lane on.
# Parking every other request behind one bad page would be the wrong trade, so
# these re-run that one job — 2.5s, 5s, 10s — and the third answer is
# delivered whatever it says (providers/PROVIDERS.md, the `kind` table).
TRANSIENT_STATUSES = (500, 502, 504)


def error_message(body, limit=200):
    """The human half of an error body, whatever shape it arrived in.

    Graph answers `{"error": {"message": …}}` and Notion `{"message": …}`, but
    a 502 or a 504 usually comes from a gateway sitting in front of either and
    is a page of HTML instead. So JSON is read as JSON and anything else is
    passed through as one line of text, bounded — this string ends up in a
    message a person reads.
    """
    if isinstance(body, bytes):
        body = body.decode(errors="replace")
    text = (body or "").strip()
    try:
        parsed = json.loads(text)
    except ValueError:
        return " ".join(text.split())[:limit]
    if isinstance(parsed, dict):
        inner = parsed.get("error")
        if isinstance(inner, dict):
            return str(inner.get("message") or inner.get("code") or "")[:limit]
        return str(parsed.get("message") or inner or "")[:limit]
    return " ".join(text.split())[:limit]


def fail_transient(status, body=b""):
    """A `TRANSIENT_STATUSES` response as the queue expects to read it.

    The status and the server's own words travel with it because the third
    attempt's answer is delivered as it stands, and by then this line is all
    the user gets. Graph is why that matters: it returns transient 500s in
    normal operation and says so in the body.
    """
    detail = error_message(body)
    fail("server error %d%s" % (status, ": " + detail if detail else ""),
         kind="transient")
