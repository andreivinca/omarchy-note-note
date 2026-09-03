#!/usr/bin/env python3
"""Microsoft account service for Note Note providers.

Owns the OAuth 2.0 device-code sign-in, the token file and its refresh, and
the Graph HTTP helpers that provider scripts (sticky.py, onenote.py) import.
Standard library only.

  msgraph.py status              -> {"configured":bool,"signedIn":bool,"account":str}
  msgraph.py login               -> line 1: {"userCode","verificationUri","message"}
                                    then blocks; last line: {"ok":true,"account":...}
  msgraph.py logout

The app registration is the provider's own (its `microsoftClientId`, handed
in through the environment below), registered once by the plugin author;
users only sign in to their account. An optional
~/.config/omarchy/note-note.json
{"microsoft": {"<provider id>": {"clientId": ..., "tenant": ...}}}
gives one provider a registration of the user's own instead.
"""
import json, os, sys, time, urllib.request, urllib.parse, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import ratelimit  # noqa: E402
# The error and IO shape every provider answers with lives in lib/provider_io.py
# so that there is one of each (see its docstring). It is re-exported from here
# unchanged: onenote.py and sticky.py import these names from `msgraph`, and
# where a helper is defined is not their business.
from provider_io import (  # noqa: E402,F401
    out, fail, fail_throttled, fail_transient, load_json, save_private, read_payload,
    THROTTLED_STATUSES, TRANSIENT_STATUSES,
)

HOME = os.path.expanduser("~")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", HOME + "/.config"), "omarchy/note-note.json")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "omarchy")
# Each provider signs in on its own: it points the script at its own token
# file (NOTE_NOTE_MS_TOKEN), asks only for its own scopes (NOTE_NOTE_MS_SCOPES)
# and names its own app registration (NOTE_NOTE_MS_CLIENT_ID) — Sticky Notes
# and OneNote share this code and nothing else. NOTE_NOTE_MS_ACCOUNT is the
# provider's id, under which CONFIG may hold a registration of the user's own.
LEGACY_TOKENS = os.path.join(STATE_DIR, "note-note-ms-token.json")
TOKENS = os.environ.get("NOTE_NOTE_MS_TOKEN") or LEGACY_TOKENS
ACCOUNT = os.environ.get("NOTE_NOTE_MS_ACCOUNT", "")
# The provider's public-client registration (Microsoft Entra: personal and
# work accounts, public client flows enabled). Every user of that provider
# signs in through it. Empty — no provider behind the call — and nobody can.
CLIENT_ID = os.environ.get("NOTE_NOTE_MS_CLIENT_ID", "")
TENANT = "common"
# The one registration every token came from before each provider had its
# own. A token that does not say who issued it is from there.
LEGACY_CLIENT_ID = "e5652641-e704-4d1a-a62f-df67d7053a30"

# Providers declare the scopes they need; each passes only its own in.
SCOPES = os.environ.get("NOTE_NOTE_MS_SCOPES", "offline_access User.Read")
GRAPH = "https://graph.microsoft.com/v1.0"


def config():
    """The registration this provider signs in through: its own, unless the
    user gave it one of theirs under its id in CONFIG."""
    entries = load_json(CONFIG, {}).get("microsoft", {})
    own = entries.get(ACCOUNT, {}) if isinstance(entries, dict) and ACCOUNT else {}
    if not isinstance(own, dict):
        own = {}
    client_id = str(own.get("clientId", "")).strip() or CLIENT_ID
    tenant = str(own.get("tenant", "")).strip() or TENANT
    return client_id, tenant


# Default ceiling for a response body; callers pass their own max_bytes.
MAX_BODY = 8 * 1024 * 1024


def read_bounded(resp, max_bytes):
    """Read at most max_bytes (+1 to detect overflow) from a response."""
    raw = resp.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise OverflowError("response larger than %d bytes" % max_bytes)
    return raw


# Pacing. An importer sets these two before it makes any request — sticky.py
# and onenote.py each name their own key, so a throttle on one never parks the
# other (providers/PROVIDERS.md, the rate-key table). Left unset, nothing here
# is paced at all, which is what an unaware caller of msgraph.py gets.
RATE_KEY = None
RATE_WINDOWS = []
GRAPH_ORIGIN = "https://graph.microsoft.com/"


def rate_key_for(url):
    """The key a URL is paced against, or None for one that must not be.

    Only Graph counts against a provider's budget. The sign-in endpoints are
    deliberately unpaced: a token refresh that waited behind a Graph cooldown
    would turn "OneNote is busy" into "you are signed out".
    """
    return RATE_KEY if (RATE_KEY and url.startswith(GRAPH_ORIGIN)) else None


