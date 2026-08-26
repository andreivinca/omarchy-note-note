#!/usr/bin/env python3
"""OneNote provider script for Note Note (needs the Notes.ReadWrite scope).

  onenote.py list [--cached|--max-age S] -> {"sections":[{id,name,notebook,notebookId}],
                                           "pages":[{id,sectionId,title,modified}]}
                                           --cached: cache only; --max-age S: cache if younger than S seconds
  onenote.py page <id>                  -> {"title","body"(markdown),"editable"}
  onenote.py update <id> <file>         -> reads {"title","originalTitle","body"}
  onenote.py create <sectionId> <file>  -> {"ok":true,"page":{...}}
  onenote.py delete <id>
  onenote.py create-section <notebookId> <file|->  -> {"ok":true,"section":{...}}
"""
import html as _html
import json, os, re, sys, time, urllib.parse, urllib.request, urllib.error, uuid

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
# What may go *up*. Graph rejects a request over 4 MB, and counts every part
# against it, so a save carries a few images at most and says so when it
# cannot: refusing is the only alternative to dropping someone's picture.
MAX_UPLOAD = 3 * 1024 * 1024      # one pasted image
MAX_UPLOAD_TOTAL = 3.5 * 1024 * 1024
MAX_NEW_IMAGES = 4


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
        # Never pass an empty message through: the autosave retries on the
        # status code in the text, and "" retries nothing and explains nothing.
        return err.get("message") or "Graph error %s" % status
    return str(err or res or "") or "Graph error %s" % status


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
    #
    # `$orderby=order` is the page order the OneNote app shows — the one the
    # user set by dragging page tabs — and the sidebar's job is to show a
    # section the way its owner arranged it, not the way it was last touched.
    # Graph sorts by `order` but does not return it: it is absent from the
    # page resource in v1.0 and in beta, and asking for it in `$select` gives
    # null. So the sequence Graph answers in *is* the order, and it is kept
    # from here to the sidebar — `pages` stays a list, never a set, and the
    # provider walks it as given (Provider.qml, rebuild). Nothing here can
    # re-sort it, because there is no key left to sort by.
    from concurrent.futures import ThreadPoolExecutor

    token = access_token()  # refresh once, not from eight threads at a time

    def section_pages(sct):
        found = []
        url = ("/me/onenote/sections/%s/pages?$select=id,title,lastModifiedDateTime&$orderby=order&$top=100"
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


# Page images are only ever fetched from Graph's own resource endpoint, with
# the bearer token, and never across a redirect: an <img src> in page content
# is untrusted and must not be able to send our token (or any request)
# anywhere else. Anything else is shown as text, not loaded.
IMAGE_HOST = "graph.microsoft.com"
IMAGE_PATH_RE = re.compile(r"^/v1\.0/(?:me|users\('[^']*'\))/onenote/resources/[A-Za-z0-9!._-]+/\$value$")
# One page's images share a wall-clock budget and a count; the cache as a
# whole is bounded too, so a page full of unique images can neither hold a
# fetch open nor fill the disk.
IMAGE_BUDGET_SECONDS = 45
MAX_PAGE_IMAGES = 40
MAX_CACHE_BYTES = 200 * 1024 * 1024
MAX_CACHE_FILES = 400
_image_budget = [0.0, 0]        # [deadline (monotonic), images fetched]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_image_opener = urllib.request.build_opener(_NoRedirect)


def image_allowed(src):
    try:
        u = urllib.parse.urlsplit(src)
    except ValueError:
        return False
    return u.scheme == "https" and u.netloc.lower() == IMAGE_HOST and bool(IMAGE_PATH_RE.match(u.path)) and not u.query and not u.fragment


def read_with_deadline(resp, max_bytes, deadline):
    """Read at most max_bytes, giving up if the whole body has not arrived by
    `deadline`: urllib's timeout only bounds a single socket read, so a
    drip-fed response would otherwise never end."""
    chunks, total = [], 0
    while True:
        if time.monotonic() > deadline:
            raise OverflowError("image took too long")
        chunk = resp.read(65536)
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > max_bytes:
            raise OverflowError("image too large")
        chunks.append(chunk)


# A cached image on its own says nothing about where it came from, and a save
# has to hand OneNote the very same resource back. The index remembers that,
# and is written by the page load that filled the cache.
IMAGE_INDEX = os.path.join(ONENOTE_IMG_DIR, "index.json")


def remember_images(page_id, images, complete):
    """What the load saw: where each image came from, and whether it got them
    all. A page whose images could not all be fetched (a throttled account, a
    dropped connection) must not be written back — the note in the editor is
    missing a picture, and saving it would take that picture off the page."""
    index = load_json(IMAGE_INDEX, {})
    files = index.get("files", {})
    for img in images:
        name = os.path.basename(img.get("local", "").replace("file://", ""))
        if name:
            files[name] = {"src": img.get("src", ""), "width": img.get("width", 0)}
    # Entries whose file is gone are dead weight; the cache prunes itself.
    files = {k: v for k, v in files.items() if os.path.exists(os.path.join(ONENOTE_IMG_DIR, k))}
    pages = index.get("pages", {})
    pages.pop(page_id, None)
    pages[page_id] = {"complete": bool(complete)}
    while len(pages) > 500:                      # oldest first; bound the file
        pages.pop(next(iter(pages)))
    save_private(IMAGE_INDEX, {"files": files, "pages": pages})


def images_complete(page_id):
    """Did the last load of this page hold on to every image it has?"""
    page = load_json(IMAGE_INDEX, {}).get("pages", {}).get(page_id)
    return page is None or page.get("complete", True)


def file_path_of(url):
    return urllib.parse.unquote(url[len("file://"):])


def known_image(url):
    """A file:// url from the note -> the OneNote resource it came from."""
    if not url.startswith("file://"):
        return None
    path = file_path_of(url)
    index = load_json(IMAGE_INDEX, {})
    if os.path.dirname(path) == ONENOTE_IMG_DIR:
        return index.get("files", {}).get(os.path.basename(path))
    # A paste the last save already uploaded: the editor still shows the
    # staged file until the page is reloaded, and without this the same bytes
    # would go up again on every autosave in between.
    return index.get("staged", {}).get(path)


def remember_staged(staged, structure):
    """After a save that uploaded parts: which resource each uploaded file
    became, read from the page itself — new images appear in document order,
    the same order the parts were staged in. Both maps are refreshed: a
    cached page image re-uploaded by the fallback gets a new resource, and a
    pasted file must not be uploaded again by the next autosave."""
    index = load_json(IMAGE_INDEX, {})
    known = {entry.get("src", "") for entry in index.get("files", {}).values()}
    known.update(entry.get("src", "") for entry in index.get("staged", {}).values())
    new_srcs = [el["src"] for el in structure if el["kind"] == "image" and el.get("src", "") not in known]
    files, pastes = index.get("files", {}), index.get("staged", {})
    for (path, width), src in zip(staged, new_srcs):
        if os.path.dirname(path) == ONENOTE_IMG_DIR:
            files[os.path.basename(path)] = {"src": src, "width": width}
        else:
            pastes[path] = {"src": src, "width": width}
    index["files"] = files
    index["staged"] = {p: e for p, e in pastes.items() if os.path.exists(p)}
    save_private(IMAGE_INDEX, index)


def prune_image_cache():
    """Keep the image cache under its file-count and byte ceilings, oldest first."""
    try:
        entries = []
        for name in os.listdir(ONENOTE_IMG_DIR):
            if name == "index.json":             # bookkeeping, not a cached image
                continue
            path = os.path.join(ONENOTE_IMG_DIR, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            entries.append((st.st_mtime, st.st_size, path))
    except OSError:
        return
    entries.sort()
    total = sum(e[1] for e in entries)
    while entries and (len(entries) > MAX_CACHE_FILES or total > MAX_CACHE_BYTES):
        _, size, path = entries.pop(0)
        try:
            os.remove(path)
            total -= size
        except OSError:
            pass


def cached_image(src, width=0):
    """A page image, fetched through Graph into the cache; returns a file://
    URL, or None when the source is not Graph's resource endpoint (then the
    page shows the image's alt text instead).

    The bytes are kept exactly as Graph served them — the editor caps its own
    display width, and a save may upload these bytes back, so nothing here may
    rescale or re-encode. `width` is only recorded (via the caller) so a save
    can write the same display width back into the page.
    """
    import hashlib, tempfile
    if not image_allowed(src):
        return None
    if _image_budget[1] >= MAX_PAGE_IMAGES or (_image_budget[0] and time.monotonic() > _image_budget[0]):
        return None                      # the page's image budget is spent
    os.makedirs(ONENOTE_IMG_DIR, mode=0o700, exist_ok=True)
    name = hashlib.sha1(src.encode()).hexdigest()
    path = os.path.join(ONENOTE_IMG_DIR, name)
    try:
        if os.path.getsize(path) > 0:
            return "file://" + path
        os.remove(path)                  # a failed fetch left a stub
    except OSError:
        pass
    req = urllib.request.Request(src, headers={"Authorization": "Bearer " + access_token()})
    fd, tmp = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=ONENOTE_IMG_DIR)   # fresh, 0600, never a symlink
    try:
        deadline = _image_budget[0] or (time.monotonic() + IMAGE_BUDGET_SECONDS)
        with _image_opener.open(req, timeout=20) as r, os.fdopen(fd, "wb") as f:
            data = read_with_deadline(r, MAX_IMAGE, deadline)
            if not data:
                # Graph serves a just-written resource as 200 with an empty
                # body; caching that would poison the page for good.
                raise OverflowError("empty image response")
            f.write(data)
        _image_budget[1] += 1
        os.replace(tmp, path)
        prune_image_cache()
        return "file://" + path
    except (urllib.error.URLError, OSError, OverflowError):
        try:
            os.remove(tmp)
        except OSError:
            pass
        return None


def cmd_onenote_pages(section_ids):
    """Pages of a few sections (one request each) — for cheap refreshes."""
    found = []
    for sid in section_ids[:10]:
        url = ("/me/onenote/sections/%s/pages?$select=id,title,lastModifiedDateTime&$orderby=order&$top=100"
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
    _image_budget[0] = time.monotonic() + IMAGE_BUDGET_SECONDS
    _image_budget[1] = 0
    status, html = graph_raw("GET", "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content")
    if status != 200:
        try:
            fail(graph_err(json.loads(html), status))
        except ValueError:
            fail("Graph error %s" % status)
    r = onenote_md.html_to_markdown(html, cached_image)
    remember_images(page_id, r["images"], r["editable"])
    out({"title": r["title"], "body": r["body"], "editable": r["editable"], "markdown": True})


MIME_BY_SUFFIX = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                  ".gif": "image/gif", ".bmp": "image/bmp", ".tif": "image/tiff", ".tiff": "image/tiff"}


class Uploads:
    """The images a save has to carry, and the rules about how many.

    An image already on the page is handed back by its own resource src and
    costs nothing. A pasted one is read from disk into a part of the request —
    which is where Graph's 4 MB limit bites, so the count and the bytes are
    both bounded and an over-large picture is refused out loud.
    """

    def __init__(self, upload_known=False):
        self.parts = []          # [(part name, mime, bytes)]
        self.staged = []         # [(file path, width)] — same order as parts
        self.bytes = 0
        self.error = ""
        # True: even an image already on the page is re-uploaded from its
        # cached bytes — the fallback for pages that must be rebuilt whole,
        # because handing an image back by src makes OneNote copy it, and a
        # copy can come back empty (docs/engine-notes.md).
        self.upload_known = upload_known

    def ref(self, url, alt):
        """(src for the <img>, width) — the resolver onenote_md renders with."""
        known = known_image(url)
        if known and not self.upload_known:
            return known.get("src", ""), known.get("width", 0)
        if known:
            return self.part(file_path_of(url), "image/png", known.get("width", 0))
        if url.startswith(("https://", "http://")):
            return url, 0                       # a public image OneNote fetches itself
        if not url.startswith("file://"):
            return "", 0
        path = file_path_of(url)
        mime = MIME_BY_SUFFIX.get(os.path.splitext(path)[1].lower())
        if not mime:
            self.error = self.error or "only PNG, JPEG, GIF, BMP and TIFF images can be saved to OneNote"
            return "", 0
        return self.part(path, mime, 0)

    def part(self, path, mime, width):
        if len(self.parts) >= MAX_NEW_IMAGES:
            self.error = self.error or "only %d images can go up in one save" % MAX_NEW_IMAGES
            return "", 0
        try:
            with open(path, "rb") as f:
                data = f.read(MAX_UPLOAD + 1)
        except OSError:
            data = b""
        if not data:
            self.error = self.error or "an image could not be read from disk — open the page again before saving"
            return "", 0
        if len(data) > MAX_UPLOAD:
            self.error = self.error or "an image is larger than %d MB" % (MAX_UPLOAD // (1024 * 1024))
            return "", 0
        if self.bytes + len(data) > MAX_UPLOAD_TOTAL:
            self.error = self.error or "the images in this save are larger than Graph accepts at once"
            return "", 0
        name = "nn-image-%d" % (len(self.parts) + 1)
        self.parts.append((name, mime, data))
        self.staged.append((path, width))
        self.bytes += len(data)
        return "name:" + name, width


def multipart(commands, parts):
    """The Commands part plus one part per image, as Graph wants them."""
    boundary = "NoteNotePart" + uuid.uuid4().hex
    body = [("--%s\r\nContent-Disposition: form-data; name=\"Commands\"\r\n"
             "Content-Type: application/json\r\n\r\n%s\r\n" % (boundary, json.dumps(commands))).encode()]
    for name, mime, data in parts:
        body.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n"
                     "Content-Type: %s\r\n\r\n" % (boundary, name, mime)).encode())
        body.append(data + b"\r\n")
    body.append(("--%s--\r\n" % boundary).encode())
    return "multipart/form-data; boundary=" + boundary, b"".join(body)


