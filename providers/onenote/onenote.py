#!/usr/bin/env python3
"""OneNote provider script for Note Note (needs the Notes.ReadWrite scope).

  onenote.py list [--cached|--max-age S] -> {"sections":[{id,name,notebook,notebookId}],
                                           "pages":[{id,sectionId,title,modified}]}
                                           --cached: cache only; --max-age S: cache if younger than S seconds
  onenote.py page <id>                  -> {"title","body"(markdown),"editable"}
  onenote.py update <id> <file>         -> reads {"title","originalTitle","body"}
  onenote.py create <sectionId> <file>  -> {"ok":true,"page":{...}}
  onenote.py delete <id>
"""
import html as _html
import json, os, re, sys, time, urllib.parse, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "services", "microsoft"))
sys.path.insert(0, HERE)
from msgraph import graph, http, fail, out, load_json, save_private, read_payload, access_token, CACHE_DIR, GRAPH  # noqa: E402
import onenote_md  # noqa: E402

ONENOTE_CACHE = os.path.join(CACHE_DIR, "note-note-onenote.json")
ONENOTE_IMG_DIR = os.path.join(CACHE_DIR, "note-note-onenote-img")
# This provider's limits: what it will read from Graph and keep around.
MAX_SECTIONS = 500
MAX_PAGES = 3000
MAX_LIST_BODY = 4 * 1024 * 1024   # one page of a listing
MAX_PAGE_HTML = 4 * 1024 * 1024   # a page's content
MAX_IMAGE = 20 * 1024 * 1024      # one cached image


# ---------------------------------------------------------------- OneNote



def graph_raw(method, path, data=None, content_type=None, extra_headers=None, max_bytes=MAX_PAGE_HTML):
    """Graph call with a non-JSON body (OneNote HTML) and a text response."""
    headers = {"Authorization": "Bearer " + access_token()}
    if content_type:
        headers["Content-Type"] = content_type
    headers.update(extra_headers or {})
    url = path if path.startswith("http") else GRAPH + path
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read(max_bytes + 1)
                if len(raw) > max_bytes:
                    fail("response larger than %d bytes" % max_bytes)
                return r.status, raw.decode(errors="replace")
        except urllib.error.HTTPError as e:
            body = e.read(max_bytes + 1)[:max_bytes].decode(errors="replace")
            if e.code in (429, 503) and attempt < 2:
                try:
                    wait = float(e.headers.get("Retry-After", "3"))
                except ValueError:
                    wait = 3.0
                time.sleep(min(max(wait, 1.0), 15.0))
                continue
            return e.code, body
        except urllib.error.URLError as e:
            fail("network error: %s" % e.reason)


def graph_err(res, status):
    err = res.get("error") if isinstance(res, dict) else None
    if isinstance(err, dict):
        return err.get("message", "Graph error %s" % status)
    return str(err or res or status)