def wait_asked_by(error):
    """How long a 429/503 wants us to wait.

    Graph's OneNote throttles usually carry no `Retry-After` at all, and a
    throttled account stays that way for tens of minutes — so a missing
    header on a 429 means a real cooldown, not a guess at a short one. A 503
    is a blip and is worth one short retry in place.
    """
    wait = ratelimit.retry_after_of(error.headers)
    if wait is not None:
        return wait
    return ratelimit.SHORT_RETRY if error.code == 503 else ratelimit.DEFAULT_COOLDOWN


def http(method, url, data=None, headers=None, form=False, max_bytes=MAX_BODY,
         transient_5xx=True):
    """One Graph request, paced and retried.

    The retry loop is `ratelimit.attempt_loop`: short waits are slept here,
    and anything longer becomes a `Throttled` the caller reports upwards
    rather than a process sitting blocked for ten minutes. (The hand-rolled
    loop this replaced fell off its own end and returned None when all three
    attempts were throttled, which reached the caller as a TypeError.)

    `transient_5xx` is the caller saying whether running this job twice is
    the same as running it once. A 502 or a 504 is a gateway losing the
    *answer*, not the far end refusing the request — the write may well have
    landed — so "re-run it" is only safe for a request that is repeatable.
    It is on by default because most requests here are reads or replaces;
    the creates, the sign-in and anything carrying an upload turn it off, and
    take the failure as it stands instead of risking a second copy.
    """
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)

    def once():
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = read_bounded(r, max_bytes)
                return r.status, (json.loads(raw) if raw else {})
        except OverflowError as e:
            fail(str(e))
        except urllib.error.HTTPError as e:
            raw = e.read(max_bytes + 1)[:max_bytes]
            if e.code in THROTTLED_STATUSES:
                raise ratelimit.Retry(wait_asked_by(e))
            if transient_5xx and e.code in TRANSIENT_STATUSES:
                fail_transient(e.code, raw)
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"error": raw.decode(errors="replace")}
        except urllib.error.URLError as e:
            fail("network error: %s" % e.reason)

    return ratelimit.attempt_loop(rate_key_for(url), RATE_WINDOWS, once)


# ---------------------------------------------------------------- tokens

def token_url(tenant):
    return "https://login.microsoftonline.com/%s/oauth2/v2.0/token" % tenant


def signed_in(client_id):
    """The token file, if it is a sign-in through `client_id`. A refresh
    token works only with the registration that issued it, so a token from
    another one — a provider given a registration of its own, or the user's
    override changing — is no sign-in at all, and the provider asks again."""
    tok = load_json(TOKENS, None)
    if not tok or tok.get("client_id", LEGACY_CLIENT_ID) != client_id:
        return None
    return tok


def forget_token(expected_refresh=None):
    """Throw the sign-in away. `cmd_status` then reports signed out and the
    provider shows its sign-in row, which is the only useful thing to offer
    once the token on disk is known to be dead.

    `expected_refresh` guards a race that only exists because this file is
    shared: a lane runs up to four processes at once (lib/ratelimit.py), and
    Entra rotates the refresh token every time one is used. Two processes that
    meet a 401 together both force a refresh; the first is answered and writes
    the new token, and the second is told `invalid_grant` about a refresh
    token that is merely no longer current. Deleting then would sign the user
    out of a grant that is perfectly alive, so the file goes only while it
    still holds the very token whose refresh failed. `cmd_logout` passes
    nothing and means it unconditionally.
    """
    if expected_refresh is not None and (load_json(TOKENS, None) or {}).get("refresh_token") != expected_refresh:
        return
    try:
        os.remove(TOKENS)
    except OSError:
        pass


def access_token(force=False):
    """This provider's access token, refreshed when it has to be.

    Ordinarily "has to be" is the stored `expires_at`, minus a minute. `force`
    is the other case, and it is the answer to a 401 on a token this disk
    still calls valid: the grant was revoked at Microsoft's end — consent
    withdrawn, an admin action, a conditional-access change — and nothing here
    can know that until it asks. A forced refresh either hands back a working
    token or proves the sign-in is gone, and one that is gone is deleted
    rather than left to 401 forever behind a raw Graph error.

    `signed_in()` handles the neighbouring case, a token issued by a
    registration that is no longer this provider's; this handles the
    registration being right and the grant being gone.
    """
    client_id, tenant = config()
    if not client_id:
        fail("not configured")
    tok = signed_in(client_id)
    if not tok:
        fail("not signed in")
    if not force and tok.get("expires_at", 0) - 60 > time.time():
        return tok["access_token"]
    used = tok.get("refresh_token", "")
    status, res = http("POST", token_url(tenant), {
        "client_id": client_id, "grant_type": "refresh_token",
        "refresh_token": used, "scope": SCOPES,
    }, form=True)
    if status != 200 or "access_token" not in res:
        if force:
            # `invalid_grant` has two meanings here and they want opposite
            # answers. If another process refreshed while this one was asking,
            # the rotation is why this failed and its token is the good one —
            # take it rather than reporting a sign-out that is not true.
            fresh = signed_in(client_id)
            if fresh and fresh.get("refresh_token") != used:
                return fresh["access_token"]
            forget_token(used)
            fail("not signed in")
        fail("sign-in expired: %s" % res.get("error_description", res.get("error", status)))
    tok.update(res)
    tok["expires_at"] = time.time() + int(res.get("expires_in", 3600))
    tok["client_id"] = client_id
    save_private(TOKENS, tok)
    return tok["access_token"]


