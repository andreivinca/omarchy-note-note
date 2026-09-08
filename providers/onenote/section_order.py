"""Join OneNote's remote TOC order to live OneDrive/Graph section IDs.

HIGH-RISK WORKAROUND: this is not a supported Graph section-order API.
It depends on OneDrive exposing .onetoc2 metadata, a custom partial binary
reader, and a personal Graph/OneDrive ID mapping verified on a live account
but not guaranteed by an API contract. Microsoft-side changes can break or
invalidate the resulting order without any code change here. Bounds and
tests reduce implementation risk; they do not guarantee compatibility.
This path is read-only. Replace it when a supported ordering API is available.
See docs/onenote-section-order.md for assumptions, evidence and limitations.

For verified personal notebooks, IDs identify OneDrive package items. Groups are
folders within that package, each with its own TOC. The UI is flat, so walk
groups in their remote position and keep their sections together. No manual
positions, note contents, signed URLs or raw TOC files are stored locally.

A folder may hold more than one TOC: an old desktop client leaves a localized
"Open Notebook.onetoc2" beside the ".onetoc2" current clients write, and only
the newest is maintained. Order numbers may repeat or skip; equal numbers keep
the order the TOC lists them in, since OneNote's own tie-break is undocumented.
"""
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

import msgraph
import ratelimit

CACHE_VERSION = 2
MAX_BODY = 512 * 1024
MAX_ITEMS = 8192
MAX_DEPTH = 32
MAX_FOLDERS = 64
MAX_CHILDREN = 1000
MAX_REQUESTS = 160
MAX_SECONDS = 45
MAX_CACHE_BYTES = 1024 * 1024
# OneDrive metadata failures must not park the normal OneNote request lane.
RATE_KEY = "graph-onenote-section-order"
RATE_WINDOWS = [(60, 30), (3600, 180)]
# HIGH-RISK WORKAROUND: observed personal-ID shape, not a documented mapping.
# Keep this restriction; do not infer support for other notebook ID formats.
ITEM_ID = re.compile(r"0-([0-9A-Fa-f]{16}![0-9]+)\Z")
# Graph's UTC stamps: fixed width up to the second, then up to seven digits.
TIMESTAMP = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,7}))?Z\Z")
DOWNLOAD_HOSTS = (".files.1drv.com", ".storage.live.com", ".sharepoint.com",
                  ".microsoftpersonalcontent.com")


class OrderUnavailable(ValueError):
    """The remote custom order could not be established safely."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def download_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = (parsed.scheme == "https" and not parsed.username and not parsed.password
                 and parsed.port in (None, 443) and not parsed.fragment
                 and parsed.hostname and parsed.hostname.endswith(DOWNLOAD_HOSTS))
    except ValueError:
        valid = False
    if not valid:
        raise OrderUnavailable("untrusted OneDrive metadata download URL")
    return url


def read_response(response, deadline):
    chunks, size = [], 0
    # read1 returns after one socket read; read(n) could wait for n bytes
    # indefinitely when a peer drip-feeds data within each socket timeout.
    while True:
        if time.monotonic() >= deadline:
            raise OrderUnavailable("section metadata download timed out")
        chunk = response.read1(min(65536, MAX_BODY + 1 - size))
        if time.monotonic() >= deadline:
            raise OrderUnavailable("section metadata download timed out")
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        if size > MAX_BODY:
            raise OrderUnavailable("section metadata exceeds its size limit")
        chunks.append(chunk)


class Remote:
    """Optional transport: owns no sign-in and has a separate rate budget.

    The caller supplies a token already used for normal notes. A metadata
    401 must never refresh, forget or otherwise change that working sign-in.
    """
    def __init__(self, token):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)
        self.deadline = time.monotonic() + MAX_SECONDS
        self.requests = 0

    def request(self, url, token=None):
        self.requests += 1
        if self.requests > MAX_REQUESTS or time.monotonic() >= self.deadline:
            raise OrderUnavailable("section metadata request budget exceeded")
        headers = {"Authorization": "Bearer " + token} if token else {}
        request = urllib.request.Request(url, headers=headers, method="GET")

        def once():
            deadline = min(self.deadline, time.monotonic() + 30)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise OrderUnavailable("section metadata download timed out")
            try:
                with self.opener.open(request, timeout=min(10, remaining)) as response:
                    return response.status, read_response(response, deadline)
            except urllib.error.HTTPError as error:
                with error:
                    if error.code in msgraph.THROTTLED_STATUSES:
                        raise ratelimit.Retry(msgraph.wait_asked_by(error))
                    return error.code, b""
            except OSError as error:
                # A signed URL is a credential: exceptions must not expose it.
                raise OrderUnavailable("could not read OneDrive section metadata") from error

        key = RATE_KEY if url.startswith(msgraph.GRAPH_ORIGIN) else None
        return ratelimit.attempt_loop(key, RATE_WINDOWS, once, attempts=1)

    def get(self, path):
        url = path if path.startswith("https://") else msgraph.GRAPH + path
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme != "https" or parsed.netloc != "graph.microsoft.com"
                or not parsed.path.startswith("/v1.0/me/drive/items/") or parsed.fragment):
            raise OrderUnavailable("untrusted OneDrive metadata endpoint")
        status, raw = self.request(url, self.token)
        if status != 200:
            raise OrderUnavailable("OneDrive metadata returned HTTP %d" % status)
        try:
            value = json.loads(raw)
        except ValueError as error:
            raise OrderUnavailable("invalid OneDrive metadata response") from error
        if not isinstance(value, dict):
            raise OrderUnavailable("invalid OneDrive metadata response")
        return value

    def download(self, item):
        if type(item.get("size")) is not int or not 0 <= item["size"] <= MAX_BODY:
            raise OrderUnavailable("invalid section metadata size")
        url = download_url(item.get("@microsoft.graph.downloadUrl", ""))
        status, raw = self.request(url)  # Signed URL; never send the Graph token.
        if status != 200:
            raise OrderUnavailable("section metadata download returned HTTP %d" % status)
        return raw


def item_path(item_id):
    return "/me/drive/items/" + urllib.parse.quote(item_id, safe="")


def modified_at(item):
    """A sortable key for an item's Graph timestamp, whatever its fraction width."""
    match = TIMESTAMP.fullmatch(str(item.get("lastModifiedDateTime", "")))
    if not match:
        raise OrderUnavailable("invalid section metadata timestamp")
    return match[1], (match[2] or "").ljust(7, "0")


