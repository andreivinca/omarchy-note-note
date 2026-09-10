#!/usr/bin/env python3
"""OneNote provider (Notes.ReadWrite; Files.Read is optional for section order).

  onenote.py list [--cached|--max-age S|--force] -> {"sections":[{id,name,notebook,notebookId,modified}],
                                           "pages":[{id,sectionId,title,modified}]}
                                           --cached: cache only; --max-age S: cache if younger than S seconds;
                                           --force: fetch every section, ignoring the per-section timestamps
  onenote.py page <id> [--check]        -> {"title","body"(markdown),"editable","view"}
  onenote.py update <id> <file>         -> reads {"title","body","view","resolution"?}
  onenote.py create <sectionId> <file>  -> {"ok":true,"page":{...}}
  onenote.py delete <id>
  onenote.py create-section <notebookId> <file|->  -> {"ok":true,"section":{...}}
"""
import html as _html
import contextlib
import json, os, re, sys, time, urllib.parse, urllib.request, urllib.error, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "services", "microsoft"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
sys.path.insert(0, HERE)
import msgraph  # noqa: E402
import ratelimit  # noqa: E402
from msgraph import (graph, http, fail, fail_throttled, out, load_json, save_private,  # noqa: E402
                     read_payload, access_token, TRANSIENT_STATUSES, CACHE_DIR, GRAPH)
import onenote_md  # noqa: E402
import onenote_patch  # noqa: E402
from notemerge import MergeStore, StaleRemote, snapshot  # noqa: E402

# OneNote's own Graph budget, shared with no other provider: a throttle here
# parks OneNote and leaves Sticky Notes listing. Microsoft's delegated OneNote
# limits are 120 requests/minute *and* 400/hour per app+user (and 5 concurrent,
# which lib/ratelimit.py caps at 4); these windows stay under both with room
# for the other things the account may be doing.
msgraph.RATE_KEY = "graph-onenote"
msgraph.RATE_WINDOWS = [(60, 100), (3600, 350)]
# Keep optional consent out of the required refresh scopes, including when
# an older, still-loaded UI supplies the previous combined scope list.
msgraph.SCOPES = " ".join(scope for scope in msgraph.SCOPES.split() if scope != "Files.Read")
msgraph.OPTIONAL_SCOPES = "Files.Read"

ONENOTE_CACHE = os.path.join(CACHE_DIR, "note-note-onenote.json")
ONENOTE_IMG_DIR = os.path.join(CACHE_DIR, "note-note-onenote-img")
# This provider's limits: what it will read from Graph and keep around.
MAX_SECTIONS = 500
MAX_PAGES = 3000
MAX_LIST_BODY = 4 * 1024 * 1024   # one page of a listing
SECTION_ORDER_VERSION = 3       # invalidates listings ordered before repeated numbers and several TOCs were accepted
MAX_ORDER_CACHE = 1024 * 1024
MAX_PAGE_HTML = 4 * 1024 * 1024   # a page's content
MAX_IMAGE = 20 * 1024 * 1024      # one cached image
# What may go *up*. Graph rejects a request over 4 MB, and counts every part
# against it, so a save carries a few images at most and says so when it
# cannot: refusing is the only alternative to dropping someone's picture.
MAX_UPLOAD = 3 * 1024 * 1024      # one pasted image
MAX_UPLOAD_TOTAL = 3.5 * 1024 * 1024
MAX_NEW_IMAGES = 4


# ---------------------------------------------------------------- OneNote