def graph(method, path, data=None, extra_headers=None, max_bytes=MAX_BODY, transient_5xx=True):
    """One Graph request, signed — and signed again once if the 401 says the
    token was revoked rather than merely old. The second pass is the same one
    call with `force`, so there is no second copy of the request to keep in
    step with the first."""
    url = path if path.startswith("http") else GRAPH + path

    def send(force):
        headers = {"Authorization": "Bearer " + access_token(force), "Accept": "application/json"}
        headers.update(extra_headers or {})
        return http(method, url, data, headers, max_bytes=max_bytes, transient_5xx=transient_5xx)

    status, res = send(False)
    if status == 401:
        status, res = send(True)
    return status, res


# ---------------------------------------------------------------- commands

def adopt_legacy_token():
    """A token from before per-provider sign-in carries every scope; seed a
    missing provider token from it so nobody has to sign in again. Only
    once: after that a missing token means the user signed out."""
    marker = TOKENS + ".seeded"
    if TOKENS != LEGACY_TOKENS and not os.path.exists(TOKENS) and not os.path.exists(marker) and os.path.exists(LEGACY_TOKENS):
        tok = load_json(LEGACY_TOKENS, None)
        if tok:
            save_private(TOKENS, tok)
            save_private(marker, {"seededFrom": LEGACY_TOKENS})


def cmd_status():
    adopt_legacy_token()
    client_id, _ = config()
    tok = signed_in(client_id) if client_id else None
    out({"configured": bool(client_id), "signedIn": bool(tok), "account": (tok or {}).get("account", ""),
         "scope": (tok or {}).get("scope", "")})


def cmd_login():
    client_id, tenant = config()
    if not client_id:
        fail("not configured")
    # Nothing in this flow may be re-run by the host. The user is reading a
    # code off the screen, and a second run mints a different one — so a 5xx
    # anywhere here is delivered as it stands rather than as "transient".
    status, res = http("POST", "https://login.microsoftonline.com/%s/oauth2/v2.0/devicecode" % tenant,
                       {"client_id": client_id, "scope": SCOPES}, form=True, transient_5xx=False)
    if status != 200 or "device_code" not in res:
        fail(res.get("error_description", res.get("error", "device code request failed")))
    out({"userCode": res["user_code"], "verificationUri": res["verification_uri"], "message": res.get("message", "")})
    interval = int(res.get("interval", 5))
    deadline = time.time() + int(res.get("expires_in", 900))
    while time.time() < deadline:
        time.sleep(interval)
        status, tok = http("POST", token_url(tenant), {
            "client_id": client_id, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": res["device_code"],
        }, form=True, transient_5xx=False)
        if status == 200 and "access_token" in tok:
            tok["expires_at"] = time.time() + int(tok.get("expires_in", 3600))
            tok["client_id"] = client_id
            save_private(TOKENS, tok)
            # Asked with the token just minted, not through `graph()`: this
            # probe is allowed to fail (the account name is a nicety, hence
            # the `else ""`), and `graph()` would answer a 401 here — Entra
            # replication lag right after a redemption is real — by forcing a
            # refresh and, if that failed too, deleting the sign-in the user
            # has this second completed.
            s, me = http("GET", GRAPH + "/me?$select=displayName,userPrincipalName,mail",
                         headers={"Authorization": "Bearer " + tok["access_token"],
                                  "Accept": "application/json"}, transient_5xx=False)
            tok["account"] = (me.get("mail") or me.get("userPrincipalName") or me.get("displayName") or "") if s == 200 else ""
            save_private(TOKENS, tok)
            out({"ok": True, "account": tok["account"]})
            return
        err = tok.get("error", "")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 5
            continue
        fail(tok.get("error_description", err or "sign-in failed"))
    fail("the code expired before you signed in")


def cmd_logout():
    # Providers keep their own caches and clear them on their "signed out".
    forget_token()
    out({"ok": True})


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "status":
        cmd_status()
    elif cmd == "login":
        cmd_login()
    elif cmd == "logout":
        cmd_logout()
    else:
        fail("usage: msgraph.py status|login|logout", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except ratelimit.Throttled as t:
        fail_throttled(t)
    except Exception as e:  # never leave the caller without JSON
        fail("%s: %s" % (type(e).__name__, e))