class Ordering:
    def __init__(self, remote, cached):
        self.remote = remote
        self.cached = cached if isinstance(cached, dict) and cached.get("version") == CACHE_VERSION else {}
        self.saved = {}
        self.current_files = []
        self.visited = set()
        self.section_names = {}

    def children(self, item_id):
        url = item_path(item_id) + "/children?$select=id,name,size,file,folder,eTag,lastModifiedDateTime&$top=200"
        found, visited = [], set()
        while url:
            if url in visited:
                raise OrderUnavailable("cyclic OneDrive metadata listing")
            visited.add(url)
            result = self.remote.get(url)
            values = result.get("value")
            if not isinstance(values, list) or len(found) + len(values) > MAX_CHILDREN:
                raise OrderUnavailable("too many notebook files")
            for item in values:
                if (not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"]
                        or not isinstance(item.get("name"), str) or not item["name"]):
                    raise OrderUnavailable("invalid notebook file metadata")
            found.extend(values)
            url = result.get("@odata.nextLink")
            if url is not None and (not isinstance(url, str) or not url):
                raise OrderUnavailable("invalid notebook pagination")
        return found

    def entries(self, item):
        key, etag = item["id"], item.get("eTag")
        self.current_files.append(key)
        old = self.cached.get("files", {}).get(key, {})
        if etag and old.get("etag") == etag and isinstance(old.get("entries"), list):
            entries = old["entries"]
        else:
            metadata = self.remote.get(item_path(key))
            # Import only inside the optional failure boundary. A broken or
            # missing parser must not prevent ordinary notes from loading.
            import toc
            entries = toc.section_entries(self.remote.download(metadata))
            # The file may have changed since the children listing.
            etag = metadata.get("eTag")
        if not isinstance(entries, list) or len(entries) > MAX_ITEMS:
            raise OrderUnavailable("invalid cached TOC entries")
        names = set()
        for entry in entries:
            if (not isinstance(entry, dict) or not isinstance(entry.get("name"), str) or not entry["name"]
                    or type(entry.get("order")) is not int or not 0 <= entry["order"] <= 0xFFFFFFFF
                    or entry["name"].casefold() in names):
                raise OrderUnavailable("invalid or ambiguous TOC entries")
            names.add(entry["name"].casefold())
        self.saved[key] = {"etag": etag, "entries": entries}
        if sum(len(value["entries"]) for value in self.saved.values()) > MAX_ITEMS:
            del self.saved[key]
            raise OrderUnavailable("too many cached section-order entries")
        return entries

    def table_of_contents(self, children):
        """The TOC file OneNote currently maintains for this folder.

        An old desktop client leaves a localized "Open Notebook.onetoc2"
        beside the ".onetoc2" that current clients write, and stops updating
        it. Live-verified: reordering in the web app rewrote only the newer
        file. The most recently modified one is therefore the notebook's.
        """
        tables = [item for item in children
                  if "file" in item and item.get("name", "").lower().endswith(".onetoc2")]
        if not tables:
            raise OrderUnavailable("notebook folder has no .onetoc2 metadata")
        if len(tables) == 1:
            return tables[0]
        stamps = [modified_at(item) for item in tables]
        newest = max(stamps)
        if stamps.count(newest) > 1:
            raise OrderUnavailable("notebook folder has no unique .onetoc2 metadata")
        return tables[stamps.index(newest)]

    def folder(self, item_id, depth=0):
        if item_id in self.visited or len(self.visited) >= MAX_FOLDERS or depth >= MAX_DEPTH:
            raise OrderUnavailable("cyclic or excessive notebook hierarchy")
        self.visited.add(item_id)
        children = self.children(item_id)
        # Order numbers may repeat and skip; the web client writes both. The
        # rank after a stable sort is the position, so equal numbers keep the
        # order the TOC lists them in.
        ranked = sorted(self.entries(self.table_of_contents(children)), key=lambda entry: entry["order"])
        positions = {entry["name"].casefold(): rank for rank, entry in enumerate(ranked)}
        relevant = [item for item in children
                    if item.get("name", "").casefold() != "onenote_recyclebin"
                    and ("folder" in item or item.get("name", "").lower().endswith(".one"))]
        # A live section the TOC never mentions has no position at all.
        # Deleted TOC records still never introduce sections into the listing.
        if any(item["name"].casefold() not in positions for item in relevant):
            raise OrderUnavailable("incomplete live section order")
        relevant.sort(key=lambda item: positions[item["name"].casefold()])
        ordered = []
        for item in relevant:
            if "folder" in item:
                ordered.extend(self.folder(item["id"], depth + 1))
            else:
                # The inverse of the same unguaranteed personal-ID mapping.
                section_id = "0-" + item["id"]
                if section_id in self.section_names:
                    raise OrderUnavailable("duplicate OneDrive section ID")
                self.section_names[section_id] = item["name"][:-4]
                ordered.append(section_id)
        return ordered

    def notebook(self, notebook_id, name):
        match = ITEM_ID.fullmatch(notebook_id)
        if not match:
            raise OrderUnavailable("custom section order currently supports personal OneDrive notebooks")
        item = self.remote.get(item_path(match[1]) + "?$select=id,name,package")
        if (item.get("id") != match[1] or item.get("name") != name
                or (item.get("package") or {}).get("type") != "oneNote"):
            raise OrderUnavailable("notebook does not match its OneDrive package")
        return self.folder(match[1])