def graph_raw(method, path, data=None, content_type=None, extra_headers=None,
              max_bytes=MAX_PAGE_HTML, retry_policy=None):
    """Graph call with a non-JSON body (OneNote HTML) and a text response.

    Paced and retried by the same loop as `msgraph.http()`, and classifying
    statuses out of the same two names — this used to be a second copy of it,
    and the two drifted.

    The shared transport owns the retry policy. Reads can replay, replacements
    restart the job with a fresh merge, and uncertain inserts/uploads stop.
    """
    url = path if path.startswith("http") else GRAPH + path

    def send(force):
        headers = {"Authorization": "Bearer " + access_token(force)}
        if content_type:
            headers["Content-Type"] = content_type
        headers.update(extra_headers or {})
        status, raw = msgraph.request(method, url, data, headers, max_bytes=max_bytes,
                                       timeout=60, retry_policy=retry_policy)
        return status, raw.decode(errors="replace")

    status, body = send(False)
    if status == 401:
        # As in `msgraph.graph()`: a 401 on a token the disk still calls valid
        # is a grant revoked at Microsoft's end, and only a forced refresh can
        # tell that apart from a token that simply needed renewing.
        status, body = send(True)
    return status, body


def graph_err(res, status):
    err = res.get("error") if isinstance(res, dict) else None
    if isinstance(err, dict):
        # Never pass an empty message through: the autosave retries on the
        # status code in the text, and "" retries nothing and explains nothing.
        return err.get("message") or "Graph error %s" % status
    return str(err or res or "") or "Graph error %s" % status


# A cold listing is one request per section, so it is also the thing most
# likely to be cut short by a throttle. Sections are written into the cache as
# they arrive, at most this often — a bounded number of writes, and a run that
# stops half way still leaves everything it fetched behind.
CHECKPOINT_SECONDS = 1.5


def section_pages_url(section_id):
    """The pages of one section, in the order the OneNote app shows them.

    `$orderby=order` is the order the user set by dragging page tabs, and the
    sidebar's job is to show a section the way its owner arranged it, not the
    way it was last touched. Graph sorts by `order` but does not return it: it
    is absent from the page resource in v1.0 and in beta, and asking for it in
    `$select` gives null. So the sequence Graph answers in *is* the order, and
    it is kept from here to the sidebar — `pages` stays a list, never a set,
    and the provider walks it as given (Provider.qml, rebuild). Nothing here
    can re-sort it, because there is no key left to sort by.
    """
    return ("/me/onenote/sections/%s/pages?$select=id,title,lastModifiedDateTime&$orderby=order&$top=100"
            % urllib.parse.quote(section_id, safe=""))


def has_section_order_scope():
    """Inspect existing consent without refreshing or changing the sign-in."""
    try:
        token = msgraph.signed_in(msgraph.config()[0]) or {}
        return "Files.Read" in token.get("scope", "").split()
    except Exception:
        return False


def alphabetical_sections(sections):
    """Sort within each notebook, preserving notebook slots and all Graph data."""
    books = {}
    for section in sections:
        books.setdefault(section["notebookId"], []).append(section)
    ordered = {key: iter(sorted(members, key=lambda section:
                               (section["name"].casefold(), section["name"], section["id"])))
               for key, members in books.items()}
    return [next(ordered[section["notebookId"]]) for section in sections]


def ordered_sections(sections, cache, token):
    """Optional-workaround boundary; normal note access never depends on it."""
    fallback = alphabetical_sections(sections)
    warning = ["Custom section order unavailable; sections sorted alphabetically"]
    if not sections:
        return fallback, {}, []
    if not has_section_order_scope():
        return fallback, {}, warning
    try:
        # HIGH-RISK WORKAROUND: keep even imports inside the failure boundary.
        # A parser/module failure must not affect page reads, edits or listing.
        # Optional code cannot emit a second JSON reply or leak an exception
        # payload through a helper that prints before raising SystemExit.
        with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink):
            import section_order
            result, saved, warnings = section_order.arrange(
                [dict(section) for section in sections], cache, section_order.Remote(token))
        # Only a permutation is accepted. Never let optional code supply new
        # sections or modify the fields returned by the authoritative Graph API.
        originals = {section["id"]: section for section in sections}
        if (len(result) != len(sections) or {section["id"] for section in result} != set(originals)
                or any(section != originals[section["id"]] for section in result)
                or not isinstance(saved, dict) or len(json.dumps(saved).encode()) > MAX_ORDER_CACHE
                or not isinstance(warnings, list) or not all(isinstance(value, str) for value in warnings)):
            return fallback, {}, warning
        return [originals[section["id"]] for section in result], saved, warnings
    except (Exception, SystemExit):
        # Never include exception text here: it could contain a signed URL.
        # KeyboardInterrupt still cancels the command rather than continuing.
        return fallback, {}, warning


