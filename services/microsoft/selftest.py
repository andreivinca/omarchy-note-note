#!/usr/bin/env python3
"""Tests for services/microsoft/msgraph.py — how a failure is classified.

Two properties, and neither is about a request succeeding.

**What each HTTP status means to the queue.** A 429 or a 503 carries a `Retry-After`
and parks the provider's whole lane; a 500, a 502 or a 504 is one request
going wrong at the far end and comes back as `kind="transient"`, re-running
that job alone rather than stopping everything behind it; anything else is
handed to the caller exactly as it arrived. Three request helpers used to
answer this question three different ways and none of them covered a 500, so
the answer now lives in `lib/provider_io.py` and this is what checks it.

**A grant revoked at Microsoft's end** (§3b). The stored `expires_at` cannot
know that consent was withdrawn, so a token that looks perfectly valid 401s
forever. One 401 must now force a refresh and retry once; a forced refresh
that itself fails must take the dead token off the disk and answer with the
same "not signed in" the app already shows when there is no token, so the UI
offers a sign-in instead of a Graph error string.

No network and no real state: `urlopen` is replaced with a scripted stand-in,
and every directory msgraph reads — the token file included — is redirected
into a temporary one before it is imported.

    python3 services/microsoft/selftest.py [-v]
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
from unittest.mock import patch

# msgraph reads all of these into module constants at import, so they are set
# first: a test that ran against the real ones would sign the user out.
WORK = tempfile.mkdtemp(prefix="note-note-msgraph-selftest-")
CLIENT_ID = "00000000-0000-0000-0000-0000000005e1"
os.environ["XDG_CONFIG_HOME"] = os.path.join(WORK, "config")
os.environ["XDG_STATE_HOME"] = os.path.join(WORK, "state")
os.environ["XDG_CACHE_HOME"] = os.path.join(WORK, "cache")
os.environ["NOTE_NOTE_RATE_DIR"] = os.path.join(WORK, "rate")
os.environ["NOTE_NOTE_MS_TOKEN"] = os.path.join(WORK, "token.json")
os.environ["NOTE_NOTE_MS_CLIENT_ID"] = CLIENT_ID
os.environ["NOTE_NOTE_MS_ACCOUNT"] = "selftest"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import msgraph  # noqa: E402
import ratelimit  # noqa: E402

FAILURES = []

ME = "https://graph.microsoft.com/v1.0/me"
# Long enough that `attempt_loop` hands the wait to the caller instead of
# sleeping on it, so a throttle costs this test no wall-clock time at all.
PARKED = "999"


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
    """Just enough of an HTTP response for `msgraph.read_bounded`."""

    def __init__(self, status, body):
        self.status = status
        self.body = body

    def read(self, size=-1):
        return self.body if size < 0 else self.body[:size]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Endpoint:
    """A scripted Graph and sign-in endpoint.

    Replies are queued per destination, because the interesting cases are the
    ones where a Graph request and a token refresh interleave; every request
    is kept so the test can say how many were made and what each carried.
    """

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
    """`urlopen` replaced for the duration, and stdout collected — every
    failure path in msgraph prints one JSON line and exits."""
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


def sign_in(expires_in=3600, access="old"):
    """A token file as a signed-in provider would have left it."""
    msgraph.save_private(msgraph.TOKENS, {
        "access_token": access, "refresh_token": "refresh-me",
        "expires_at": time.time() + expires_in, "client_id": CLIENT_ID,
        "account": "someone@example.com",
    })


def test_throttled_statuses(verbose):
    """429 and 503 park the lane: they reach the caller as `Throttled`, which
    `fail_throttled` turns into the "throttled" kind the queue reads."""
    failures = 0
    for status in msgraph.THROTTLED_STATUSES:
        endpoint = Endpoint(graph=[(status, b"{}", headers(Retry_After=PARKED))])
        parked = None
        with scripted(endpoint):
            try:
                msgraph.http("GET", ME)
            except ratelimit.Throttled as t:
                parked = t.retry_after
        failures += check("%d parks the lane" % status, parked == float(PARKED),
                          "retry_after %r" % (parked,))
    # And the wait a missing header implies, which is why they park at all.
    no_header = urllib.error.HTTPError(ME, 429, "", headers(), io.BytesIO(b""))
    failures += check("a 429 without Retry-After is a real cooldown",
                      msgraph.wait_asked_by(no_header) == ratelimit.DEFAULT_COOLDOWN)
    blip = urllib.error.HTTPError(ME, 503, "", headers(), io.BytesIO(b""))
    failures += check("a 503 without Retry-After is a blip",
                      msgraph.wait_asked_by(blip) == ratelimit.SHORT_RETRY)
    if verbose:
        print("  %r park; a bare 429 waits %ss, a bare 503 %ss"
              % (list(msgraph.THROTTLED_STATUSES), ratelimit.DEFAULT_COOLDOWN, ratelimit.SHORT_RETRY))
    print("429 and 503 park the provider's lane")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_transient_statuses(verbose):
    """500, 502 and 504 re-run this job only, carrying the status and whatever
    the server actually said — the third attempt's answer is what the user sees."""
    failures = 0
    for status in msgraph.TRANSIENT_STATUSES:
        body = {"error": {"code": "InternalServerError", "message": "Transient error"}}
        endpoint = Endpoint(graph=[(status, body, headers())])
        code = None
        with scripted(endpoint) as printed:
            try:
                msgraph.http("GET", ME)
            except SystemExit as e:
                code = e.code
        answer = answered(printed)
        failures += check("%d is transient" % status, answer.get("kind") == "transient",
                          "answered %r" % (answer,))
        failures += check("%d fails the job" % status, code == 1, "exit %r" % (code,))
        failures += check("%d says what happened" % status,
                          str(status) in answer.get("error", "")
                          and "Transient error" in answer.get("error", ""),
                          "%r" % (answer.get("error"),))
        failures += check("%d is asked once" % status, len(endpoint.calls) == 1,
                          "%d requests" % len(endpoint.calls))
    if verbose:
        print("  %r re-run the one job" % (list(msgraph.TRANSIENT_STATUSES),))
    print("500, 502 and 504 re-run one job, not the lane")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_other_statuses_reach_the_caller(verbose):
    """Everything else is the caller's to interpret and arrives unchanged —
    a 404 is not a retry, and a 400 is the request being wrong."""
    failures = 0
    for status in (400, 403, 404):
        endpoint = Endpoint(graph=[(status, {"error": {"message": "nope"}}, headers())])
        with scripted(endpoint):
            got, res = msgraph.http("GET", ME)
        failures += check("%d is handed back" % status, got == status, "got %r" % (got,))
        failures += check("%d keeps its body" % status,
                          res.get("error", {}).get("message") == "nope", "%r" % (res,))
    if verbose:
        print("  400, 403 and 404 returned as they arrived")
    print("every other status is the caller's business")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_retry_policy_and_cooldown_are_independent(verbose):
    failures = 0
    # A read can replay in place. A write that needs reconciliation must
    # leave this process, even when Retry-After would permit a short sleep.
    endpoint = Endpoint(graph=[(503, b"busy", headers(Retry_After="0")), (200, b"{}", headers())])
    with scripted(endpoint):
        status, _ = msgraph.http("GET", ME)
    failures += check("a safe read replays", status == 200 and len(endpoint.calls) == 2)

    for policy in (msgraph.RetryPolicy.NEVER, msgraph.RetryPolicy.RESTART):
        key = "test-policy-" + policy.value
        endpoint = Endpoint(graph=[(503, b"busy", headers(Retry_After="999"))])
        restarted = False
        status = None
        with scripted(endpoint), patch.object(msgraph, "RATE_KEY", key):
            try:
                status, _ = msgraph.http("PATCH", ME, {}, retry_policy=policy)
            except ratelimit.Throttled:
                restarted = True
        failures += check(policy.value + " records the account cooldown", ratelimit.cooldown_remaining(key) > 990)
        failures += check(policy.value + " sends one request", len(endpoint.calls) == 1)
        failures += check(policy.value + " controls job restart", restarted == (policy is msgraph.RetryPolicy.RESTART))
        if policy is msgraph.RetryPolicy.NEVER:
            failures += check("an uncertain write reaches the caller", status == 503)

    # 429 is an explicit refusal, so even a create can retry that rejection.
    endpoint = Endpoint(graph=[(429, b"busy", headers(Retry_After="0")), (201, b"{}", headers())])
    with scripted(endpoint):
        status, _ = msgraph.http("POST", ME, {}, retry_policy=msgraph.RetryPolicy.NEVER)
    failures += check("a rejected create may retry", status == 201 and len(endpoint.calls) == 2)
    print("retry permission is distinct from account cooldown")
    return failures


