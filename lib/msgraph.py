#!/usr/bin/env python3
"""Microsoft Sticky Notes bridge for Note Note.

Sticky Notes sync into the Outlook mailbox's "Notes" folder, which Microsoft
Graph exposes as a well-known mail folder. This script wraps the OAuth 2.0
device-code flow and the handful of Graph calls the plugin needs. Standard
library only.

  msgraph.py status              -> {"configured":bool,"signedIn":bool,"account":str}
  msgraph.py login               -> line 1: {"userCode","verificationUri","message"}
                                    then blocks; last line: {"ok":true,"account":...}
  msgraph.py logout
  msgraph.py list [--cached]     -> {"notes":[{id,title,body,modified}], "cached":bool}
  msgraph.py update <id> <file>  -> reads {"title","body"} from file, PATCHes the note
  msgraph.py delete <id>
  msgraph.py create            -> {"ok":true,"note":{id,title,body,modified}}

OneNote (needs the Notes.ReadWrite scope; `status` reports "onenote": true when
the stored token carries it):
  msgraph.py onenote-list [--cached]        -> {"sections":[{id,name,notebook}],
                                                "pages":[{id,sectionId,title,modified}]}
  msgraph.py onenote-page <id>              -> {"title","body","editable"}
  msgraph.py onenote-update <id> <file>     -> reads {"title","body"}; replaces the page body
  msgraph.py onenote-create <sectionId> <file> -> {"ok":true,"page":{...}}
  msgraph.py onenote-delete <id>

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
TOKENS = os.path.join(STATE_DIR, "note-note-ms-token.json")
CACHE = os.path.join(CACHE_DIR, "note-note-sticky.json")
# Note Note's own public-client registration (Microsoft Entra, multi-tenant +
# personal accounts, public client flows enabled, delegated Mail.ReadWrite,
# User.Read, offline_access). Fill in once; every user signs in through it.
CLIENT_ID = "e5652641-e704-4d1a-a62f-df67d7053a30"
TENANT = "common"

SCOPES = "offline_access User.Read Mail.ReadWrite Notes.ReadWrite"
ONENOTE_CACHE = os.path.join(CACHE_DIR, "note-note-onenote.json")
ONENOTE_IMG_DIR = os.path.join(CACHE_DIR, "note-note-onenote-img")
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
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def config():
    cfg = load_json(CONFIG, {}).get("microsoft", {})
    client_id = cfg.get("clientId", "").strip() or CLIENT_ID
    tenant = cfg.get("tenant", "").strip() or TENANT
    return client_id, tenant


def http(method, url, data=None, headers=None, form=False):
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
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
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


def graph(method, path, data=None, extra_headers=None):
    headers = {"Authorization": "Bearer " + access_token(), "Accept": "application/json"}
    headers.update(extra_headers or {})
    url = path if path.startswith("http") else GRAPH + path
    return http(method, url, data, headers)


# ---------------------------------------------------------------- commands

def has_onenote(tok):
    return "Notes.ReadWrite" in (tok or {}).get("scope", "")


def cmd_status():
    client_id, _ = config()
    tok = load_json(TOKENS, None) if client_id else None
    out({"configured": bool(client_id), "signedIn": bool(tok), "account": (tok or {}).get("account", ""),
         "onenote": has_onenote(tok)})


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
    for p in (TOKENS, CACHE, ONENOTE_CACHE):
        try:
            os.remove(p)
        except OSError:
            pass
    out({"ok": True})


def to_note(m):
    body = (m.get("body") or {}).get("content", "") or ""
    # Sticky Notes keep subject == first line of the body, so the title is
    # not a separate thing to show or edit; the body is the note.
    return {
        "id": m["id"],
        "title": "",
        "body": body.replace("\r\n", "\n").rstrip("\n"),
        "modified": m.get("lastModifiedDateTime", ""),
    }


def cmd_list(cached):
    if cached:
        c = load_json(CACHE, None)
        if c is not None:
            out({"notes": c.get("notes", []), "cached": True})
            return
        out({"notes": [], "cached": True})
        return
    notes = []
    url = ("/me/mailFolders/notes/messages?$select=id,subject,body,lastModifiedDateTime"
           "&$orderby=lastModifiedDateTime%20desc&$top=100")
    while url:
        status, res = graph("GET", url, extra_headers={"Prefer": 'outlook.body-content-type="text"'})
        if status != 200:
            fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
                 else str(res.get("error", status)))
        notes.extend(to_note(m) for m in res.get("value", []))
        url = res.get("@odata.nextLink")
    os.makedirs(CACHE_DIR, exist_ok=True)
    save_private(CACHE, {"notes": notes, "fetched": time.time()})
    out({"notes": notes, "cached": False})


def cmd_update(note_id, path):
    payload = load_json(path, None)
    if payload is None:
        fail("cannot read payload")
    body = payload.get("body", "")
    first = next((l.strip() for l in body.split("\n") if l.strip()), "")
    data = {"body": {"contentType": "text", "content": body}, "subject": first[:255]}
    status, res = graph("PATCH", "/me/messages/" + urllib.parse.quote(note_id, safe=""), data)
    if status not in (200, 201):
        fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
             else str(res.get("error", status)))
    # Keep the cache in step so a reopen shows the edit even before a refresh.
    c = load_json(CACHE, {"notes": []})
    for n in c.get("notes", []):
        if n["id"] == note_id:
            n["body"] = body
            n["modified"] = res.get("lastModifiedDateTime", n.get("modified", ""))
    save_private(CACHE, c)
    out({"ok": True})


def cmd_create():
    # A message in the Notes folder is only a sticky note if its MAPI message
    # class says so; PR_MESSAGE_CLASS is 0x001A.
    data = {"subject": "", "body": {"contentType": "text", "content": ""},
            "singleValueExtendedProperties": [{"id": "String 0x001A", "value": "IPM.StickyNote"}]}
    status, res = graph("POST", "/me/mailFolders/notes/messages", data)
    if status not in (200, 201) or "id" not in res:
        fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
             else str(res.get("error", status)))
    note = to_note(res)
    c = load_json(CACHE, {"notes": []})
    c["notes"] = [note] + [n for n in c.get("notes", []) if n["id"] != note["id"]]
    save_private(CACHE, c)
    out({"ok": True, "note": note})


# ---------------------------------------------------------------- OneNote

import html as _html
from html.parser import HTMLParser


class _TextExtractor(HTMLParser):
    """HTML -> plain text: block elements break lines, everything else is
    inline. Good enough for the text OneNote pages are made of."""
    BLOCK = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "table", "ul", "ol", "title"}

    def __init__(self):
        super().__init__()
        self.parts, self.skip, self.rich = [], 0, False

    def handle_starttag(self, tag, attrs):
        if tag in ("img", "object", "iframe", "video", "audio"):
            self.rich = True
        if tag in ("title", "style", "script"):
            self.skip += 1
        if tag in ("p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr") or tag == "br":
            self.parts.append("\n")
        if tag == "li":
            self.parts.append("- ")

    def handle_endtag(self, tag):
        if tag in ("title", "style", "script"):
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)

    def text(self):
        t = "".join(self.parts).replace("\r", "")
        lines = [l.rstrip() for l in t.split("\n")]
        # Collapse runs of blank lines to one and trim the ends.
        outl, blank = [], False
        for l in lines:
            if l.strip():
                outl.append(l.strip()); blank = False
            elif not blank and outl:
                outl.append(""); blank = True
        while outl and not outl[-1]:
            outl.pop()
        return "\n".join(outl)


def html_to_text(html):
    p = _TextExtractor()
    p.feed(html)
    return p.text(), p.rich


def text_to_html(text):
    return "".join("<p>%s</p>" % (_html.escape(l) if l.strip() else "<br/>") for l in text.split("\n")) or "<p></p>"


def graph_raw(method, path, data=None, content_type=None, extra_headers=None):
    """Graph call with a non-JSON body (OneNote HTML) and a text response."""
    headers = {"Authorization": "Bearer " + access_token()}
    if content_type:
        headers["Content-Type"] = content_type
    headers.update(extra_headers or {})
    url = path if path.startswith("http") else GRAPH + path
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except urllib.error.URLError as e:
        fail("network error: %s" % e.reason)


def graph_err(res, status):
    err = res.get("error") if isinstance(res, dict) else None
    if isinstance(err, dict):
        return err.get("message", "Graph error %s" % status)
    return str(err or res or status)


def cmd_onenote_list(cached):
    if cached:
        c = load_json(ONENOTE_CACHE, None) or {"sections": [], "pages": []}
        out({"sections": c.get("sections", []), "pages": c.get("pages", []), "cached": True})
        return
    sections = []
    url = "/me/onenote/sections?$select=id,displayName,parentNotebook&$expand=parentNotebook($select=id,displayName)&$top=100"
    while url:
        status, res = graph("GET", url)
        if status != 200:
            fail(graph_err(res, status))
        for sct in res.get("value", []):
            sections.append({"id": sct["id"], "name": sct.get("displayName", ""),
                             "notebook": (sct.get("parentNotebook") or {}).get("displayName", ""),
                             "notebookId": (sct.get("parentNotebook") or {}).get("id", "")})
        url = res.get("@odata.nextLink")
    # Pages are listed per section: the account-wide /me/onenote/pages call
    # refuses accounts with many sections. Each call takes a couple of
    # seconds, so sections are fetched in parallel.
    from concurrent.futures import ThreadPoolExecutor

    token = access_token()  # refresh once, not from eight threads at a time

    def section_pages(sct):
        found = []
        url = ("/me/onenote/sections/%s/pages?$select=id,title,lastModifiedDateTime&$orderby=lastModifiedDateTime%%20desc&$top=100"
               % urllib.parse.quote(sct["id"], safe=""))
        while url:
            status, res = http("GET", url if url.startswith("http") else GRAPH + url, headers={
                "Authorization": "Bearer " + token, "Accept": "application/json"})
            if status != 200:
                return {"error": graph_err(res, status)}
            for pg in res.get("value", []):
                found.append({"id": pg["id"], "title": pg.get("title", "") or "",
                              "sectionId": sct["id"], "modified": pg.get("lastModifiedDateTime", "")})
            url = res.get("@odata.nextLink")
        return found

    pages = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for result in pool.map(section_pages, sections):
            if isinstance(result, dict):
                fail(result["error"])
            pages.extend(result)
    os.makedirs(CACHE_DIR, exist_ok=True)
    save_private(ONENOTE_CACHE, {"sections": sections, "pages": pages, "fetched": time.time()})
    out({"sections": sections, "pages": pages, "cached": False})


def cached_image(src, width=0):
    """Download a page image through Graph (the src needs our token) into the
    cache and return a file:// URL the editor can show. The editor draws
    images at their natural size, so the file is scaled to the width OneNote
    declares (when ImageMagick is around to do it)."""
    import hashlib, shutil, subprocess
    os.makedirs(ONENOTE_IMG_DIR, exist_ok=True)
    name = hashlib.sha1(("%s@%d" % (src, width)).encode()).hexdigest()
    path = os.path.join(ONENOTE_IMG_DIR, name)
    if not os.path.exists(path):
        req = urllib.request.Request(src, headers={"Authorization": "Bearer " + access_token()})
        try:
            with urllib.request.urlopen(req, timeout=60) as r, open(path + ".tmp", "wb") as f:
                f.write(r.read())
        except (urllib.error.URLError, OSError):
            return src
        magick = shutil.which("magick") or shutil.which("convert")
        if width > 0 and magick:
            subprocess.run([magick, path + ".tmp", "-resize", "%dx>" % width, path + ".tmp"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.replace(path + ".tmp", path)
    return "file://" + path


def cmd_onenote_page(page_id):
    status, html = graph_raw("GET", "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content")
    if status != 200:
        try:
            fail(graph_err(json.loads(html), status))
        except ValueError:
            fail("Graph error %s" % status)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import onenote_md
    r = onenote_md.html_to_markdown(html, cached_image)
    out({"title": r["title"], "body": r["body"], "editable": r["editable"], "markdown": True})


def cmd_onenote_update(page_id, path):
    payload = load_json(path, None)
    if payload is None:
        fail("cannot read payload")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import onenote_md
    ops = [{"target": "body", "action": "replace",
            "content": "<div>%s</div>" % onenote_md.markdown_to_onenote_html(payload.get("body", ""))}]
    if "title" in payload:
        ops.append({"target": "title", "action": "replace", "content": _html.escape(payload["title"])})
    status, res = graph_raw("PATCH", "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content",
                            json.dumps(ops).encode(), "application/json")
    if status not in (200, 204):
        try:
            fail(graph_err(json.loads(res), status))
        except ValueError:
            fail("Graph error %s" % status)
    out({"ok": True})


def cmd_onenote_create(section_id, path):
    payload = load_json(path, None) or {}
    title = _html.escape(payload.get("title", "") or "")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import onenote_md
    html = "<!DOCTYPE html><html><head><title>%s</title></head><body>%s</body></html>" % (
        title, onenote_md.markdown_to_onenote_html(payload.get("body", "")))
    status, res = graph_raw("POST", "/me/onenote/sections/" + urllib.parse.quote(section_id, safe="") + "/pages",
                            html.encode(), "application/xhtml+xml")
    if status not in (200, 201):
        try:
            fail(graph_err(json.loads(res), status))
        except ValueError:
            fail("Graph error %s" % status)
    pg = json.loads(res)
    page = {"id": pg["id"], "title": pg.get("title", "") or "", "sectionId": section_id,
            "modified": pg.get("lastModifiedDateTime", "")}
    c = load_json(ONENOTE_CACHE, {"sections": [], "pages": []})
    c["pages"] = [page] + [p for p in c.get("pages", []) if p["id"] != page["id"]]
    save_private(ONENOTE_CACHE, c)
    out({"ok": True, "page": page})


def cmd_onenote_delete(page_id):
    status, res = graph_raw("DELETE", "/me/onenote/pages/" + urllib.parse.quote(page_id, safe=""))
    if status not in (204, 200, 404):
        try:
            fail(graph_err(json.loads(res), status))
        except ValueError:
            fail("Graph error %s" % status)
    c = load_json(ONENOTE_CACHE, {"sections": [], "pages": []})
    c["pages"] = [p for p in c.get("pages", []) if p["id"] != page_id]
    save_private(ONENOTE_CACHE, c)
    out({"ok": True})


def cmd_delete(note_id):
    status, res = graph("DELETE", "/me/messages/" + urllib.parse.quote(note_id, safe=""))
    if status not in (204, 200, 404):
        fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
             else str(res.get("error", status)))
    c = load_json(CACHE, {"notes": []})
    c["notes"] = [n for n in c.get("notes", []) if n["id"] != note_id]
    save_private(CACHE, c)
    out({"ok": True})


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "status":
        cmd_status()
    elif cmd == "login":
        cmd_login()
    elif cmd == "logout":
        cmd_logout()
    elif cmd == "list":
        cmd_list("--cached" in argv[2:])
    elif cmd == "update" and len(argv) >= 4:
        cmd_update(argv[2], argv[3])
    elif cmd == "delete" and len(argv) >= 3:
        cmd_delete(argv[2])
    elif cmd == "create":
        cmd_create()
    elif cmd == "onenote-list":
        cmd_onenote_list("--cached" in argv[2:])
    elif cmd == "onenote-page" and len(argv) >= 3:
        cmd_onenote_page(argv[2])
    elif cmd == "onenote-update" and len(argv) >= 4:
        cmd_onenote_update(argv[2], argv[3])
    elif cmd == "onenote-create" and len(argv) >= 4:
        cmd_onenote_create(argv[2], argv[3])
    elif cmd == "onenote-delete" and len(argv) >= 3:
        cmd_onenote_delete(argv[2])
    else:
        fail("usage: msgraph.py status|login|logout|list [--cached]|update <id> <file>|delete <id>|create", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except Exception as e:  # never leave the caller without JSON
        fail("%s: %s" % (type(e).__name__, e))