class Listing:
    """The listing cache, and what a re-listing may skip.

    Two things are folded in here, and both exist to spend fewer requests on
    an account that has not changed (section-order metadata is checked too):

    **Continue, never restart.** Each section's pages are written into the
    cache as its request comes back, with the section's own
    `lastModifiedDateTime` beside them. A listing cut short by a throttle
    keeps everything it fetched, and the next run picks up the tail.

    **Diff by timestamp.** The single request that lists all sections already
    says when each was last modified, so a re-listing fetches pages only for
    the sections whose stamp moved (and ones it has never seen). A quiet
    account skips page requests entirely. `--force` — the
    Refresh row — ignores the stamps and fetches everything.
    """

    def __init__(self, cache, sections):
        self.sections = sections
        self.section_orders = cache.get("sectionOrders", {})
        self.order_warnings = cache.get("sectionOrderWarnings", [])
        self.order_scope = has_section_order_scope()
        self.by_section = {}
        for pg in (cache.get("pages") or []):
            self.by_section.setdefault(pg.get("sectionId", ""), []).append(pg)
        seen = cache.get("sectionPages")
        self.seen = dict(seen) if isinstance(seen, dict) else {}
        # `fetched` means "the whole account was listed", which is what
        # --max-age is measured against; a partial save must not start it.
        self.fetched = cache.get("fetched", 0) if isinstance(cache.get("fetched"), (int, float)) else 0
        self.last_write = 0.0

    def stale(self, sct, force):
        if force:
            return True
        was = self.seen.get(sct["id"])
        # A section we have never finished has no entry at all, which is how
        # an interrupted run knows its own tail.
        return not isinstance(was, dict) or was.get("modified") != sct.get("modified", "")

    def record(self, sct, pages):
        self.by_section[sct["id"]] = pages
        self.seen[sct["id"]] = {"modified": sct.get("modified", ""), "at": time.time()}

    def pages(self):
        found = []
        for sct in self.sections:
            found.extend(self.by_section.get(sct["id"], []))
        return found[:MAX_PAGES]

    def save(self, complete):
        live = set(sct["id"] for sct in self.sections)
        self.seen = dict((k, v) for k, v in self.seen.items() if k in live)
        if complete:
            self.fetched = time.time()
        os.makedirs(CACHE_DIR, exist_ok=True)
        save_private(ONENOTE_CACHE, {"sections": self.sections, "pages": self.pages(),
                                     "sectionPages": self.seen, "fetched": self.fetched,
                                     "sectionOrders": self.section_orders,
                                     "sectionOrderVersion": SECTION_ORDER_VERSION,
                                     "sectionOrderScope": self.order_scope,
                                     "sectionOrderWarnings": self.order_warnings})
        self.last_write = time.monotonic()

    def checkpoint(self):
        if time.monotonic() - self.last_write >= CHECKPOINT_SECONDS:
            self.save(False)


