"""Synthetic TOC/OneDrive tests: no account, network or real notebook data."""
import io
import json
import struct
import unittest
import urllib.error
from unittest.mock import patch

import onenote  # noqa: F401 -- establishes the provider's shared library paths
import section_order as order
import toc


def compact(value):
    if value == 0:
        return b"\0"
    for width in range(1, 8):
        if value < 1 << (7 * width):
            return ((value << width) | (1 << (width - 1))).to_bytes(width, "little")
    return b"\x80" + value.to_bytes(8, "little")


def guid(value):
    return (value.to_bytes(16, "little"), 1)


def exguid(value):
    if value == toc.NIL:
        return b"\0"
    return b"\x80" + value[1].to_bytes(4, "little") + value[0]


def node(tag, data=b"", children=None):
    compound = 4 if children is not None else 0
    if tag < 64 and len(data) < 128:
        start = struct.pack("<H", (len(data) << 9) | (tag << 3) | compound)
    else:
        start = struct.pack("<I", (len(data) << 17) | (tag << 3) | compound | 2)
    end = b""
    if children is not None:
        end = bytes([(tag << 2) | 1]) if tag < 64 else struct.pack("<H", (tag << 2) | 3)
    return start + data + b"".join(children or []) + end


def prop_set(values, refs):
    ids, payloads = [], []
    for key, value in values.items():
        ids.append(struct.pack("<I", key))
        if key == toc.CHILDREN:
            payloads.append(struct.pack("<I", len(value)))
        elif key == toc.ORDER:
            payloads.append(struct.pack("<I", value))
        else:
            payloads.append(struct.pack("<I", len(value)) + value)
    return (struct.pack("<I", 0x80000000 | len(refs)) + bytes(4 * len(refs))
            + struct.pack("<H", len(values)) + b"".join(ids) + b"".join(payloads))


def fixture(names=("Food.one", "Welcome.one", "Health.one"), orders=(3, 1, 5),
            base=False, revision_cycle=False, object_cycle=False):
    """Build the actual packaged wire format, with optional revision inheritance."""
    index, manifest, cell, revision, group, root = [guid(i) for i in range(1, 7)]
    older, old_group = guid(7), guid(8)
    cell_id = guid(9), toc.NIL
    objects = [guid(20 + i) for i in range(len(names))]

    def element(key, kind, children):
        return node(1, exguid(key) + b"\0" + compact(kind), children)

    def object_group(key, values):
        declarations, data = [], []
        for object_id, properties, refs in values:
            for partition, payload, references in [(1, prop_set(properties, refs), refs), (4, struct.pack("<I", 0x20001), [])]:
                declarations.append(node(0x18, exguid(object_id) + compact(partition)
                                         + compact(len(payload)) + compact(len(references)) + b"\0"))
                data.append(node(0x16, compact(len(references)) + b"".join(exguid(ref) for ref in references)
                                 + b"\0" + compact(len(payload)) + payload))
        return element(key, 5, [node(0x1D, children=declarations), node(0x1E, children=data)])

    leaves = [(key, {toc.FILENAME: name.encode("utf-16-le"), toc.ORDER: position,
                     toc.IDENTITY: key[0]}, []) for key, name, position in zip(objects, names, orders)]
    root_refs = [root] if object_cycle else objects
    values = [(root, {toc.CHILDREN: root_refs}, root_refs)]
    index_children = [node(0x11, exguid(manifest) + b"\0"),
                      node(0x0E, exguid(cell_id[0]) + exguid(cell_id[1]) + exguid(cell) + b"\0")]
    parts = [element(index, 1, index_children),
             element(manifest, 2, [node(7, exguid(toc.DATA_ROOT) + exguid(cell_id[0]) + exguid(cell_id[1]))]),
             element(cell, 3, [node(0x0B, exguid(revision))])]
    predecessor = revision if revision_cycle else older if base else toc.NIL
    parts.append(element(revision, 4, [node(0x1A, exguid(revision) + exguid(predecessor)),
                                      node(0x0A, exguid(toc.CONTENT_ROOT) + exguid(root)),
                                      node(0x19, exguid(group))]))
    if base:
        # The current first leaf overrides the older revision, while all
        # other leaves are inherited from it.
        parts.append(object_group(group, values + leaves[:1]))
        old_values = [(key, dict(props), refs) for key, props, refs in leaves]
        old_values[0][1][toc.ORDER] = 99
        parts.append(object_group(old_group, old_values))
        parts.append(element(older, 4, [node(0x1A, exguid(older) + exguid(toc.NIL)),
                                       node(0x19, exguid(old_group))]))
    else:
        parts.append(object_group(group, values + leaves))
    return bytes(48) + toc.PACKAGING_FORMAT + bytes(4) + node(
        0x7A, exguid(index) + toc.TOC_SCHEMA, [node(0x15, b"\0", parts)])