def patch_page(url, commands, parts):
    if parts:
        content_type, body = multipart(commands, parts)
    else:
        content_type, body = "application/json", json.dumps(commands).encode()
    return graph_raw("PATCH", url, body, content_type)


def wrap_runs(runs):
    """Runs -> a page body: text in divs a later save can find again, images
    beside them, never inside. Every text run carries a data-id so the next
    save can look up the generated id it needs to replace it."""
    out = []
    for i, run in enumerate(runs):
        if run["kind"] == "image":
            out.append(run["html"])
        else:
            out.append('<div data-id="%s">%s</div>' % (onenote_md.TEXT_RUN_ID % i, run["html"]))
    return "".join(out) or "<div><p></p></div>"


# ---- the surgical save ------------------------------------------------
#
# OneNote copies an image every time it is handed back by its own src — and
# the copy of a resource it has not materialised yet comes back empty forever
# (docs/engine-notes.md). So a save may NEVER send an unchanged image, in any
# form. Instead the page is transformed in place: text runs are replaced where
# they stand, a deleted image becomes an empty div (which OneNote drops), and
# a pasted one is uploaded as a part of the same request. An image that did
# not change is not mentioned by any command at all.

EMPTY_DIV = "<div></div>"


def plan_commands(runs, structure):
    """The PATCH commands that turn the page into the note, or None when the
    page's shape rules the surgical path out (then the caller decides)."""
    for element in structure:
        # A paragraph sitting directly in the outer div (a page written by the
        # OneNote apps) cannot be replaced — only whole divs can.
        if element["kind"] == "text" and not element.get("id", "").startswith("div:"):
            return None
    kept = [run["ref"] for run in runs if run["kind"] == "image" and not run["ref"].startswith("name:")]
    anchors = _anchor_indices(kept, structure)
    if anchors is None:
        return None                      # an image moved, or the page changed under us

    commands = []
    naming = _RunNames()
    bounds = [-1] + anchors + [len(structure)]
    note_segments = _note_segments(runs)
    for k in range(len(kept) + 1):
        page_gap = structure[bounds[k] + 1:bounds[k + 1]]
        content = "".join(_gap_html(run, naming) for run in note_segments[k])
        slots = [el for el in page_gap if el["kind"] == "text"]
        spares = [el for el in page_gap if el["kind"] == "image"]   # deleted images
        if content:
            if slots:
                target = slots.pop(0)["id"]
            elif spares:
                target = spares.pop(0)["id"]
            else:
                commands.append(_insert_command(content, structure, bounds, k))
                target = None
            if target:
                commands.append({"target": target, "action": "replace", "content": content})
        for el in slots + spares:
            commands.append({"target": el["id"], "action": "replace", "content": EMPTY_DIV})
    return [c for c in commands if c]