def cmd_onenote_list(cached, max_age=0, force=False):
    c = load_json(ONENOTE_CACHE, None)
    order_scope = has_section_order_scope()
    current_order = (isinstance(c, dict) and c.get("sectionOrderVersion") == SECTION_ORDER_VERSION
                     and c.get("sectionOrderScope") == order_scope)
    if cached or (max_age and c and current_order
                  and time.time() - c.get("fetched", 0) < max_age):
        c = c or {"sections": [], "pages": []}
        sections = c.get("sections", [])
        warnings = c.get("sectionOrderWarnings", [])
        if not current_order or not order_scope:
            sections = alphabetical_sections(sections)
            warnings = ["Custom section order unavailable; sections sorted alphabetically"] if sections else []
        out({"sections": sections, "pages": c.get("pages", []), "cached": True,
             "sectionOrderWarnings": warnings})
        return
    sections = []
    url = ("/me/onenote/sections?$select=id,displayName,lastModifiedDateTime,parentNotebook"
           "&$expand=parentNotebook($select=id,displayName)&$top=100")
    while url and len(sections) < MAX_SECTIONS:
        status, res = graph("GET", url, max_bytes=MAX_LIST_BODY)
        if status != 200:
            fail(graph_err(res, status))
        for sct in res.get("value", []):
            sections.append({"id": sct["id"], "name": sct.get("displayName", ""),
                             "notebook": (sct.get("parentNotebook") or {}).get("displayName", ""),
                             "notebookId": (sct.get("parentNotebook") or {}).get("id", ""),
                             "modified": sct.get("lastModifiedDateTime", "")})
        url = res.get("@odata.nextLink")
    sections = sections[:MAX_SECTIONS]
    cache = c if isinstance(c, dict) else {}
    # This token has already worked for normal notes. Optional metadata uses
    # the snapshot as-is; it cannot refresh or invalidate the account.
    token = access_token()
    sections, orders, warnings = ordered_sections(sections, cache.get("sectionOrders"), token)
    listing = Listing(cache, sections)
    listing.section_orders = orders
    listing.order_warnings = warnings
    todo = [sct for sct in sections if listing.stale(sct, force)]

    # Pages are listed per section: the account-wide /me/onenote/pages call
    # refuses accounts with many sections (docs/engine-notes.md). Each call
    # takes a couple of seconds, so the stale ones are fetched in parallel —
    # the pacer holds the total to four requests in flight.
    from concurrent.futures import ThreadPoolExecutor, as_completed

    # All workers use the already-validated token snapshot. Optional ordering
    # cannot change it or impose a cooldown on this normal OneNote lane.
    def section_pages(sct):
        found = []
        url = section_pages_url(sct["id"])
        while url and len(found) < MAX_PAGES:
            # A worker must not answer for the whole run: `fail()` writes the
            # one JSON line and exits, and doing that from inside the pool
            # would step over the other three threads' stdout *and* jump the
            # `listing.save(False)` below, throwing away every section already
            # fetched. So the classification is carried back instead.
            status, res = http("GET", url if url.startswith("http") else GRAPH + url, headers={
                "Authorization": "Bearer " + token, "Accept": "application/json"},
                max_bytes=MAX_LIST_BODY, retry_policy=msgraph.RetryPolicy.NEVER)
            if status != 200:
                return {"error": graph_err(res, status),
                        "kind": "transient" if status in TRANSIENT_STATUSES else None}
            for pg in res.get("value", []):
                found.append({"id": pg["id"], "title": pg.get("title", "") or "",
                              "sectionId": sct["id"], "modified": pg.get("lastModifiedDateTime", "")})
            url = res.get("@odata.nextLink")
        return found

    if todo:
        error, error_kind = "", None
        try:
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = dict((pool.submit(section_pages, sct), sct) for sct in todo)
                for future in as_completed(futures):
                    result = future.result()
                    if isinstance(result, dict):
                        error, error_kind = result["error"], result.get("kind")
                        break
                    listing.record(futures[future], result)
                    listing.checkpoint()
        except ratelimit.Throttled:
            # Keep what did arrive: the sections stored here are skipped by
            # their own stamp next time, so the run after the cooldown fetches
            # only the tail instead of spending the budget again from scratch.
            listing.save(False)
            raise
        if error:
            # Whatever went wrong, what did arrive is kept first — the same
            # bargain the `Throttled` path above makes, and the reason a run
            # after a failure fetches only the tail.
            listing.save(False)
            fail(error, kind=error_kind)

    listing.save(True)
    out({"sections": sections, "pages": listing.pages(), "cached": False,
         "sectionOrderWarnings": listing.order_warnings})


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
    # An editor can still reference a staged paste while the next save reads
    # the page. Keep its resource alias so that read cannot cause a re-upload.
    staged = {path: entry for path, entry in index.get("staged", {}).items() if os.path.isfile(path)}
    staged = dict(list(staged.items())[-128:])
    save_private(IMAGE_INDEX, {"files": files, "pages": pages, "staged": staged})


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