BOOK = "0-0123456789ABCDEF!10"
TOC = "0123456789ABCDEF!12"


def sections():
    return [{"id": "0-0123456789ABCDEF!" + str(index), "name": name,
             "notebookId": BOOK, "notebook": "Test", "modified": "stamp"}
            for index, name in [(30, "Food"), (31, "Health"), (32, "Welcome"), (33, "New")]]


class Remote:
    def __init__(self, etag="v1"):
        self.etag, self.downloads, self.calls = etag, 0, []
        self.children = [{"id": s["id"][2:], "name": s["name"] + ".one", "file": {}} for s in sections()]
        self.children.append({"id": TOC, "name": "Open Notebook.onetoc2", "file": {}, "eTag": etag})

    def get(self, path):
        self.calls.append(path)
        if "/children" in path:
            return {"value": self.children}
        if path == order.item_path(TOC):
            return {"eTag": self.etag}
        return {"id": BOOK[2:], "name": "Test", "package": {"type": "oneNote"}}

    def download(self, item):
        self.downloads += 1
        return fixture(names=("Food.one", "Welcome.one", "Health.one", "Deleted.one"), orders=(3, 1, 5, 0))


class TocTests(unittest.TestCase):
    def test_current_and_inherited_revisions(self):
        for base in (False, True):
            entries = toc.section_entries(fixture(base=base))
            self.assertEqual([e["name"] for e in entries], ["Welcome.one", "Food.one", "Health.one"])
            self.assertEqual([e["order"] for e in entries], [1, 3, 5])

    def test_desktop_envelope(self):
        header = bytearray(1024)
        header[48:64] = toc.DESKTOP_FORMAT
        struct.pack_into("<QI", header, 160, 1024, 0)
        self.assertEqual(toc.section_entries(bytes(header) + fixture()), toc.section_entries(fixture()))
        struct.pack_into("<Q", header, 160, 2**63)
        with self.assertRaises(toc.InvalidToc):
            toc.section_entries(bytes(header) + fixture())

    def test_last_filename_reference_wins(self):
        entries = toc.section_entries(fixture(names=("Same.one", "Same.one"), orders=(1, 9)))
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["order"], 9)

    def test_cycles_and_limits(self):
        for data in (fixture(revision_cycle=True), fixture(object_cycle=True), bytes(toc.MAX_BYTES + 1),
                     fixture() + b"unexpected", fixture().replace(toc.TOC_SCHEMA, bytes(16))):
            with self.assertRaises(toc.InvalidToc):
                toc.section_entries(data)

    def test_all_truncations_rejected(self):
        data = fixture()
        for size in range(len(data)):
            with self.assertRaises(toc.InvalidToc, msg=str(size)):
                toc.section_entries(data[:size])

    def test_compact_encodings(self):
        for value in [0, 1, 127, 128, 16383, 16384, 2**32, 2**63, 2**64 - 1]:
            reader = toc.Reader(compact(value))
            self.assertEqual(reader.compact(), value)
            reader.finish()