def _anchor_indices(kept, structure):
    """Where each kept image sits on the page — in order, each used once."""
    srcs = [el.get("src", "") for el in structure]
    out, position = [], 0
    for ref in kept:
        while position < len(structure) and not (structure[position]["kind"] == "image" and srcs[position] == ref):
            position += 1
        if position >= len(structure):
            return None
        out.append(position)
        position += 1
    return out


def _note_segments(runs):
    """The note's runs, split at its kept images: segment k is what belongs
    between page anchors k-1 and k."""
    segments, current = [], []
    for run in runs:
        if run["kind"] == "image" and not run["ref"].startswith("name:"):
            segments.append(current)
            current = []
        else:
            current.append(run)
    segments.append(current)
    return segments


class _RunNames:
    """Fresh, unique data-ids for the text runs a save writes."""

    def __init__(self):
        self.next = int(time.time()) % 1000000 * 100

    def take(self):
        self.next += 1
        return onenote_md.TEXT_RUN_ID % self.next


def _gap_html(run, naming):
    if run["kind"] == "image":
        return run["html"]
    return '<div data-id="%s">%s</div>' % (naming.take(), run["html"])


def _insert_command(content, structure, bounds, k):
    """New content in a gap with nothing to replace: insert it beside an
    anchor image, or append to the body of a page with no anchors at all."""
    if bounds[k] >= 0:
        return {"target": structure[bounds[k]]["id"], "action": "insert", "position": "after", "content": content}
    if bounds[k + 1] < len(structure):
        return {"target": structure[bounds[k + 1]]["id"], "action": "insert", "position": "before", "content": content}
    return {"target": "body", "action": "append", "content": content}