def remember_staged(staged, html):
    """Match upload aliases by the data-id written with each image.

    Patch order and document order can differ. Only an exact, unique marker
    can associate a local paste with its acknowledged OneNote resource.
    """
    index = load_json(IMAGE_INDEX, {})
    images = {}
    for node in onenote_patch.walk(onenote_patch.parse(html)):
        if node.tag == "img" and node.attrs.get("data-id"):
            images.setdefault(node.attrs["data-id"], []).append(node.attrs.get("src", ""))
    files, pastes = index.get("files", {}), index.get("staged", {})
    for upload in staged.values():
        sources = images.get(upload["dataId"], [])
        if len(sources) != 1 or not image_allowed(sources[0]):
            continue
        path, width, src = upload["path"], upload["width"], sources[0]
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
    # No revoked-grant pass of its own, for the reason the listing pool has
    # none: the only caller is `cmd_onenote_page`, whose `graph_raw` fetch of
    # the page content has already met any 401 and forced the refresh.
    req = urllib.request.Request(src, headers={"Authorization": "Bearer " + access_token()})
    fd, tmp = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=ONENOTE_IMG_DIR)   # fresh, 0600, never a symlink
    pause = 0.0        # a throttle met here, recorded once the slot is released
    try:
        deadline = _image_budget[0] or (time.monotonic() + IMAGE_BUDGET_SECONDS)
        # An image is a Graph request like any other and is paced like one:
        # forty of them is what a picture-heavy page costs, and that is most
        # of a minute's budget on its own.
        with os.fdopen(fd, "wb") as f:
            with ratelimit.slot(msgraph.RATE_KEY, msgraph.RATE_WINDOWS):
                with _image_opener.open(req, timeout=20) as r:
                    data = read_with_deadline(r, MAX_IMAGE, deadline)
                    if not data:
                        # Graph serves a just-written resource as 200 with an
                        # empty body; caching that would poison the page for good.
                        raise OverflowError("empty image response")
                    f.write(data)
        _image_budget[1] += 1
        os.replace(tmp, path)
        prune_image_cache()
        return "file://" + path
    except ratelimit.Throttled:
        pass                       # the pacer already knows; nothing to record
    except urllib.error.HTTPError as e:
        if e.code in (429, 503):
            pause = msgraph.wait_asked_by(e)
    except (urllib.error.URLError, OSError, OverflowError):
        pass
    try:
        os.remove(tmp)
    except OSError:
        pass
    if pause:
        # The rest of this page's images would earn the same answer, and so
        # would the next process: record it once and let them all fail fast.
        # The page still loads — it shows the alt text — and the incomplete
        # image list keeps a save from writing it back (remember_images).
        ratelimit.report_throttle(msgraph.RATE_KEY, pause)
    return None


def cmd_onenote_pages(section_ids):
    """Pages of a few sections (one request each) — for cheap refreshes."""
    found = []
    for sid in section_ids[:10]:
        url = section_pages_url(sid)
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


