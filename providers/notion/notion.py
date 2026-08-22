#!/usr/bin/env python3
"""Notion provider script for Note Note. Standard library only.

Talks to the official Notion API with an internal integration secret that the
user pastes into the provider's setup screen (stored owner-only in
~/.local/state/omarchy/note-note-notion.json). Pages must be shared with the
integration in Notion ("Connections") to be visible.

  notion.py status                 -> {"configured":bool,"workspace":str}
  notion.py setup <file>           -> reads {"token"}; verifies it; stores it
  notion.py logout
  notion.py list [--cached|--max-age S] -> {"pages":[{id,title,parent,edited}],"cached":bool}
  notion.py page <id>              -> {"title","body"(markdown),"editable"}
  notion.py update <id> <file>     -> reads {"title","body"}; replaces the page's blocks
  notion.py create <parentId> <file> -> {"ok":true,"page":{...}}
  notion.py delete <id>            -> archives the page
  notion.py clear-cache
"""
import json, os, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import notion_md  # noqa: E402

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "omarchy")
TOKEN_FILE = os.path.join(STATE_DIR, "note-note-notion.json")
CACHE = os.path.join(CACHE_DIR, "note-note-notion.json")
API = "https://api.notion.com/v1"
VERSION = "2022-06-28"

# This provider's limits.
MAX_PAGES = 1000
MAX_BLOCKS = 300            # per page; more opens read-only
MAX_BODY = 4 * 1024 * 1024  # one API response
MIN_GAP = 0.34              # seconds between requests (3 req/s)
_last = [0.0]


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
def token():
    t = load_json(TOKEN_FILE, {}).get("token", "")
    if not t:
        fail("not configured")
    return t


def api(method, path, data=None, tok=None):
    gap = MIN_GAP - (time.time() - _last[0])
    if gap > 0:
        time.sleep(gap)
    _last[0] = time.time()
    headers = {"Authorization": "Bearer " + (tok or token()), "Notion-Version": VERSION, "Content-Type": "application/json"}
    req = urllib.request.Request(API + path, data=json.dumps(data).encode() if data is not None else None, method=method, headers=headers)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read(MAX_BODY + 1)
                if len(raw) > MAX_BODY:
                    fail("response larger than %d bytes" % MAX_BODY)
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read(MAX_BODY + 1)[:MAX_BODY]
            if e.code in (429, 502, 503) and attempt < 2:
                try:
                    wait = float(e.headers.get("Retry-After", "2"))
                except ValueError:
                    wait = 2.0
                time.sleep(min(max(wait, 1.0), 15.0))
                continue
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"message": raw.decode(errors="replace")[:200]}
        except urllib.error.URLError as e:
            fail("network error: %s" % e.reason)


def err(res, status):
    return (res.get("message") if isinstance(res, dict) else None) or ("Notion error %s" % status)


def title_of(page):
    props = page.get("properties", {}) or {}
    for p in props.values():
        if p.get("type") == "title":
            return "".join(t.get("plain_text", "") for t in p.get("title", [])).strip()
    return ""


def parent_of(page):
    par = page.get("parent", {}) or {}
    return par.get("page_id") or par.get("database_id") or ("workspace" if par.get("workspace") else "")


# ---------------------------------------------------------------- commands

def cmd_status():
    cfg = load_json(TOKEN_FILE, {})
    out({"configured": bool(cfg.get("token")), "workspace": cfg.get("workspace", "")})


def cmd_setup(path):
    payload = read_payload(path) or {}
    tok = (payload.get("token") or "").strip()
    if not tok:
        fail("paste the integration secret")
    status, res = api("GET", "/users/me", tok=tok)
    if status != 200:
        fail(err(res, status))
    name = (res.get("bot") or {}).get("workspace_name") or res.get("name") or "Notion"
    save_private(TOKEN_FILE, {"token": tok, "workspace": name})
    out({"ok": True, "workspace": name})


def cmd_logout():
    for p in (TOKEN_FILE, CACHE):
        try:
            os.remove(p)
        except OSError:
            pass
    out({"ok": True})


def cmd_list(cached, max_age=0):
    c = load_json(CACHE, None)
    if cached or (max_age and c and time.time() - c.get("fetched", 0) < max_age):
        c = c or {"pages": []}
        out({"pages": c.get("pages", []), "cached": True})
        return
    pages, cursor = [], None
    while len(pages) < MAX_PAGES:
        body = {"filter": {"property": "object", "value": "page"}, "sort": {"direction": "descending", "timestamp": "last_edited_time"}, "page_size": 100}
        if cursor:
            body["start_cursor"] = cursor
        status, res = api("POST", "/search", body)
        if status != 200:
            fail(err(res, status))
        for pg in res.get("value", res.get("results", [])):
            if pg.get("archived"):
                continue
            pages.append({"id": pg["id"], "title": title_of(pg), "parent": parent_of(pg), "edited": pg.get("last_edited_time", "")})
        if not res.get("has_more"):
            break
        cursor = res.get("next_cursor")
    pages = pages[:MAX_PAGES]
    os.makedirs(CACHE_DIR, exist_ok=True)
    save_private(CACHE, {"pages": pages, "fetched": time.time()})
    out({"pages": pages, "cached": False})