def upload_everything(body_md):
    """The safe fallback for a page whose shape the surgical path cannot
    handle: rewrite the whole body with every image uploaded from the local
    cache — bytes we hold, so nothing depends on OneNote copying a resource.
    Fails loudly when the images will not fit in one request."""
    uploads = Uploads(upload_known=True)
    runs = onenote_md.markdown_to_runs(body_md, uploads.ref)
    if uploads.error:
        fail(uploads.error + " — this page cannot be restructured in one save; edit it in OneNote")
    return [{"target": "body", "action": "replace", "content": "<div>%s</div>" % wrap_runs(runs)}], uploads


def cmd_onenote_update(page_id, path):
    payload = read_payload(path)
    if payload is None:
        fail("cannot read payload")
    if not images_complete(page_id):
        fail("an image on this page could not be loaded — open the page again before saving")
    url = "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content"

    uploads = Uploads()
    runs = onenote_md.markdown_to_runs(payload.get("body", ""), uploads.ref)
    if uploads.error:
        fail(uploads.error)

    if not any(r["kind"] == "image" for r in runs):
        # No images to protect: one plain body replace, as it always was.
        commands, parts = [{"target": "body", "action": "replace",
                            "content": "<div>%s</div>" % wrap_runs(runs)}], uploads.parts
    else:
        # Only the generated ids can target a replace, and OneNote renews
        # them on every write — so each save starts by reading the page back.
        status, current = graph_raw("GET", url + "?includeIDs=true")
        if status != 200:
            try:
                fail(graph_err(json.loads(current), status))
            except ValueError:
                fail("Graph error %s" % status)
        commands = plan_commands(runs, onenote_md.page_structure(current))
        if commands is None:
            # A page shaped by the OneNote apps: rebuilt once, with its images
            # uploaded from our own bytes, and surgical from then on.
            commands, uploads = upload_everything(payload.get("body", ""))
        parts = uploads.parts

    if commands:
        status, res = patch_page(url, commands, parts)
        if status not in (200, 204):
            try:
                fail(graph_err(json.loads(res), status))
            except ValueError:
                fail("Graph error %s" % status)
        if uploads.staged:
            # One extra read so the next autosave knows these pastes are
            # already on the page and does not upload them again.
            status, current = graph_raw("GET", url + "?includeIDs=true")
            if status == 200:
                remember_staged(uploads.staged, onenote_md.page_structure(current))

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
    # A brand-new page has no images of its own to keep, so everything the
    # note shows goes up as bytes — never as a reference OneNote would copy.
    uploads = Uploads(upload_known=True)
    runs = onenote_md.markdown_to_runs(payload.get("body", ""), uploads.ref)
    if uploads.error:
        fail(uploads.error)
    html = "<!DOCTYPE html><html><head><title>%s</title></head><body>%s</body></html>" % (title, wrap_runs(runs))
    if uploads.parts:
        # A page created with an image is a multipart POST: the HTML is the
        # "Presentation" part and each image is one of its own.
        boundary = "NoteNotePart" + uuid.uuid4().hex
        body = [("--%s\r\nContent-Disposition: form-data; name=\"Presentation\"\r\n"
                 "Content-Type: text/html\r\n\r\n%s\r\n" % (boundary, html)).encode()]
        for name, mime, data in uploads.parts:
            body.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n"
                         "Content-Type: %s\r\n\r\n" % (boundary, name, mime)).encode())
            body.append(data + b"\r\n")
        body.append(("--%s--\r\n" % boundary).encode())
        content_type, payload_bytes = "multipart/form-data; boundary=" + boundary, b"".join(body)
    else:
        content_type, payload_bytes = "application/xhtml+xml", html.encode()
    status, res = graph_raw("POST", "/me/onenote/sections/" + urllib.parse.quote(section_id, safe="") + "/pages",
                            payload_bytes, content_type)
    if status not in (200, 201):
        try:
            fail(graph_err(json.loads(res), status))
        except ValueError:
            fail("Graph error %s" % status)
    pg = json.loads(res)
    page = {"id": pg["id"], "title": pg.get("title", "") or "", "sectionId": section_id,
            "modified": pg.get("lastModifiedDateTime", "")}
    c = load_json(ONENOTE_CACHE, {"sections": [], "pages": []})
    # A new page goes to the end of its section, which is where OneNote itself
    # puts one and so where the next listing will show it. (It used to go to
    # the front, which was right while the list was newest-first.)
    kept = [p for p in c.get("pages", []) if p["id"] != page["id"]]
    last = max([i for i, p in enumerate(kept) if p.get("sectionId") == section_id],
               default=len(kept) - 1)
    kept.insert(last + 1, page)
    c["pages"] = kept
    save_private(ONENOTE_CACHE, c)
    out({"ok": True, "page": page})