def normalize_note(note):
    """Comparable Markdown, including aliases for pictures already uploaded."""
    def image_ref(url, alt):
        known = known_image(url)
        if known and known.get("src"):
            import hashlib
            name = hashlib.sha1(known["src"].encode()).hexdigest()
            cached = os.path.join(ONENOTE_IMG_DIR, name)
            if os.path.isfile(cached):
                return "file://" + cached, 0
        return url, 0

    html = onenote_md.markdown_to_onenote_html(note["body"], image_ref)
    body = onenote_md.html_to_markdown("<body>" + html + "</body>", lambda src, width: src)["body"]
    return {"title": note["title"].strip(), "body": body}


def merge_account():
    # Stable Graph identity, never an email/display name or a rotating token.
    token = msgraph.signed_in(msgraph.config()[0])
    if not token:
        fail("not signed in")
    account = token.get("userId")
    if not account:
        status, profile = graph("GET", "/me?$select=id")
        if status != 200 or not profile.get("id"):
            fail("could not identify the account for note recovery")
        account = profile["id"]
        token = load_json(msgraph.TOKENS, {})
        token["userId"] = account
        save_private(msgraph.TOKENS, token)
    return msgraph.config()[0] + ":" + account


def merge_store(page_id):
    return MergeStore(os.path.join(msgraph.STATE_DIR, "note-note-merges"),
                      "onenote", merge_account(), page_id,
                      normalize=normalize_note, stale_seconds=120)


def read_page(page_id):
    _image_budget[0] = time.monotonic() + IMAGE_BUDGET_SECONDS
    _image_budget[1] = 0
    url = "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content?includeIDs=true"
    status, html = graph_raw("GET", url)
    if status != 200:
        try:
            fail(graph_err(json.loads(html), status))
        except ValueError:
            fail("Graph error %s" % status)
    result = onenote_md.html_to_markdown(html, cached_image)
    remember_images(page_id, result["images"], result["editable"])
    return result, html


def cmd_onenote_page(page_id, check=False):
    with merge_store(page_id) as journal:
        # Recovery does not depend on the account's page service being online.
        if not check:
            recovered = journal.recover()
            if recovered is not None:
                out(dict(recovered, editable=True, markdown=True))
                return
        remote, html = read_page(page_id)
        if check:
            journal.check_remote(remote)
        result = normalize_note(remote) if check else journal.open(remote)
        out(dict(result, editable=remote["editable"], markdown=True))


MIME_BY_SUFFIX = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                  ".gif": "image/gif", ".bmp": "image/bmp", ".tif": "image/tiff", ".tiff": "image/tiff"}


class Uploads:
    """The images a save has to carry, and the rules about how many.

    Existing images use their resource identity during planning. Only images
    mentioned by a command are materialized as upload parts. Graph's 4 MB
    limit includes those bytes, so both the count and total size are bounded.
    """

    def __init__(self, upload_known=False):
        self.parts = []          # [(part name, mime, bytes)]
        self.staged = {}         # part name -> local file and durable data-id
        self.bytes = 0
        self.error = ""
        self.image_paths = {}
        # A new page owns no existing resources; creation uploads every image.
        self.upload_known = upload_known

    def ref(self, url, alt):
        """(src for the <img>, width) — the resolver onenote_md renders with."""
        known = known_image(url)
        if known and not self.upload_known:
            self.image_paths[known.get("src", "")] = url
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
        self.staged[name] = {"path": path, "width": width, "dataId": "nn-upload-" + uuid.uuid4().hex}
        self.bytes += len(data)
        self.image_paths["name:" + name] = "file://" + path
        return "name:" + name, width

    def materialize(self, commands):
        """Only changed images appear in a plan; send their bytes, not URLs.

        An unchanged resource is never copied just because neighbouring text
        changed. The planner leaves that image out of the commands entirely.
        """
        return [dict(command, content=self.render_uploads(command["content"])) for command in commands]

    def render_uploads(self, source):
        """Materialize images and label upload parts in a presentation fragment."""
        content = onenote_patch.parse(source)
        for node in onenote_patch.walk(content):
            if node.tag != "img":
                continue
            source = node.attrs.get("src", "")
            local = self.image_paths.get(source)
            if local and not source.startswith("name:"):
                path = file_path_of(local)
                mime = MIME_BY_SUFFIX.get(os.path.splitext(path)[1].lower(), "image/png")
                width = int(float(node.attrs.get("width", "0") or 0))
                node.attrs["src"] = self.part(path, mime, width)[0]
            if node.attrs.get("src", "").startswith("name:"):
                upload = self.staged.get(node.attrs["src"][5:])
                if upload:
                    node.attrs["data-id"] = upload["dataId"]
        return onenote_patch.serialize(content)


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
    # An uncertain insert or upload must not be repeated: the first request
    # may already have added the item. Replacements can retry through a new
    # fetch and merge; they never append another copy to the same anchor.
    if parts:
        content_type, body = multipart(commands, parts)
    else:
        content_type, body = "application/json", json.dumps(commands).encode()
    repeatable = not parts and all(command["action"] == "replace" for command in commands)
    policy = msgraph.RetryPolicy.RESTART if repeatable else msgraph.RetryPolicy.NEVER
    return graph_raw("PATCH", url, body, content_type, retry_policy=policy)