class OrderingTests(unittest.TestCase):
    def test_live_join_and_versioned_cache(self):
        remote = Remote()
        result, cached, warnings = order.arrange(sections(), remote=remote)
        self.assertEqual([s["name"] for s in result], ["Welcome", "Food", "Health", "New"])
        self.assertFalse(warnings)
        self.assertEqual(len(result), len(sections()))  # Deleted.one stays deleted.
        self.assertEqual(remote.downloads, 1)
        self.assertNotIn("downloadUrl", json.dumps(cached))
        remote = Remote()
        again, _, _ = order.arrange(sections(), cached, remote)
        self.assertEqual(result, again)
        self.assertEqual(remote.downloads, 0)
        remote = Remote("v2")
        order.arrange(sections(), cached, remote)
        self.assertEqual(remote.downloads, 1)

    def test_unavailable_keeps_last_remote_order_and_warns(self):
        result, cached, _ = order.arrange(sections(), remote=Remote())
        remote = Remote()
        def offline(path):
            raise order.OrderUnavailable("offline")
        remote.get = offline
        again, saved, warnings = order.arrange(sections(), cached, remote)
        self.assertEqual(result, again)
        self.assertTrue(warnings)
        self.assertEqual(saved, cached)

    def test_unsupported_ids_never_probe_drive(self):
        entries, remote = sections(), Remote()
        entries[0] = dict(entries[0], notebookId="1-work-notebook", notebook="Work")
        entries[1] = dict(entries[1], notebookId="1-work-notebook", notebook="Work")
        result, _, warnings = order.arrange(entries, remote=remote)
        self.assertEqual(result[0], entries[0])
        self.assertTrue(warnings)
        self.assertFalse(any("work-notebook" in call for call in remote.calls))

    def test_removed_notebooks_prune_metadata(self):
        _, cached, _ = order.arrange(sections(), remote=Remote())
        _, saved, _ = order.arrange([], cached, Remote())
        self.assertFalse(saved["files"])
        self.assertFalse(saved["notebooks"])

    def test_paginated_listing_cycle(self):
        remote = Remote()
        remote.get = lambda path: {"value": [], "@odata.nextLink": path}
        with self.assertRaisesRegex(order.OrderUnavailable, "cyclic"):
            order.Ordering(remote, {}).children(BOOK[2:])

    def test_ambiguous_toc_is_not_guessed(self):
        remote = Remote()
        remote.children.append({"id": "extra", "name": ".onetoc2", "file": {}})
        result, _, warnings = order.arrange(sections(), remote=remote)
        self.assertEqual(result, sections())
        self.assertTrue(warnings)
        self.assertEqual(remote.downloads, 0)

    def test_nested_group_position_and_recycle_bin(self):
        remote = Remote()
        remote.children = [{"id": "group", "name": "Group", "folder": {}},
                           {"id": "bin", "name": "OneNote_RecycleBin", "folder": {}},
                           {"id": TOC, "name": "Open Notebook.onetoc2", "file": {}},
                           {"id": "food", "name": "Food.one", "file": {}}]
        original_get = remote.get
        def get(path):
            if path.startswith(order.item_path("group") + "/children"):
                return {"value": [{"id": "child", "name": "Child.one", "file": {}},
                                  {"id": "group-toc", "name": "Open Notebook.onetoc2", "file": {}}]}
            return original_get(path)
        remote.get = get
        reader = order.Ordering(remote, {})
        def entries(item):
            if item["id"] == TOC:
                return [{"name": "Food.one", "order": 1}, {"name": "Group", "order": 2}]
            return [{"name": "Child.one", "order": 1}]
        reader.entries = entries
        self.assertEqual(reader.folder(BOOK[2:]), ["0-food", "0-child"])
        self.assertNotIn("bin", reader.visited)

    def test_listing_checkpoint_preserves_order_cache_and_page_order(self):
        result, cached, _ = order.arrange(sections(), remote=Remote())
        pages = [{"id": "second", "sectionId": result[0]["id"]},
                 {"id": "first", "sectionId": result[0]["id"]}]
        listing = onenote.Listing({"pages": pages, "sectionOrders": cached}, result)
        with patch.object(onenote, "save_private") as save, patch.object(onenote.os, "makedirs"):
            listing.save(False)
        data = save.call_args.args[1]
        self.assertEqual(data["sectionOrders"], cached)
        self.assertEqual(data["sections"], result)
        self.assertEqual(data["pages"], pages)