def arrange(sections, cached=None, remote=None):
    """Use verified remote order per book; any failure sorts that book A–Z.

    The broad catch is intentional at this optional feature boundary. No
    exception text from an unexpected failure is exposed: it might contain
    a signed URL. Process cancellation (KeyboardInterrupt) still propagates.
    """
    ordering = Ordering(remote, cached)
    books = {}
    for section in sections:
        books.setdefault(section["notebookId"], []).append(section)
    warnings, live_files = [], set()
    for notebook_id, members in books.items():
        if len(members) == 1:
            continue  # A single section has no relative position to discover.
        ordering.current_files = []
        try:
            ids = ordering.notebook(notebook_id, members[0]["notebook"])
            positions = {key: index for index, key in enumerate(ids)}
            for section in members:
                if (section["id"] not in positions
                        or ordering.section_names[section["id"]].casefold() != section["name"].casefold()):
                    raise OrderUnavailable("Graph and OneDrive section identities no longer match")
            members.sort(key=lambda section: positions[section["id"]])
            live_files.update(ordering.current_files)
        except (Exception, SystemExit):
            warnings.append("%s: custom order unavailable; sections sorted alphabetically" %
                            (members[0]["notebook"] or "Notebook"))
            members.sort(key=lambda section: (section["name"].casefold(), section["name"], section["id"]))
            for key in ordering.current_files:
                ordering.saved.pop(key, None)
    # Preserve the original placement of notebooks within the account list.
    iterators = {key: iter(members) for key, members in books.items()}
    result = [next(iterators[section["notebookId"]]) for section in sections]
    files = {key: value for key, value in ordering.saved.items() if key in live_files}
    saved = {"version": CACHE_VERSION, "files": files}
    if len(json.dumps(saved).encode()) > MAX_CACHE_BYTES:
        # Ordering is still valid; decline to persist an oversized optimization.
        saved = {"version": CACHE_VERSION, "files": {}}
    return result, saved, warnings