def test_revoked_grant_refreshes_once(verbose):
    """§3b: a 401 on a token this disk still calls valid forces one refresh
    and repeats the request once, with the new token."""
    sign_in()
    endpoint = Endpoint(
        graph=[(401, {"error": {"message": "InvalidAuthenticationToken"}}, headers()),
               (200, {"displayName": "Someone"}, headers())],
        token=[(200, {"access_token": "new", "refresh_token": "r2", "expires_in": 3600}, headers())])
    with scripted(endpoint):
        status, res = msgraph.graph("GET", "/me")
    failures = 0
    failures += check("the retry succeeds", status == 200 and res.get("displayName") == "Someone",
                      "%r %r" % (status, res))
    failures += check("refreshed exactly once", len(endpoint.to("token")) == 1,
                      "%d refreshes" % len(endpoint.to("token")))
    failures += check("asked Graph exactly twice", len(endpoint.to("graph")) == 2,
                      "%d requests" % len(endpoint.to("graph")))
    sent = [call[3] for call in endpoint.to("graph")]
    failures += check("the retry carries the new token", sent == ["Bearer old", "Bearer new"],
                      "%r" % (sent,))
    failures += check("the new token is kept",
                      msgraph.load_json(msgraph.TOKENS, {}).get("access_token") == "new",
                      "%r" % (msgraph.load_json(msgraph.TOKENS, {}).get("access_token"),))
    if verbose:
        print("  %r" % (sent,))
    print("a revoked-looking 401 refreshes once and retries once")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_dead_grant_is_forgotten(verbose):
    """And when the forced refresh cannot revive it, the token comes off the
    disk and the answer is the plain "not signed in" the UI knows how to
    offer a sign-in for — not a Graph error string the user cannot act on."""
    sign_in()
    endpoint = Endpoint(
        graph=[(401, {"error": {"message": "InvalidAuthenticationToken"}}, headers())],
        token=[(400, {"error": "invalid_grant",
                      "error_description": "AADSTS50173: token revoked"}, headers())])
    code = None
    with scripted(endpoint) as printed:
        try:
            msgraph.graph("GET", "/me")
        except SystemExit as e:
            code = e.code
    answer = answered(printed)
    failures = 0
    failures += check("a dead grant fails", code == 1, "exit %r" % (code,))
    failures += check("it fails as not signed in", answer.get("error") == "not signed in",
                      "%r" % (answer,))
    failures += check("it is not dressed up as retryable", "kind" not in answer, "%r" % (answer,))
    failures += check("the dead token is gone", not os.path.exists(msgraph.TOKENS))
    failures += check("Graph was asked only once", len(endpoint.to("graph")) == 1,
                      "%d requests" % len(endpoint.to("graph")))
    if verbose:
        print("  answered %r" % (answer,))
    print("a grant that will not refresh is deleted, not re-reported")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_ordinary_expiry_keeps_its_message(verbose):
    """The everyday path is untouched: a token that simply ran out and cannot
    be renewed still says "sign-in expired" and still stays on the disk, so
    only the forced path throws a sign-in away."""
    sign_in(expires_in=-10)
    endpoint = Endpoint(token=[(400, {"error": "invalid_grant",
                                      "error_description": "expired"}, headers())])
    code = None
    with scripted(endpoint) as printed:
        try:
            msgraph.access_token()
        except SystemExit as e:
            code = e.code
    answer = answered(printed)
    failures = 0
    failures += check("an expired sign-in fails", code == 1, "exit %r" % (code,))
    failures += check("it says the sign-in expired",
                      answer.get("error", "").startswith("sign-in expired:"), "%r" % (answer,))
    failures += check("the token is left where it was", os.path.exists(msgraph.TOKENS))
    if verbose:
        print("  answered %r" % (answer,))
    print("an ordinary expiry keeps its own message")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_a_blip_during_a_forced_refresh_keeps_the_token(verbose):
    """Where §3a and §3b meet, and the one ordering that must not drift.

    A forced refresh is the path that deletes a sign-in, and it is reached by
    any 401. If the token endpoint answers that refresh with a 500 — Microsoft
    having a bad minute, not the grant being gone — the transient failure has
    to win: the request is re-run and the token stays. Classify it the other
    way round, or delete before classifying, and a passing server blip signs
    the user out of a provider whose grant was never revoked.
    """
    sign_in()
    endpoint = Endpoint(
        graph=[(401, {"error": {"message": "InvalidAuthenticationToken"}}, headers())],
        token=[(500, {"error": "temporarily_unavailable"}, headers())])
    code = None
    with scripted(endpoint) as printed:
        try:
            msgraph.graph("GET", "/me")
        except SystemExit as e:
            code = e.code
    answer = answered(printed)
    failures = 0
    failures += check("a blip fails the job", code == 1, "exit %r" % (code,))
    failures += check("a blip is transient, not a sign-out",
                      answer.get("kind") == "transient", "%r" % (answer,))
    failures += check("the sign-in survives a blip", os.path.exists(msgraph.TOKENS),
                      "the token file was deleted")
    failures += check("and survives it intact",
                      msgraph.load_json(msgraph.TOKENS, {}).get("refresh_token") == "refresh-me",
                      "%r" % (msgraph.load_json(msgraph.TOKENS, {}),))
    if verbose:
        print("  answered %r" % (answer,))
    print("a server blip during a forced refresh keeps the sign-in")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_optional_scopes_cannot_break_required_refresh(verbose):
    failures = 0
    required = "offline_access User.Read Notes.ReadWrite"
    base_grant = "User.Read Notes.ReadWrite"
    for optional_granted, optional_accepted in [(False, False), (True, True), (True, False)]:
        sign_in()
        token = msgraph.load_json(msgraph.TOKENS, {})
        token.update({"expires_at": 0, "scope": base_grant + (" Files.Read" if optional_granted else "")})
        msgraph.save_private(msgraph.TOKENS, token)
        requests = []

        def refresh(method, url, data, **kwargs):
            requests.append(data["scope"].split())
            if "Files.Read" in requests[-1] and not optional_accepted:
                return 400, {"error": "invalid_scope"}
            return 200, {"access_token": "new", "refresh_token": "new-refresh", "expires_in": 3600,
                         "scope": base_grant + (" Files.Read" if optional_accepted else "")}

        with patch.object(msgraph, "SCOPES", required), patch.object(msgraph, "OPTIONAL_SCOPES", "Files.Read"):
            with patch.object(msgraph, "http", side_effect=refresh), patch.object(msgraph, "forget_token") as forget:
                access = msgraph.access_token(force=True)
                failures += check("optional failure never signs out", not forget.called)
        saved = msgraph.load_json(msgraph.TOKENS, {})
        failures += check("required sign-in remains usable", access == "new" and saved.get("access_token") == "new")
        failures += check("unconsented scopes are never requested", ("Files.Read" in requests[0]) == optional_granted)
        failures += check("optional failure retries required scopes", len(requests) == (2 if optional_granted and not optional_accepted else 1))
        failures += check("effective grant drops unavailable optional permission",
                          ("Files.Read" in saved.get("scope", "").split()) == optional_accepted)
        if verbose:
            print("  scopes requested: %r" % requests)
    print("optional scope renewal falls back without breaking required access")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_optional_refresh_with_malformed_reply_or_omitted_scope(verbose):
    sign_in()
    token = msgraph.load_json(msgraph.TOKENS, {})
    token.update({"expires_at": 0, "scope": "User.Read Notes.ReadWrite Files.Read"})
    msgraph.save_private(msgraph.TOKENS, token)
    with patch.object(msgraph, "SCOPES", "offline_access User.Read Notes.ReadWrite"):
        with patch.object(msgraph, "OPTIONAL_SCOPES", "Files.Read"):
            with patch.object(msgraph, "http", side_effect=[(200, None), (200, {
                "access_token": "base-only", "refresh_token": "new-refresh", "expires_in": 3600})]) as request:
                access = msgraph.access_token()
    saved = msgraph.load_json(msgraph.TOKENS, {})
    failures = check("malformed optional reply retries required grant", access == "base-only" and request.call_count == 2)
    failures += check("omitted scope does not retain stale optional grant", "Files.Read" not in saved.get("scope", "").split())
    print("malformed optional replies and omitted scopes preserve base access")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_cache_session_and_inflight_refresh(verbose):
    sign_in(expires_in=-1)
    with patch.object(msgraph, "out") as output:
        msgraph.cmd_status()
        session = output.call_args.args[0]["cacheSession"]
        msgraph.cmd_status()
        failures = check("status assigns one stable cache session",
                         bool(session) and output.call_args.args[0]["cacheSession"] == session)
    with patch.object(msgraph, "http", return_value=(200, {
            "access_token": "renewed", "refresh_token": "renewed-refresh", "expires_in": 3600})):
        msgraph.access_token()
    failures += check("refresh retains the cache session",
                      msgraph.signed_in(CLIENT_ID).get("cacheSession") == session)

    def identified_during_refresh(*args, **kwargs):
        current = msgraph.signed_in(CLIENT_ID)
        current["userId"] = "stable-recovery-account"
        msgraph.save_private(msgraph.TOKENS, current)
        return 200, {"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600}

    with patch.object(msgraph, "http", side_effect=identified_during_refresh):
        msgraph.access_token(force=True)
    failures += check("refresh preserves a concurrent recovery identity lookup",
                      msgraph.signed_in(CLIENT_ID).get("userId") == "stable-recovery-account")

    for action, status in (("logout", 200), ("other account", 200), ("other account", 400)):
        def reply(*args, **kwargs):
            if action == "logout":
                msgraph.forget_token()
            else:
                token = msgraph.signed_in(CLIENT_ID)
                token.update(cacheSession="other", access_token="other-access", refresh_token="other-refresh")
                msgraph.save_private(msgraph.TOKENS, token)
            return status, {"access_token": "late", "refresh_token": "late-refresh", "expires_in": 3600}

        sign_in()
        with patch.object(msgraph, "out") as output:
            msgraph.cmd_status()
            printed = io.StringIO()
            with patch.object(msgraph, "http", side_effect=reply), contextlib.redirect_stdout(printed):
                try:
                    msgraph.access_token(force=True)
                    failures += check("late refresh must fail after " + action, False)
                except SystemExit:
                    failures += check("late refresh reports account change",
                                      answered(printed).get("error") == "the signed-in account changed")
        current = msgraph.signed_in(CLIENT_ID)
        failures += check("late refresh cannot undo " + action,
                          current is None if action == "logout" else current.get("access_token") == "other-access")
    print("cache sessions survive refresh and reject late account responses")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    total = 0
    try:
        total += test_throttled_statuses(args.verbose)
        total += test_transient_statuses(args.verbose)
        total += test_other_statuses_reach_the_caller(args.verbose)
        total += test_retry_policy_and_cooldown_are_independent(args.verbose)
        total += test_revoked_grant_refreshes_once(args.verbose)
        total += test_dead_grant_is_forgotten(args.verbose)
        total += test_ordinary_expiry_keeps_its_message(args.verbose)
        total += test_a_blip_during_a_forced_refresh_keeps_the_token(args.verbose)
        total += test_optional_scopes_cannot_break_required_refresh(args.verbose)
        total += test_optional_refresh_with_malformed_reply_or_omitted_scope(args.verbose)
        total += test_cache_session_and_inflight_refresh(args.verbose)
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
