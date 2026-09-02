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


def http(method, url, data=None, headers=None, form=False, max_bytes=MAX_BODY):
    """One Graph request, paced and retried.

    The retry loop is `ratelimit.attempt_loop`: short waits are slept here,
    and anything longer becomes a `Throttled` the caller reports upwards
    rather than a process sitting blocked for ten minutes. (The hand-rolled
    loop this replaced fell off its own end and returned None when all three
    attempts were throttled, which reached the caller as a TypeError.)
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
            if e.code in (429, 503):
                raise ratelimit.Retry(wait_asked_by(e))
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


def access_token():
    client_id, tenant = config()
    if not client_id:
        fail("not configured")
    tok = signed_in(client_id)
    if not tok:
        fail("not signed in")
    if tok.get("expires_at", 0) - 60 > time.time():
        return tok["access_token"]
    status, res = http("POST", token_url(tenant), {
        "client_id": client_id, "grant_type": "refresh_token",
        "refresh_token": tok.get("refresh_token", ""), "scope": SCOPES,
    }, form=True)
    if status != 200 or "access_token" not in res:
        fail("sign-in expired: %s" % res.get("error_description", res.get("error", status)))
    tok.update(res)
    tok["expires_at"] = time.time() + int(res.get("expires_in", 3600))
    tok["client_id"] = client_id
    save_private(TOKENS, tok)
    return tok["access_token"]


def graph(method, path, data=None, extra_headers=None, max_bytes=MAX_BODY):
    headers = {"Authorization": "Bearer " + access_token(), "Accept": "application/json"}
    headers.update(extra_headers or {})
    url = path if path.startswith("http") else GRAPH + path
    return http(method, url, data, headers, max_bytes=max_bytes)


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
    status, res = http("POST", "https://login.microsoftonline.com/%s/oauth2/v2.0/devicecode" % tenant,
                       {"client_id": client_id, "scope": SCOPES}, form=True)
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
        }, form=True)
        if status == 200 and "access_token" in tok:
            tok["expires_at"] = time.time() + int(tok.get("expires_in", 3600))
            tok["client_id"] = client_id
            save_private(TOKENS, tok)
            s, me = graph("GET", "/me?$select=displayName,userPrincipalName,mail")
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
    try:
        os.remove(TOKENS)
    except OSError:
        pass
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