class TransportTests(unittest.TestCase):
    def test_download_origin_allowlist(self):
        for host in order.DOWNLOAD_HOSTS:
            url = "https://test" + host + "/signed?secret=redacted"
            self.assertEqual(order.download_url(url), url)
        for url in ["http://x.files.1drv.com/x", "https://x.files.1drv.com.evil.test/x",
                    "https://files.1drv.com@evil.test/x", "file:///etc/passwd",
                    "https://user@x.sharepoint.com/x", "https://x.sharepoint.com:444/x",
                    "https://x.sharepoint.com/x#fragment", "https://[invalid"]:
            with self.assertRaises(order.OrderUnavailable):
                order.download_url(url)

    def test_untrusted_pagination_has_no_authorization(self):
        remote = order.Remote()
        with patch.object(remote, "request") as request:
            for path in ["https://evil.test/v1.0/me/drive/items/x", "https://graph.microsoft.com.evil.test/v1.0/me/drive/items/x"]:
                with self.assertRaises(order.OrderUnavailable):
                    remote.get(path)
            request.assert_not_called()

    def test_signed_download_omits_bearer_and_refuses_redirect(self):
        remote = order.Remote()
        class Response(io.BytesIO):
            status = 200
        with patch.object(remote.opener, "open", return_value=Response(b"toc")) as opened:
            remote.download({"size": 3, "@microsoft.graph.downloadUrl": "https://test.files.1drv.com/x"})
            request = opened.call_args.args[0]
            self.assertIsNone(request.get_header("Authorization"))
        self.assertIsNone(order.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test"))
        with patch.object(remote.opener, "open", side_effect=urllib.error.HTTPError("secret-url", 302, "", {}, None)):
            with self.assertRaisesRegex(order.OrderUnavailable, "HTTP 302"):
                remote.download({"size": 3, "@microsoft.graph.downloadUrl": "https://test.files.1drv.com/x"})

    def test_size_and_wall_clock_limits(self):
        with self.assertRaises(order.OrderUnavailable):
            order.read_response(io.BytesIO(bytes(toc.MAX_BYTES + 1)), float("inf"))
        with patch.object(order.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaises(order.OrderUnavailable):
                order.read_response(io.BytesIO(b"x"), 1)

    def test_graph_401_refreshes_once(self):
        remote = order.Remote()
        with patch.object(order.msgraph, "access_token", side_effect=["old", "new"]) as token:
            with patch.object(remote, "request", side_effect=[(401, b""), (200, b"{\"id\":\"x\"}")]) as request:
                self.assertEqual(remote.get(order.item_path("x")), {"id": "x"})
                self.assertEqual([call.args[1] for call in request.call_args_list], ["old", "new"])
            self.assertEqual(token.call_args_list[-1].args, (True,))

    def test_request_count_limit_before_sending(self):
        remote = order.Remote()
        remote.requests = order.MAX_REQUESTS
        with patch.object(remote.opener, "open") as opened:
            with self.assertRaises(order.OrderUnavailable):
                remote.request("https://test.files.1drv.com/x")
            opened.assert_not_called()


def run():
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    return unittest.TextTestRunner().run(suite).wasSuccessful()


if __name__ == "__main__":
    unittest.main()
