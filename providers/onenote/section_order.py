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
"""
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

import msgraph
import ratelimit
import toc

CACHE_VERSION = 1
MAX_FOLDERS = 64
MAX_CHILDREN = 1000
MAX_REQUESTS = 160
MAX_SECONDS = 180
MAX_CACHE_BYTES = 1024 * 1024
# HIGH-RISK WORKAROUND: observed personal-ID shape, not a documented mapping.
# Keep this restriction; do not infer support for other notebook ID formats.
ITEM_ID = re.compile(r"0-([0-9A-Fa-f]{16}![0-9]+)\Z")
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
        chunk = response.read1(min(65536, toc.MAX_BYTES + 1 - size))
        if time.monotonic() >= deadline:
            raise OrderUnavailable("section metadata download timed out")
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        if size > toc.MAX_BYTES:
            raise OrderUnavailable("section metadata exceeds its size limit")
        chunks.append(chunk)


class Remote:
    """Read-only, origin-checked transport with the provider's pacing/auth."""
    def __init__(self):
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

        return ratelimit.attempt_loop(msgraph.rate_key_for(url), msgraph.RATE_WINDOWS, once)

    def get(self, path):
        url = path if path.startswith("https://") else msgraph.GRAPH + path
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme != "https" or parsed.netloc != "graph.microsoft.com"
                or not parsed.path.startswith("/v1.0/me/drive/items/") or parsed.fragment):
            raise OrderUnavailable("untrusted OneDrive metadata endpoint")
        status, raw = self.request(url, msgraph.access_token())
        if status == 401:
            status, raw = self.request(url, msgraph.access_token(True))
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
        if not isinstance(item.get("size"), int) or not 0 <= item["size"] <= toc.MAX_BYTES:
            raise OrderUnavailable("invalid section metadata size")
        url = download_url(item.get("@microsoft.graph.downloadUrl", ""))
        status, raw = self.request(url)  # Signed URL; never send the Graph token.
        if status != 200:
            raise OrderUnavailable("section metadata download returned HTTP %d" % status)
        return raw


def item_path(item_id):
    return "/me/drive/items/" + urllib.parse.quote(item_id, safe="")


class Ordering:
    def __init__(self, remote, cached):
        self.remote = remote
        self.cached = cached if isinstance(cached, dict) and cached.get("version") == CACHE_VERSION else {}
        self.saved = {}
        self.notebooks = {}
        self.current_files = []
        self.visited = set()

    def children(self, item_id):
        url = item_path(item_id) + "/children?$select=id,name,size,file,folder,eTag&$top=200"
        found, visited = [], set()
        while url:
            if url in visited:
                raise OrderUnavailable("cyclic OneDrive metadata listing")
            visited.add(url)
            result = self.remote.get(url)
            values = result.get("value")
            if not isinstance(values, list) or len(found) + len(values) > MAX_CHILDREN:
                raise OrderUnavailable("too many notebook files")
            found.extend(values)
            url = result.get("@odata.nextLink")
        return found

    def entries(self, item):
        key, etag = item["id"], item.get("eTag")
        self.current_files.append(key)
        old = self.cached.get("files", {}).get(key, {})
        if etag and old.get("etag") == etag and isinstance(old.get("entries"), list):
            entries = old["entries"]
        else:
            metadata = self.remote.get(item_path(key))
            entries = toc.section_entries(self.remote.download(metadata))
            # The file may have changed since the children listing.
            etag = metadata.get("eTag")
        self.saved[key] = {"etag": etag, "entries": entries}
        if sum(len(value["entries"]) for value in self.saved.values()) > toc.MAX_ITEMS:
            del self.saved[key]
            raise OrderUnavailable("too many cached section-order entries")
        return entries

    def folder(self, item_id, depth=0):
        if item_id in self.visited or len(self.visited) >= MAX_FOLDERS or depth >= toc.MAX_DEPTH:
            raise OrderUnavailable("cyclic or excessive notebook hierarchy")
        self.visited.add(item_id)
        children = self.children(item_id)
        tables = [item for item in children if "file" in item and item.get("name", "").lower().endswith(".onetoc2")]
        if len(tables) != 1:
            raise OrderUnavailable("notebook folder has no unique .onetoc2 metadata")
        positions = {entry["name"].casefold(): entry["order"] for entry in self.entries(tables[0])}
        relevant = [item for item in children
                    if item.get("name", "").casefold() != "onenote_recyclebin"
                    and ("folder" in item or item.get("name", "").lower().endswith(".one"))]
        # Unknown/new files keep their API sequence after the known entries.
        # Deleted TOC records never introduce items: only live children join.
        relevant.sort(key=lambda item: positions.get(item.get("name", "").casefold(), float("inf")))
        ordered = []
        for item in relevant:
            if "folder" in item:
                ordered.extend(self.folder(item["id"], depth + 1))
            else:
                # The inverse of the same unguaranteed personal-ID mapping.
                ordered.append("0-" + item["id"])
        return ordered

    def notebook(self, notebook_id, name):
        match = ITEM_ID.fullmatch(notebook_id)
        if not match:
            raise OrderUnavailable("custom section order currently supports personal OneDrive notebooks")
        item = self.remote.get(item_path(match[1]) + "?$select=id,name,package")
        if item.get("name") != name or (item.get("package") or {}).get("type") != "oneNote":
            raise OrderUnavailable("notebook does not match its OneDrive package")
        return self.folder(match[1])


def arrange(sections, cached=None, remote=None):
    """Keep Graph IDs authoritative; change only section sequence, per book."""
    ordering = Ordering(remote or Remote(), cached)
    books = {}
    for section in sections:
        books.setdefault(section["notebookId"], []).append(section)
    ranks, warnings = {}, []
    for notebook_id, members in books.items():
        if len(members) == 1:
            continue  # A single section has no relative position to discover.
        ordering.current_files = []
        try:
            ids = ordering.notebook(notebook_id, members[0]["notebook"])
            ordering.notebooks[notebook_id] = {"ids": ids, "files": ordering.current_files}
        except (OrderUnavailable, toc.InvalidToc) as error:
            warnings.append("%s: %s" % (members[0]["notebook"] or "Notebook", error))
            previous = ordering.cached.get("notebooks", {}).get(notebook_id, {})
            ids = previous.get("ids", [])
            if previous:
                ordering.notebooks[notebook_id] = previous
                for key in previous.get("files", []):
                    if key in ordering.cached.get("files", {}):
                        ordering.saved[key] = ordering.cached["files"][key]
        ranks[notebook_id] = {key: index for index, key in enumerate(ids)}
        positions = ranks.get(notebook_id, {})
        members.sort(key=lambda section: positions.get(section["id"], float("inf")))
    # Preserve the original placement of notebooks within the account list.
    iterators = {key: iter(members) for key, members in books.items()}
    result = [next(iterators[section["notebookId"]]) for section in sections]
    live_files = {key for book in ordering.notebooks.values() for key in book["files"]}
    files = {key: value for key, value in ordering.saved.items() if key in live_files}
    saved = {"version": CACHE_VERSION, "files": files, "notebooks": ordering.notebooks}
    if len(json.dumps(saved).encode()) > MAX_CACHE_BYTES:
        # Ordering is still valid; decline to persist an oversized optimization.
        saved = {"version": CACHE_VERSION, "files": {}, "notebooks": {}}
    return result, saved, warnings