def cmd_onenote_list(cached, max_age=0):
    c = load_json(ONENOTE_CACHE, None)
    if cached or (max_age and c and time.time() - c.get("fetched", 0) < max_age):
        c = c or {"sections": [], "pages": []}
        out({"sections": c.get("sections", []), "pages": c.get("pages", []), "cached": True})
        return
    sections = []
    url = "/me/onenote/sections?$select=id,displayName,parentNotebook&$expand=parentNotebook($select=id,displayName)&$top=100"
    while url and len(sections) < MAX_SECTIONS:
        status, res = graph("GET", url, max_bytes=MAX_LIST_BODY)
        if status != 200:
            fail(graph_err(res, status))
        for sct in res.get("value", []):
            sections.append({"id": sct["id"], "name": sct.get("displayName", ""),
                             "notebook": (sct.get("parentNotebook") or {}).get("displayName", ""),
                             "notebookId": (sct.get("parentNotebook") or {}).get("id", "")})
        url = res.get("@odata.nextLink")
    sections = sections[:MAX_SECTIONS]
    # Pages are listed per section: the account-wide /me/onenote/pages call
    # refuses accounts with many sections. Each call takes a couple of
    # seconds, so sections are fetched in parallel.
    from concurrent.futures import ThreadPoolExecutor

    token = access_token()  # refresh once, not from eight threads at a time

    def section_pages(sct):
        found = []
        url = ("/me/onenote/sections/%s/pages?$select=id,title,lastModifiedDateTime&$orderby=lastModifiedDateTime%%20desc&$top=100"
               % urllib.parse.quote(sct["id"], safe=""))
        while url and len(found) < MAX_PAGES:
            status, res = http("GET", url if url.startswith("http") else GRAPH + url, headers={
                "Authorization": "Bearer " + token, "Accept": "application/json"}, max_bytes=MAX_LIST_BODY)
            if status != 200:
                return {"error": graph_err(res, status)}
            for pg in res.get("value", []):
                found.append({"id": pg["id"], "title": pg.get("title", "") or "",
                              "sectionId": sct["id"], "modified": pg.get("lastModifiedDateTime", "")})
            url = res.get("@odata.nextLink")
        return found

    pages = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(section_pages, sections):
            if isinstance(result, dict):
                fail(result["error"])
            pages.extend(result)
    pages = pages[:MAX_PAGES]
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
                raw = r.read(MAX_IMAGE + 1)
                if len(raw) > MAX_IMAGE:
                    return src            # shown as a link, not downloaded
                f.write(raw)
        except (urllib.error.URLError, OSError):
            return src
        magick = shutil.which("magick") or shutil.which("convert")
        if width > 0 and magick:
            subprocess.run([magick, path + ".tmp", "-resize", "%dx>" % width, path + ".tmp"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.replace(path + ".tmp", path)
    return "file://" + path


def cmd_onenote_pages(section_ids):
    """Pages of a few sections (one request each) — for cheap refreshes."""
    found = []
    for sid in section_ids[:10]:
        url = ("/me/onenote/sections/%s/pages?$select=id,title,lastModifiedDateTime&$orderby=lastModifiedDateTime%%20desc&$top=100"
               % urllib.parse.quote(sid, safe=""))
        while url and len(found) < MAX_PAGES:
            status, res = graph("GET", url, max_bytes=MAX_LIST_BODY)
            if status != 200:
                fail(graph_err(res, status))
            for pg in res.get("value", []):
                found.append({"id": pg["id"], "title": pg.get("title", "") or "", "sectionId": sid, "modified": pg.get("lastModifiedDateTime", "")})
            url = res.get("@odata.nextLink")
    c = load_json(ONENOTE_CACHE, None)
    if c:
        c["pages"] = [p for p in c.get("pages", []) if p["sectionId"] not in section_ids] + found
        save_private(ONENOTE_CACHE, c)
    out({"sections": section_ids[:10], "pages": found})


def cmd_onenote_page(page_id):
    status, html = graph_raw("GET", "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content")
    if status != 200:
        try:
            fail(graph_err(json.loads(html), status))
        except ValueError:
            fail("Graph error %s" % status)
    r = onenote_md.html_to_markdown(html, cached_image)
    out({"title": r["title"], "body": r["body"], "editable": r["editable"], "markdown": True})


def cmd_onenote_update(page_id, path):
    payload = read_payload(path)
    if payload is None:
        fail("cannot read payload")
    url = "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content"
    ops = [{"target": "body", "action": "replace",
            "content": "<div>%s</div>" % onenote_md.markdown_to_onenote_html(payload.get("body", ""))}]
    status, res = graph_raw("PATCH", url, json.dumps(ops).encode(), "application/json")
    if status not in (200, 204):
        try:
            fail(graph_err(json.loads(res), status))
        except ValueError:
            fail("Graph error %s" % status)
    # The title goes in its own request, and only when it changed: on some
    # (older) pages Graph answers a title replace with a 500 "Transient
    # error" every time, and bundling it would sink the body save too.
    warning = ""
    if "title" in payload and payload["title"] != payload.get("originalTitle", payload["title"]):
        ops = [{"target": "title", "action": "replace", "content": _html.escape(payload["title"])}]
        status, res = graph_raw("PATCH", url, json.dumps(ops).encode(), "application/json")
        if status not in (200, 204):
            try:
                warning = "title not saved: " + graph_err(json.loads(res), status)
            except ValueError:
                warning = "title not saved (Graph error %s)" % status
    out({"ok": True, "warning": warning} if warning else {"ok": True})


def cmd_onenote_create(section_id, path):
    payload = read_payload(path) or {}
    title = _html.escape(payload.get("title", "") or "")
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




def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "list":
        age = 0
        if "--max-age" in argv:
            try:
                age = int(argv[argv.index("--max-age") + 1])
            except (IndexError, ValueError):
                age = 0
        cmd_onenote_list("--cached" in argv[2:], age)
    elif cmd == "pages" and len(argv) >= 3:
        cmd_onenote_pages(argv[2:])
    elif cmd == "page" and len(argv) >= 3:
        cmd_onenote_page(argv[2])
    elif cmd == "update" and len(argv) >= 4:
        cmd_onenote_update(argv[2], argv[3])
    elif cmd == "create" and len(argv) >= 4:
        cmd_onenote_create(argv[2], argv[3])
    elif cmd == "delete" and len(argv) >= 3:
        cmd_onenote_delete(argv[2])
    elif cmd == "clear-cache":
        try:
            os.remove(ONENOTE_CACHE)
        except OSError:
            pass
        out({"ok": True})
    else:
        fail("usage: onenote.py list [--cached]|page <id>|update <id> <file>|create <sectionId> <file>|delete <id>|clear-cache", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
