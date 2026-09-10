"""Search cache, provider transport and QML lifecycle tests; no real account."""
import contextlib
import io
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "lib"))
sys.path.insert(0, str(HERE))
import search_index as search  # noqa: E402
import onenote  # noqa: E402
from notemerge import MergeStore  # noqa: E402


def page(page_id, section="s", modified="1"):
    return {"id": page_id, "sectionId": section, "modified": modified}


def write_child(directory, ticket, text):
    search.Index(directory, "a", now=lambda: 1000).record(ticket["id"], text, ticket)


def claim_child(directory, answers, release):
    answers.put(search.Index(directory, "a", now=lambda: 1000).claim_page([]))
    release.wait(5)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.clock = 1000
        self.valid = True
        self.index = search.Index(self.temp.name, "a", lambda: self.valid, lambda: self.clock)
        self.index.sync([page("p1"), page("p2", "other")])

    def put(self, page_id, text):
        self.assertTrue(self.index.record(page_id, text, self.index.ticket(page_id)))

    def test_visible_text_and_links_without_images_or_markup(self):
        html = ('<html><head><title>secret-title</title><style>secret-style</style></head>'
                '<body><p>Te<strong>le</strong>fon &amp; STRAẞE</p><div>Second<br>line</div>'
                '<script>secret-script</script><img src="https://secret-image">'
                '<a href="https://example.com/path">website</a></body></html>')
        text = search.searchable_text(html)
        self.assertIn("telefon & strasse second line", text)
        self.assertIn("https://example.com/path", text)
        self.assertNotIn("secret", text)
        self.assertNotIn("<", text)

    def test_restart_keeps_text_and_resumes_unread_pages(self):
        self.put("p1", "telefon")
        restarted = search.Index(self.temp.name, "a", now=lambda: self.clock)
        self.assertEqual(restarted.search("TELEFON")["ids"], ["p1"])
        self.assertEqual(restarted.next_page([])["id"], "p2")
        self.assertEqual(restarted.status()["indexed"], 1)
        self.put("p2", "")
        self.assertEqual(restarted.status()["indexed"], 2)
        self.assertEqual(restarted.status()["pending"], 0)
        self.assertEqual(os.stat(self.index.path).st_mode & 0o777, 0o600)

    def test_inventory_changes_preserve_text_and_remove_deleted_pages(self):
        self.put("p1", "cached text")
        old = self.index.ticket("p2")
        self.index.sync([page("p1", modified="2"), page("p3")])
        self.assertEqual(self.index.search("cached")["ids"], ["p1"])
        self.assertFalse(self.index.record("p2", "late", old))
        self.assertEqual(self.index.status()["pending"], 2)
        self.index.sync([page("p1", modified="2"), page("p2")])
        self.assertFalse(self.index.record("p2", "late", old))

    def test_save_beats_inflight_reads_and_allows_eventual_consistency(self):
        old = self.index.ticket("p1")
        self.index.record("p1", "new text", saved=True)
        self.assertFalse(self.index.record("p1", "old text", old))
        self.index.sync([page("p1", modified="2"), page("p2")])
        fresh_ticket = self.index.ticket("p1")
        self.assertFalse(self.index.record("p1", "lagging server", fresh_ticket))
        self.clock += search.SAVE_GRACE_SECONDS + 1
        self.assertTrue(self.index.record("p1", "new server text", fresh_ticket))
        self.assertEqual(self.index.search("lagging")["ids"], [])

    def test_old_signin_cannot_read_write_or_clear_new_account(self):
        self.put("p1", "private a")
        old = self.index.ticket("p1")
        self.valid = False
        self.assertEqual(self.index.search("private")["ids"], [])
        self.index.clear()
        self.assertFalse(self.index.record("p1", "late a", old))
        other = search.Index(self.temp.name, "b", now=lambda: self.clock)
        other.sync([page("p1")])
        other.record("p1", "private b", other.ticket("p1"))
        self.index.clear()
        self.index.sync([page("p2")])
        self.assertEqual(other.search("private b")["ids"], ["p1"])
        self.assertEqual(self.index.search("private b")["ids"], [])

    def test_failures_back_off_without_blocking_other_pages(self):
        self.index.failed(self.index.ticket("p1"), 500)
        self.assertEqual(self.index.next_page([])["id"], "p2")
        self.assertEqual(self.index.status()["failed"], 1)
        self.clock += 301
        self.assertEqual(self.index.next_page(["s"])["id"], "p1")
        self.put("p1", "old body")
        self.clock += search.REFRESH_SECONDS + 1
        self.index.failed(self.index.ticket("p1"), 503)
        self.assertEqual(self.index.search("old")["ids"], ["p1"])
        self.index.failed(self.index.ticket("p1"), 403)
        self.assertEqual(self.index.search("old")["ids"], [])

    def test_periodic_refresh_does_not_depend_on_modified_stamp(self):
        self.put("p1", "old")
        self.put("p2", "other")
        self.assertIsNone(self.index.next_page([]))
        self.clock += search.REFRESH_SECONDS + 1
        self.index.sync([page("p1"), page("p2", "other")])
        self.assertEqual(self.index.next_page(["other"])["id"], "p2")

    def test_bounds_corruption_and_failed_atomic_write(self):
        self.put("p1", "original")
        with self.assertRaises(ValueError):
            self.index.record("p1", "x" * (search.MAX_TEXT_BYTES + 1), saved=True)
        with patch.object(search, "save_private", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.index.record("p1", "replacement", saved=True)
        self.assertEqual(self.index.search("original")["ids"], ["p1"])
        with patch.object(search, "MAX_CACHE_BYTES", 20):
            self.assertEqual(self.index.search("original")["ids"], [])
        Path(self.index.path).write_text('{"version":1,"entries":{"bad":null}}')
        self.assertEqual(self.index.search("anything")["ids"], [])
        self.assertEqual(self.index.sync([page("p1")])["pending"], 1)

    def test_concurrent_process_writes_are_merged(self):
        processes = [multiprocessing.get_context("fork").Process(
            target=write_child, args=(self.temp.name, self.index.ticket(page_id), "needle"))
            for page_id in ("p1", "p2")]
        for process in processes:
            process.start()
        for process in processes:
            process.join(5)
            self.assertEqual(process.exitcode, 0)
        self.assertEqual(set(self.index.search("needle")["ids"]), {"p1", "p2"})

    def test_parallel_workers_claim_distinct_pages_and_recover_after_exit(self):
        context = multiprocessing.get_context("fork")
        answers, release = context.Queue(), context.Event()
        processes = [context.Process(target=claim_child, args=(self.temp.name, answers, release))
                     for _ in range(2)]
        try:
            for process in processes:
                process.start()
            tickets = [answers.get(timeout=5) for _ in processes]
            self.assertEqual({ticket["id"] for ticket in tickets}, {"p1", "p2"})
            self.assertIsNone(self.index.next_page([]))
        finally:
            release.set()
            for process in processes:
                process.join(5)
                self.assertEqual(process.exitcode, 0)
            answers.close()
        self.assertIsNotNone(self.index.next_page([]))

    def test_expired_worker_cannot_overwrite_a_new_claim(self):
        first = self.index.claim_page(["s"])
        self.clock += search.LEASE_SECONDS + 1
        second = self.index.claim_page(["s"])
        self.assertEqual(first["id"], second["id"])
        self.assertFalse(self.index.record(first["id"], "late", first))
        self.assertTrue(self.index.record(second["id"], "current", second))
        self.assertEqual(self.index.search("current")["ids"], [second["id"]])


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(onenote, "CACHE_DIR", self.temp.name))
        self.stack.enter_context(patch.object(onenote, "ONENOTE_CACHE", self.temp.name + "/listing.json"))
        self.stack.enter_context(patch.object(onenote, "ONENOTE_IMG_DIR", self.temp.name + "/images"))
        self.stack.enter_context(patch.object(onenote, "IMAGE_INDEX", self.temp.name + "/images/index.json"))
        self.stack.enter_context(patch.object(onenote.msgraph, "config", return_value=("client", "common")))
        self.stack.enter_context(patch.object(onenote.msgraph, "signed_in", return_value={"cacheSession": "a"}))
        self.stack.enter_context(patch.dict(os.environ, {"NOTE_NOTE_MS_CACHE_SESSION": "a"}))
        self.index = onenote.content_index()
        self.index.sync([page("p1")])
        self.out = self.stack.enter_context(patch.object(onenote, "out"))
        self.payload = self.stack.enter_context(patch.object(onenote, "read_payload", return_value={}))
        self.stack.enter_context(patch.object(onenote, "merge_store", self.store))

    def store(self, page_id):
        return MergeStore(self.temp.name, "onenote", "test-account", page_id, normalize=onenote.normalize_note)

    def test_indexing_downloads_html_only_and_search_never_uses_network(self):
        with patch.object(onenote.ratelimit, "background_delay", return_value=0), \
                patch.object(onenote, "cached_image", side_effect=AssertionError("image fetched")), \
                patch.object(onenote, "graph_raw", return_value=(200,
                    '<html><body><p>Telefon</p><img src="https://example.com/a.png"></body></html>')) as remote:
            onenote.cmd_search_step("-")
            self.assertEqual(remote.call_count, 1)
            self.assertEqual(self.out.call_args.args[0]["status"]["indexed"], 1)
            self.payload.return_value = {"query": "telefon"}
            remote.side_effect = AssertionError("search touched network")
            onenote.cmd_search("-")
            self.assertEqual(self.out.call_args.args[0]["paths"], ["onenote:p1"])

    def test_budget_defers_indexing_without_parking_foreground_lane(self):
        with patch.object(onenote.ratelimit, "background_delay", return_value=120), \
                patch.object(onenote, "graph_raw", side_effect=AssertionError("no budget")):
            onenote.cmd_search_step("-")
        result = self.out.call_args.args[0]
        self.assertTrue(result["deferred"])
        self.assertNotIn("kind", result)
        self.assertEqual(result["retryAfter"], 120)

    def test_failed_page_is_not_counted_as_indexed(self):
        with patch.object(onenote.ratelimit, "background_delay", return_value=0), \
                patch.object(onenote, "graph_raw", return_value=(404, "{}")):
            onenote.cmd_search_step("-")
        result = self.out.call_args.args[0]["status"]
        self.assertEqual((result["indexed"], result["pending"], result["failed"]), (0, 1, 1))

    def test_successful_save_updates_text_without_an_extra_read(self):
        ticket = self.index.ticket("p1")
        base = {"title": "same", "body": "original\n\nseparator\n\nlast"}
        with self.store("p1") as journal:
            view = journal.open(base)["view"]
        self.payload.return_value = dict(base, view=view, body="new searchable text\n\nseparator\n\nlast")
        html = ('<html><head><title>same</title></head><body><div id="div:root">'
                '<p id="p:first">original</p><p id="p:middle">separator</p>'
                '<p id="p:last">phone addition</p></div></body></html>')
        with patch.object(onenote, "patch_page", return_value=(204, "")) as write, \
                patch.object(onenote, "graph_raw", return_value=(200, html)) as read:
            onenote.cmd_onenote_update("p1", "-")
        self.assertTrue(self.out.call_args.args[0]["ok"])
        self.assertEqual(read.call_count, 1, "search must reuse the save's required fresh read")
        self.assertEqual(read.call_args.args[0], "GET")
        self.assertIn("includeIDs=true", read.call_args.args[1])
        self.assertEqual(write.call_count, 1)
        self.assertEqual(self.index.search("searchable")["ids"], ["p1"])
        self.assertEqual(self.index.search("phone addition")["ids"], ["p1"])
        self.assertEqual(self.index.search("original")["ids"], [])
        self.assertFalse(self.index.record("p1", "stale response", ticket))

    def test_conflicting_local_text_is_not_published_to_search(self):
        with self.store("p1") as journal:
            view = journal.open({"title": "same", "body": "original"})["view"]
        self.payload.return_value = {"title": "same", "body": "local conflict", "view": view}
        html = '<html><head><title>same</title></head><body><p id="p:one">remote conflict</p></body></html>'
        with patch.object(onenote, "patch_page", side_effect=AssertionError("conflict must not write")), \
                patch.object(onenote, "graph_raw", return_value=(200, html)):
            onenote.cmd_onenote_update("p1", "-")
        self.assertIsNotNone(self.out.call_args.args[0]["conflict"])
        self.assertEqual(self.index.search("remote conflict")["ids"], ["p1"])
        self.assertEqual(self.index.search("local conflict")["ids"], [])

    def test_account_lookup_cannot_write_another_signins_token(self):
        tokens = [{"cacheSession": "a"}, {"cacheSession": "b", "refresh_token": "new"}]
        with patch.object(onenote.msgraph, "signed_in", side_effect=tokens), \
                patch.object(onenote.msgraph, "TOKENS", self.temp.name + "/token.json"), \
                patch.object(onenote, "graph", return_value=(200, {"id": "account-a"})), \
                patch.object(onenote, "save_private") as save, contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit):
                onenote.merge_account()
        save.assert_not_called()
        self.assertIn("the signed-in account changed", output.getvalue())

    def test_account_lookup_preserves_a_concurrent_token_refresh(self):
        tokens = [{"cacheSession": "a", "refresh_token": "old"}, {"cacheSession": "a", "refresh_token": "new"}]
        with patch.object(onenote.msgraph, "signed_in", side_effect=tokens), \
                patch.object(onenote.msgraph, "TOKENS", self.temp.name + "/token.json"), \
                patch.object(onenote, "graph", return_value=(200, {"id": "account-a"})), \
                patch.object(onenote, "save_private") as save:
            self.assertEqual(onenote.merge_account(), "client:account-a")
        self.assertEqual(save.call_args.args[1], {"cacheSession": "a", "refresh_token": "new", "userId": "account-a"})

    def test_other_account_listing_is_never_used_as_search_inventory(self):
        onenote.save_private(onenote.ONENOTE_CACHE, {"cacheSession": "other", "pages": [page("private")]})
        onenote.cmd_onenote_list(True)
        self.assertEqual(self.out.call_args.args[0]["pages"], [])
        self.assertFalse(self.out.call_args.args[0]["inventoryReady"])

    def test_partial_and_capped_listings_do_not_claim_complete_search_scope(self):
        listing = onenote.Listing({}, [{"id": "s", "modified": "1", "notebookId": "book", "name": "Section"}])
        listing.record({"id": "s", "modified": "1"}, [page("p1")])
        listing.save(False)
        onenote.cmd_onenote_list(True)
        self.assertTrue(self.out.call_args.args[0]["inventoryReady"])
        self.assertFalse(self.out.call_args.args[0]["inventoryComplete"])
        listing.save(True)
        onenote.cmd_onenote_list(True)
        self.assertTrue(self.out.call_args.args[0]["inventoryComplete"])
        with patch.object(onenote, "MAX_PAGES", 1):
            listing.save(True)
        onenote.cmd_onenote_list(True)
        self.assertFalse(self.out.call_args.args[0]["inventoryComplete"])

    def test_background_budget_read_does_not_consume_a_request(self):
        state = {"stamps": [999] * 80, "cooldownUntil": 0}
        with patch.object(onenote.ratelimit, "_locked", return_value=contextlib.nullcontext(state)):
            delay = onenote.ratelimit.background_delay("test", [(60, 100)], now=lambda: 1000)
        self.assertEqual(delay, 59)
        self.assertEqual(len(state["stamps"]), 80)


class QmlTests(unittest.TestCase):
    def test_controller_lifecycle(self):
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic",
                   QT_FORCE_STDERR_LOGGING="1")
        proc = subprocess.run(["qml6", str(HERE / "search_selftest.qml")],
                              capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("<<<RESULT>>>", proc.stderr, proc.stderr)
        results = json.loads(proc.stderr.split("<<<RESULT>>>")[1].split("<<<END>>>")[0])
        self.assertTrue(results, proc.stderr)
        self.assertEqual([row for row in results if not row["ok"]], [], proc.stderr)
        noise = [line for line in proc.stderr.splitlines() if ".qml:" in line or "qrc:" in line]
        self.assertEqual(noise, [], proc.stderr)


if __name__ == "__main__":
    unittest.main()
