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
import json, os, sys, time, urllib.parse, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
sys.path.insert(0, HERE)
import ratelimit  # noqa: E402
# The error and IO shape every provider answers with. This script carried its
# own copies of these until they were lifted into lib/provider_io.py; see its
# docstring for why one of each is the point.
from provider_io import (  # noqa: E402
    out, fail, fail_throttled, fail_transient, load_json, save_private, read_payload,
    THROTTLED_STATUSES, TRANSIENT_STATUSES,
)
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
# Notion's published limit is an average of three requests a second. It used
# to be kept by sleeping 0.34 s between requests inside one process, which
# said nothing about the other processes the host may have running at the same
# moment; the pacer counts them all (lib/ratelimit.py).
RATE_KEY = "notion"
RATE_WINDOWS = [(1, 3)]


def token():
    t = load_json(TOKEN_FILE, {}).get("token", "")
    if not t:
        fail("not configured")
    return t


def api(method, path, data=None, tok=None, transient_5xx=True):
    """One Notion request, paced across processes and retried.

    Notion answers a 429 with a `Retry-After`, and its limit is per second
    rather than a long lockout, so a missing header means a short wait rather
    than a real cooldown. A 502 used to wait here too; it is a bad gateway
    rather than a busy account, so it goes back as "transient" with the other
    server errors and re-runs the one job (lib/provider_io.py).

    `transient_5xx` is the caller saying whether that re-run is safe. A 502 or
    a 504 is the gateway losing the answer to a request that may well have
    been carried out, so only a repeatable one may be run again — `cmd_create`
    is not, and says so.
    """
    headers = {"Authorization": "Bearer " + (tok or token()), "Notion-Version": VERSION, "Content-Type": "application/json"}
    req = urllib.request.Request(API + path, data=json.dumps(data).encode() if data is not None else None, method=method, headers=headers)

    def once():
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read(MAX_BODY + 1)
                if len(raw) > MAX_BODY:
                    fail("response larger than %d bytes" % MAX_BODY)
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read(MAX_BODY + 1)[:MAX_BODY]
            if e.code in THROTTLED_STATUSES:
                wait = ratelimit.retry_after_of(e.headers)
                raise ratelimit.Retry(wait if wait is not None else ratelimit.SHORT_RETRY)
            if transient_5xx and e.code in TRANSIENT_STATUSES:
                fail_transient(e.code, raw)
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"message": raw.decode(errors="replace")[:200]}
        except urllib.error.URLError as e:
            fail("network error: %s" % e.reason)

    return ratelimit.attempt_loop(RATE_KEY, RATE_WINDOWS, once)


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
        status, res = api("GET", "/blocks/%s/children?page_size=100%s" % (
            urllib.parse.quote(block_id, safe=""),
            ("&start_cursor=" + urllib.parse.quote(cursor, safe="")) if cursor else ""))
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
    status, pg = api("GET", "/pages/" + urllib.parse.quote(page_id, safe=""))
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
    quoted = urllib.parse.quote(page_id, safe="")
    # Title: the page's title property (name varies; find it).
    status, pg = api("GET", "/pages/" + quoted)
    if status != 200:
        fail(err(pg, status))
    tprop = next((k for k, v in (pg.get("properties") or {}).items() if v.get("type") == "title"), None)
    if tprop and "title" in payload and payload["title"] != title_of(pg):
        status, res = api("PATCH", "/pages/" + quoted, {"properties": {tprop: {"title": [{"type": "text", "text": {"content": payload["title"][:2000]}}]}}})
        if status != 200:
            fail(err(res, status))
    # Body: replace the top-level blocks (children come along with their
    # parents) — new ones in first, old ones out afterwards, and in that order.
    #
    # Written the other way round this deleted the page and only then converted
    # the markdown and sent it back, so the note spent a conversion and one
    # round trip per hundred blocks not existing. Anything that ended the run
    # inside that window ended it with the note gone and no way back: a 400
    # from a block Notion will not take is delivered as it stands, and the app
    # being killed says nothing at all.
    #
    # Reversing it is safe because Notion *appends* children: every PATCH
    # lands after everything already on the page, so the ids recorded here
    # cannot name anything that was just written and deleting them last cannot
    # touch it. The worst case becomes the note twice over — visible, and
    # something the user can fix.
    old, _ = fetch_children(page_id, [MAX_BLOCKS + 1])
    new = notion_md.markdown_to_blocks(payload.get("body", ""))
    for i in range(0, len(new), 100):
        status, res = api("PATCH", "/blocks/%s/children" % quoted, {"children": new[i:i + 100]})
        if status != 200:
            fail(err(res, status))
    for b in old:
        status, res = api("DELETE", "/blocks/" + urllib.parse.quote(b["id"], safe=""))
        if status not in (200, 204):
            fail(err(res, status))
    out({"ok": True})


def cmd_create(parent_id, path):
    payload = read_payload(path) or {}
    body = {"parent": {"page_id": parent_id}, "properties": {"title": {"title": [{"type": "text", "text": {"content": payload.get("title", "") or ""}}]}},
            "children": notion_md.markdown_to_blocks(payload.get("body", ""))[:100]}
    # Never re-run on a 5xx: a 502 or a 504 here is the gateway losing the
    # answer to a page that Notion may already have created, and the retry
    # would leave the user with the same note two or three times over. The
    # failure is reported instead, and one create the user can repeat is a
    # far better outcome than three they did not ask for.
    status, res = api("POST", "/pages", body, transient_5xx=False)
    if status != 200:
        fail(err(res, status))
    page = {"id": res["id"], "title": title_of(res), "parent": parent_of(res), "edited": res.get("last_edited_time", "")}
    c = load_json(CACHE, {"pages": []})
    c["pages"] = [page] + [p for p in c.get("pages", []) if p["id"] != page["id"]]
    save_private(CACHE, c)
    out({"ok": True, "page": page})


def cmd_delete(page_id):
    status, res = api("PATCH", "/pages/" + urllib.parse.quote(page_id, safe=""), {"archived": True})
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
    except ratelimit.Throttled as t:
        fail_throttled(t)
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
