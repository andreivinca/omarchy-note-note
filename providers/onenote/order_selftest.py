"""Synthetic TOC/OneDrive tests: no account, network or real notebook data."""
import builtins
import contextlib
import io
import json
import struct
import time
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


def alphabetical():
    return sorted(sections(), key=lambda section: section["name"].casefold())


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
        return fixture(names=("Food.one", "Welcome.one", "Health.one", "Deleted.one", "New.one"), orders=(3, 1, 5, 0, 8))


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

    def test_unavailable_discards_last_remote_order_and_warns(self):
        _, cached, _ = order.arrange(sections(), remote=Remote())
        remote = Remote()
        def offline(path):
            raise order.OrderUnavailable("offline")
        remote.get = offline
        again, saved, warnings = order.arrange(sections(), cached, remote)
        self.assertEqual(again, alphabetical())
        self.assertTrue(warnings)
        self.assertFalse(saved["files"])

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
        self.assertNotIn("notebooks", saved)

    def test_paginated_listing_cycle(self):
        remote = Remote()
        remote.get = lambda path: {"value": [], "@odata.nextLink": path}
        with self.assertRaisesRegex(order.OrderUnavailable, "cyclic"):
            order.Ordering(remote, {}).children(BOOK[2:])

    def test_ambiguous_toc_is_not_guessed(self):
        remote = Remote()
        remote.children.append({"id": "extra", "name": ".onetoc2", "file": {}})
        result, _, warnings = order.arrange(sections(), remote=remote)
        self.assertEqual(result, alphabetical())
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

    def test_unexpected_failures_and_throttles_are_alphabetical(self):
        _, cached, _ = order.arrange(sections(), remote=Remote())
        for error in [RuntimeError("secret-url"), TypeError("secret-url"), SystemExit(1),
                      order.ratelimit.Throttled(60), toc.InvalidToc("unsupported"), TimeoutError()]:
            remote = Remote()
            with patch.object(remote, "get", side_effect=error):
                result, saved, warnings = order.arrange(list(reversed(sections())), cached, remote)
            self.assertEqual(result, alphabetical())
            self.assertFalse(saved["files"])
            self.assertTrue(warnings)
            self.assertNotIn("secret-url", str(warnings))

    def test_partial_or_changed_id_mapping_is_rejected(self):
        for count in (1, 4):
            remote = Remote()
            for item in remote.children[:count]:
                item["id"] = "changed-" + item["id"]
            result, saved, warnings = order.arrange(sections(), remote=remote)
            self.assertEqual(result, alphabetical())
            self.assertFalse(saved["files"])
            self.assertTrue(warnings)

    def test_missing_or_ambiguous_live_positions_are_rejected(self):
        for orders in [(3, 1, 5), (3, 1, 5, 5)]:
            remote = Remote()
            remote.download = lambda item: fixture(
                names=("Food.one", "Welcome.one", "Health.one", "New.one"), orders=orders)
            result, saved, warnings = order.arrange(sections(), remote=remote)
            self.assertEqual(result, alphabetical())
            self.assertTrue(warnings)
            self.assertFalse(saved["files"])

    def test_invalid_children_and_cache_do_not_abort(self):
        for invalid in [None, {}, {"name": "x.one"}, {"id": "x", "name": []}]:
            remote = Remote()
            remote.children.append(invalid)
            result, _, warnings = order.arrange(sections(), remote=remote)
            self.assertEqual(result, alphabetical())
            self.assertTrue(warnings)
        for files in [None, [], {TOC: None}, {TOC: {"etag": "v1", "entries": [None]}}]:
            result, _, warnings = order.arrange(sections(), {"version": order.CACHE_VERSION, "files": files}, Remote())
            self.assertEqual(result, alphabetical())
            self.assertTrue(warnings)


    def test_one_failed_notebook_does_not_change_a_healthy_one(self):
        broken = [dict(section, id="other-" + section["id"], notebookId="unsupported", notebook="Broken")
                  for section in reversed(sections())]
        mixed = [section for pair in zip(broken, sections()) for section in pair]
        result, saved, warnings = order.arrange(mixed, remote=Remote())
        self.assertEqual([section["name"] for section in result if section["notebookId"] == BOOK],
                         ["Welcome", "Food", "Health", "New"])
        self.assertEqual([section["name"] for section in result if section["notebookId"] == "unsupported"],
                         ["Food", "Health", "New", "Welcome"])
        self.assertEqual([section["notebookId"] for section in result], [section["notebookId"] for section in mixed])
        self.assertEqual(len(warnings), 1)
        self.assertIn(TOC, saved["files"])