def wrap_runs(runs):
    """Group text for a new page, with images beside the text containers."""
    out = []
    for run in runs:
        if run["kind"] == "image":
            out.append(run["html"])
        else:
            out.append("<div>%s</div>" % run["html"])
    return "".join(out) or "<div><p></p></div>"




def write_page(page_id, note, remote, current):
    """Write a merge planned against the exact HTML fetched by this save."""
    url = "/me/onenote/pages/" + urllib.parse.quote(page_id, safe="") + "/content"
    if note["body"] != normalize_note(remote)["body"]:
        uploads = Uploads()
        runs = onenote_md.markdown_to_runs(note["body"], uploads.ref)
        if uploads.error:
            fail(uploads.error)
        try:
            planned = onenote_patch.plan(current, "".join(run["html"] for run in runs))
        except (onenote_patch.UnsupportedEdit, onenote_patch.InvalidPlan) as error:
            fail(str(error) + " — your draft was kept")
        image_paths = {item["src"]: item.get("local") for item in remote.get("images", [])}
        image_paths.update(uploads.image_paths)
        simulated_note = onenote_md.html_to_markdown(planned.simulated, lambda src, width: image_paths.get(src))
        if not simulated_note["editable"] or normalize_note(simulated_note)["body"] != note["body"]:
            fail("the proposed update could not preserve this page's content — your draft was kept")
        commands = uploads.materialize(planned.commands)
        if uploads.error:
            fail(uploads.error)
        if commands:
            status, res = patch_page(url, commands, uploads.parts)
            if status not in (200, 204):
                try:
                    fail(graph_err(json.loads(res), status))
                except ValueError:
                    fail("Graph error %s" % status)
            if uploads.staged:
                status, content = graph_raw("GET", url + "?includeIDs=true")
                if status == 200:
                    remember_staged(uploads.staged, content)

    # Some older pages reject title writes. Record the successful body and
    # retain the title's draft if that happens, so a retry has the right base.
    warning = ""
    if note["title"] != remote["title"]:
        ops = [{"target": "title", "action": "replace", "content": _html.escape(note["title"])}]
        status, res = graph_raw("PATCH", url, json.dumps(ops).encode(), "application/json",
                                retry_policy=msgraph.RetryPolicy.NEVER)
        if status not in (200, 204):
            try:
                warning = "title not saved: " + graph_err(json.loads(res), status)
            except ValueError:
                warning = "title not saved (Graph error %s)" % status
    return warning