def cmd_onenote_create_section(notebook_id, path):
    payload = read_payload(path) or {}
    name = (payload.get("name") or "").strip()
    if not name:
        fail("a section needs a name")
    status, res = graph("POST", "/me/onenote/notebooks/%s/sections" % urllib.parse.quote(notebook_id, safe=""),
                        {"displayName": name[:50]})
    if status not in (200, 201) or "id" not in res:
        fail(graph_err(res, status))
    section = {"id": res["id"], "name": res.get("displayName", name),
               "notebook": "", "notebookId": notebook_id}
    c = load_json(ONENOTE_CACHE, None)
    if c:
        for sct in c.get("sections", []):
            if sct.get("notebookId") == notebook_id:
                section["notebook"] = sct.get("notebook", "")
                break
        c["sections"] = c.get("sections", []) + [section]
        save_private(ONENOTE_CACHE, c)
    out({"ok": True, "section": section})


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
    elif cmd == "create-section" and len(argv) >= 4:
        cmd_onenote_create_section(argv[2], argv[3])
    elif cmd == "clear-cache":
        try:
            os.remove(ONENOTE_CACHE)
        except OSError:
            pass
        out({"ok": True})
    else:
        fail("usage: onenote.py list [--cached]|page <id>|update <id> <file>|create <sectionId> <file>|delete <id>|create-section <notebookId> <file>|clear-cache", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