class BoundaryTests(unittest.TestCase):
    def test_missing_scope_never_invokes_workaround(self):
        with patch.object(onenote, "has_section_order_scope", return_value=False), patch.object(order, "Remote") as remote:
            result, saved, warnings = onenote.ordered_sections(list(reversed(sections())), {}, "token")
        remote.assert_not_called()
        self.assertEqual(result, alphabetical())
        self.assertFalse(saved)
        self.assertTrue(warnings)

    def test_broken_optional_import_and_constructor_are_contained(self):
        original_import = builtins.__import__
        def missing(name, *args, **kwargs):
            if name == "section_order":
                raise ImportError("secret-url")
            return original_import(name, *args, **kwargs)
        with patch.object(onenote, "has_section_order_scope", return_value=True):
            with patch.object(builtins, "__import__", side_effect=missing):
                result, _, warnings = onenote.ordered_sections(sections(), {}, "token")
            self.assertEqual(result, alphabetical())
            self.assertNotIn("secret-url", str(warnings))
            with patch.object(order, "Remote", side_effect=RuntimeError("secret-url")):
                result, _, warnings = onenote.ordered_sections(sections(), {}, "token")
            self.assertEqual(result, alphabetical())
            self.assertTrue(warnings)

    def test_invalid_optional_result_cannot_change_graph_membership(self):
        for result in [sections()[:-1], sections() + sections()[:1],
                       [dict(section, name="changed") for section in sections()]]:
            with patch.object(onenote, "has_section_order_scope", return_value=True), patch.object(order, "Remote"):
                with patch.object(order, "arrange", return_value=(result, {}, [])):
                    arranged, _, warnings = onenote.ordered_sections(sections(), {}, "token")
            self.assertEqual(arranged, alphabetical())
            self.assertTrue(warnings)

    def test_workaround_failure_does_not_abort_page_listing_or_checkpoint(self):
        source = sections()
        graph_sections = [{"id": section["id"], "displayName": section["name"],
                           "lastModifiedDateTime": "stamp", "parentNotebook": {"id": BOOK, "displayName": "Test"}}
                          for section in source]
        printed = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(onenote, "has_section_order_scope", return_value=True))
            stack.enter_context(patch.object(onenote, "load_json", return_value={}))
            stack.enter_context(patch.object(onenote, "access_token", return_value="token"))
            stack.enter_context(patch.object(onenote, "graph", return_value=(200, {"value": graph_sections})))
            http = stack.enter_context(patch.object(onenote, "http", return_value=(200, {"value": [
                {"id": "z", "title": "Z first"}, {"id": "a", "title": "A second"}]})))
            save = stack.enter_context(patch.object(onenote, "save_private"))
            stack.enter_context(patch.object(onenote.os, "makedirs"))
            stack.enter_context(patch.object(order, "arrange", side_effect=RuntimeError("secret-url")))
            stack.enter_context(contextlib.redirect_stdout(printed))
            onenote.cmd_onenote_list(False)
        reply = json.loads(printed.getvalue())
        self.assertEqual(reply["sections"], alphabetical())
        self.assertEqual(http.call_count, len(source))
        self.assertTrue(all("$orderby=order" in call.args[1] for call in http.call_args_list))
        self.assertEqual([page["id"] for page in reply["pages"]], ["z", "a"] * len(source))
        self.assertEqual(save.call_args.args[1]["sections"], alphabetical())
        self.assertTrue(reply["sectionOrderWarnings"])
        self.assertNotIn("secret-url", printed.getvalue())

    def test_cached_order_loses_permission_or_old_policy(self):
        for scope, version in [(False, onenote.SECTION_ORDER_VERSION), (True, 1)]:
            cache = {"sections": list(reversed(sections())), "pages": [], "fetched": time.time(),
                     "sectionOrderVersion": version, "sectionOrderScope": True}
            printed = io.StringIO()
            with patch.object(onenote, "load_json", return_value=cache), patch.object(onenote, "has_section_order_scope", return_value=scope):
                with contextlib.redirect_stdout(printed):
                    onenote.cmd_onenote_list(True)
            self.assertEqual(json.loads(printed.getvalue())["sections"], alphabetical())

    def test_print_then_exit_cannot_corrupt_provider_protocol(self):
        def broken(*args):
            onenote.fail("secret-url")
        printed = io.StringIO()
        with patch.object(onenote, "has_section_order_scope", return_value=True), patch.object(order, "Remote"):
            with patch.object(order, "arrange", side_effect=broken), contextlib.redirect_stdout(printed):
                result, _, warnings = onenote.ordered_sections(sections(), {}, "token")
        self.assertEqual(result, alphabetical())
        self.assertTrue(warnings)
        self.assertEqual(printed.getvalue(), "")


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
        remote = order.Remote("snapshot")
        with patch.object(remote, "request") as request:
            for path in ["https://evil.test/v1.0/me/drive/items/x", "https://graph.microsoft.com.evil.test/v1.0/me/drive/items/x"]:
                with self.assertRaises(order.OrderUnavailable):
                    remote.get(path)
            request.assert_not_called()

    def test_signed_download_omits_bearer_and_refuses_redirect(self):
        remote = order.Remote("snapshot")
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

    def test_graph_401_never_refreshes_or_forgets_shared_auth(self):
        remote = order.Remote("snapshot")
        with patch.object(order.msgraph, "access_token") as token, patch.object(order.msgraph, "forget_token") as forget:
            with patch.object(remote, "request", return_value=(401, b"")) as request:
                with self.assertRaises(order.OrderUnavailable):
                    remote.get(order.item_path("x"))
                self.assertEqual(request.call_args.args[1], "snapshot")
                self.assertEqual(request.call_count, 1)
            token.assert_not_called()
            forget.assert_not_called()

    def test_request_count_limit_before_sending(self):
        remote = order.Remote("snapshot")
        remote.requests = order.MAX_REQUESTS
        with patch.object(remote.opener, "open") as opened:
            with self.assertRaises(order.OrderUnavailable):
                remote.request("https://test.files.1drv.com/x")
            opened.assert_not_called()

    def test_metadata_throttle_has_its_own_budget(self):
        remote = order.Remote("snapshot")
        with patch.object(order.ratelimit, "attempt_loop", return_value=(429, b"")) as attempt:
            remote.request(order.msgraph.GRAPH + order.item_path("x"), "snapshot")
        self.assertEqual(attempt.call_args.args[0], "graph-onenote-section-order")
        self.assertNotEqual(attempt.call_args.args[0], onenote.msgraph.RATE_KEY)


def run():
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    return unittest.TextTestRunner().run(suite).wasSuccessful()


if __name__ == "__main__":
    unittest.main()