def cmd_onenote_update(page_id, path):
    payload = read_payload(path)
    if not isinstance(payload, dict):
        fail("cannot read payload")
    with merge_store(page_id) as journal:
        journal.stage(payload.get("view", ""), payload)
        remote, current = read_page(page_id)
        if not remote["editable"]:
            fail("this page now contains content that cannot be saved safely — your draft was kept")
        merged = journal.prepare(remote, payload.get("resolution"))
        if merged["conflict"]:
            out({"error": "This note changed elsewhere. Review the conflicting changes.",
                 "conflict": merged["conflict"]})
            return
        note = merged["note"]
        if normalize_note(note) != note:
            fail("the merged formatting needs review before saving — your draft was kept")
        warning = write_page(page_id, note, remote, current)
        if warning:
            journal.commit(dict(note, title=remote["title"]), accepted_fields=("body",))
            out({"error": warning})
            return
        saved = journal.commit(note)
        out(dict(saved, ok=True, merged=normalize_note(payload) != snapshot(saved)))


def cmd_onenote_create(section_id, path):
    # Resolve the recovery identity before making a page. A failed profile
    # read must not leave a newly created page behind an apparent failure.
    merge_account()
    payload = read_payload(path) or {}
    title = _html.escape(payload.get("title", "") or "")
    # A brand-new page has no images of its own to keep, so everything the
    # note shows goes up as bytes — never as a reference OneNote would copy.
    uploads = Uploads(upload_known=True)
    runs = onenote_md.markdown_to_runs(payload.get("body", ""), uploads.ref)
    if uploads.error:
        fail(uploads.error)
    html = "<!DOCTYPE html><html><head><title>%s</title></head><body>%s</body></html>" % (title, uploads.render_uploads(wrap_runs(runs)))
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
    # A 502 or a 504 is the gateway losing the answer to a page Graph may
    # already have made; re-running would leave the user with two or three.
    status, res = graph_raw("POST", "/me/onenote/sections/" + urllib.parse.quote(section_id, safe="") + "/pages",
                            payload_bytes, content_type, retry_policy=msgraph.RetryPolicy.NEVER)
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
    with merge_store(page["id"]) as journal:
        note = journal.open({"title": page["title"], "body": payload.get("body", "")})
    out({"ok": True, "page": page, "note": note})


def cmd_onenote_create_section(notebook_id, path):
    payload = read_payload(path) or {}
    name = (payload.get("name") or "").strip()
    if not name:
        fail("a section needs a name")
    # Not repeatable either, for the same reason a page create is not.
    status, res = graph("POST", "/me/onenote/notebooks/%s/sections" % urllib.parse.quote(notebook_id, safe=""),
                        {"displayName": name[:50]}, retry_policy=msgraph.RetryPolicy.NEVER)
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
    with merge_store(page_id) as journal:
        status, res = graph_raw("DELETE", "/me/onenote/pages/" + urllib.parse.quote(page_id, safe=""))
        if status not in (204, 200, 404):
            try:
                fail(graph_err(json.loads(res), status))
            except ValueError:
                fail("Graph error %s" % status)
        c = load_json(ONENOTE_CACHE, {"sections": [], "pages": []})
        c["pages"] = [p for p in c.get("pages", []) if p["id"] != page_id]
        save_private(ONENOTE_CACHE, c)
        journal.discard()
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
        cmd_onenote_list("--cached" in argv[2:], age, "--force" in argv[2:])
    elif cmd == "pages" and len(argv) >= 3:
        cmd_onenote_pages(argv[2:])
    elif cmd == "page" and len(argv) >= 3:
        cmd_onenote_page(argv[2], "--check" in argv[3:])
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
        fail("usage: onenote.py list [--cached|--max-age S|--force]|page <id>|update <id> <file>|create <sectionId> <file>|delete <id>|create-section <notebookId> <file>|clear-cache", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except StaleRemote:
        fail("OneNote is still syncing the previous save — try again shortly", kind="transient")
    except ratelimit.Throttled as t:
        fail_throttled(t)
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
