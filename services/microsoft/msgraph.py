#!/usr/bin/env python3
"""Microsoft account service for Note Note providers.

Owns the OAuth 2.0 device-code sign-in, the token file and its refresh, and
the Graph HTTP helpers that provider scripts (sticky.py, onenote.py) import.
Standard library only.

  msgraph.py status              -> {"configured":bool,"signedIn":bool,"account":str}
  msgraph.py login               -> line 1: {"userCode","verificationUri","message"}
                                    then blocks; last line: {"ok":true,"account":...}
  msgraph.py logout

The app registration is the plugin's own (CLIENT_ID below), registered once
by the plugin author; users only sign in to their account. An optional
~/.config/omarchy/note-note.json {"microsoft": {"clientId": ..., "tenant": ...}}
overrides it, for people who prefer their own registration.
"""
import json, os, sys, time, urllib.request, urllib.parse, urllib.error

HOME = os.path.expanduser("~")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", HOME + "/.config"), "omarchy/note-note.json")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "omarchy")
# Each provider signs in on its own: it points the script at its own token
# file (NOTE_NOTE_MS_TOKEN) and asks only for its own scopes
# (NOTE_NOTE_MS_SCOPES). The app registration and this code are shared.
LEGACY_TOKENS = os.path.join(STATE_DIR, "note-note-ms-token.json")
TOKENS = os.environ.get("NOTE_NOTE_MS_TOKEN") or LEGACY_TOKENS
# Note Note's own public-client registration (Microsoft Entra, multi-tenant +
# personal accounts, public client flows enabled, delegated Mail.ReadWrite,
# User.Read, offline_access). Fill in once; every user signs in through it.
CLIENT_ID = "e5652641-e704-4d1a-a62f-df67d7053a30"
TENANT = "common"

# Providers declare the scopes they need; the host passes the union in.
SCOPES = os.environ.get("NOTE_NOTE_MS_SCOPES", "offline_access User.Read")
GRAPH = "https://graph.microsoft.com/v1.0"


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def fail(msg, code=1):
    out({"error": msg})
    sys.exit(code)


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
    cfg = load_json(CONFIG, {}).get("microsoft", {})
    client_id = cfg.get("clientId", "").strip() or CLIENT_ID
    tenant = cfg.get("tenant", "").strip() or TENANT
    return client_id, tenant


# Default ceiling for a response body; callers pass their own max_bytes.
MAX_BODY = 8 * 1024 * 1024


def read_bounded(resp, max_bytes):
    """Read at most max_bytes (+1 to detect overflow) from a response."""
    raw = resp.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise OverflowError("response larger than %d bytes" % max_bytes)
    return raw


def http(method, url, data=None, headers=None, form=False, max_bytes=MAX_BODY):
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
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = read_bounded(r, max_bytes)
                return r.status, (json.loads(raw) if raw else {})
        except OverflowError as e:
            fail(str(e))
        except urllib.error.HTTPError as e:
            raw = e.read(max_bytes + 1)[:max_bytes]
            # Throttled: Graph says how long to wait. Honour it (bounded) and retry.
            if e.code in (429, 503) and attempt < 2:
                try:
                    wait = float(e.headers.get("Retry-After", "3"))
                except ValueError:
                    wait = 3.0
                time.sleep(min(max(wait, 1.0), 15.0))
                continue
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"error": raw.decode(errors="replace")}
        except urllib.error.URLError as e:
            fail("network error: %s" % e.reason)


# ---------------------------------------------------------------- tokens

def token_url(tenant):
    return "https://login.microsoftonline.com/%s/oauth2/v2.0/token" % tenant


def access_token():
    client_id, tenant = config()
    if not client_id:
        fail("not configured")
    tok = load_json(TOKENS, None)
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
    tok = load_json(TOKENS, None) if client_id else None
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
    except Exception as e:  # never leave the caller without JSON
        fail("%s: %s" % (type(e).__name__, e))