def fetch_children(block_id, budget):
    """All child blocks, recursively, within a block budget; returns (blocks, truncated)."""
    blocks, cursor = [], None
    while True:
        status, res = api("GET", "/blocks/%s/children?page_size=100%s" % (block_id, "&start_cursor=" + cursor if cursor else ""))
        if status != 200:
            fail(err(res, status))
        for b in res.get("results", []):
            if budget[0] <= 0:
                return blocks, True
            budget[0] -= 1
            if b.get("has_children") and b.get("type") != "child_page":
                kids, trunc = fetch_children(b["id"], budget)
                b["children"] = kids
                if trunc:
                    return blocks + [b], True
            blocks.append(b)
        if not res.get("has_more"):
            return blocks, False
        cursor = res.get("next_cursor")


def cmd_page(page_id):
    status, pg = api("GET", "/pages/" + page_id)
    if status != 200:
        fail(err(pg, status))
    blocks, truncated = fetch_children(page_id, [MAX_BLOCKS])
    md, editable = notion_md.blocks_to_markdown(blocks)
    if truncated:
        md += "\n\n[page continues — more than %d blocks; edit it in Notion]" % MAX_BLOCKS
        editable = False
    out({"title": title_of(pg), "body": md, "editable": editable})


def cmd_update(page_id, path):
    payload = read_payload(path)
    if payload is None:
        fail("cannot read payload")
    # Title: the page's title property (name varies; find it).
    status, pg = api("GET", "/pages/" + page_id)
    if status != 200:
        fail(err(pg, status))
    tprop = next((k for k, v in (pg.get("properties") or {}).items() if v.get("type") == "title"), None)
    if tprop and "title" in payload and payload["title"] != title_of(pg):
        status, res = api("PATCH", "/pages/" + page_id, {"properties": {tprop: {"title": [{"type": "text", "text": {"content": payload["title"][:2000]}}]}}})
        if status != 200:
            fail(err(res, status))
    # Body: replace top-level blocks (children come along with their parents).
    old, _ = fetch_children(page_id, [MAX_BLOCKS + 1])
    for b in old:
        status, res = api("DELETE", "/blocks/" + b["id"])
        if status not in (200, 204):
            fail(err(res, status))
    new = notion_md.markdown_to_blocks(payload.get("body", ""))
    for i in range(0, len(new), 100):
        status, res = api("PATCH", "/blocks/%s/children" % page_id, {"children": new[i:i + 100]})
        if status != 200:
            fail(err(res, status))
    out({"ok": True})


def cmd_create(parent_id, path):
    payload = read_payload(path) or {}
    body = {"parent": {"page_id": parent_id}, "properties": {"title": {"title": [{"type": "text", "text": {"content": payload.get("title", "") or ""}}]}},
            "children": notion_md.markdown_to_blocks(payload.get("body", ""))[:100]}
    status, res = api("POST", "/pages", body)
    if status != 200:
        fail(err(res, status))
    page = {"id": res["id"], "title": title_of(res), "parent": parent_of(res), "edited": res.get("last_edited_time", "")}
    c = load_json(CACHE, {"pages": []})
    c["pages"] = [page] + [p for p in c.get("pages", []) if p["id"] != page["id"]]
    save_private(CACHE, c)
    out({"ok": True, "page": page})


def cmd_delete(page_id):
    status, res = api("PATCH", "/pages/" + page_id, {"archived": True})
    if status != 200:
        fail(err(res, status))
    c = load_json(CACHE, {"pages": []})
    c["pages"] = [p for p in c.get("pages", []) if p["id"] != page_id]
    save_private(CACHE, c)
    out({"ok": True})


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "status":
        cmd_status()
    elif cmd == "setup" and len(argv) >= 3:
        cmd_setup(argv[2])
    elif cmd == "logout":
        cmd_logout()
    elif cmd == "list":
        age = 0
        if "--max-age" in argv:
            try:
                age = int(argv[argv.index("--max-age") + 1])
            except (IndexError, ValueError):
                age = 0
        cmd_list("--cached" in argv[2:], age)
    elif cmd == "page" and len(argv) >= 3:
        cmd_page(argv[2])
    elif cmd == "update" and len(argv) >= 4:
        cmd_update(argv[2], argv[3])
    elif cmd == "create" and len(argv) >= 4:
        cmd_create(argv[2], argv[3])
    elif cmd == "delete" and len(argv) >= 3:
        cmd_delete(argv[2])
    elif cmd == "clear-cache":
        try:
            os.remove(CACHE)
        except OSError:
            pass
        out({"ok": True})
    else:
        fail("usage: notion.py status|setup <file>|logout|list [--cached|--max-age S]|page <id>|update <id> <file>|create <parentId> <file>|delete <id>|clear-cache", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
