"""Merge and recovery tests using synthetic notes, without a provider or UI."""
from pathlib import Path
import itertools
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from notemerge import (  # noqa: E402
    AmbiguousAlignment, DraftOwnedByAnotherView, MergeStore, StaleRemote, align, merge_note,
)


def note(body, title="Title"):
    return {"title": title, "body": body}


class MergeTests(unittest.TestCase):
    def test_repeated_checkbox_edits_combine_with_prose_edits_and_insertions(self):
        for states in itertools.product((False, True), repeat=3):
            for left, right in itertools.permutations(range(3), 2):
                def document(flags, footer):
                    return note("\n".join("- [%s] Same" % ("x" if flag else " ") for flag in flags) + "\n\n" + footer)

                ours, theirs, expected = list(states), list(states), list(states)
                ours[left] = not ours[left]
                theirs[right] = not theirs[right]
                expected[left] = not expected[left]
                expected[right] = not expected[right]
                for addition in ("", "\nRemote addition"):
                    with self.subTest(states=states, left=left, right=right, addition=addition):
                        result = merge_note(document(states, "Footer"), document(ours, "New footer"),
                                            document(theirs, "Footer" + addition))
                        self.assertEqual(result["note"], document(expected, "New footer" + addition))

    def test_ambiguous_repeated_deletion_requires_review(self):
        base = note("- [ ] Same\n- [ ] Same\n\nFooter")
        local = note("- [ ] Same\n\nFooter")
        remote = note("- [x] Same\n- [ ] Same\n\nNew footer")
        result = merge_note(base, local, remote)
        self.assertIsNone(result["note"])
        self.assertEqual(result["conflict"]["parts"][0]["base"], base["body"])

    def test_checkbox_state_combinations_preserve_order_and_item_count(self):
        for labels in (("Apples", "Bread", "Coffee"), ("Same", "Same", "Same")):
            def checklist(flags):
                return note("".join("- [%s] %s\n" % ("x" if flag else " ", label)
                                    for flag, label in zip(flags, labels)))
            for states in itertools.product((False, True), repeat=3):
                for local_index, remote_index in itertools.permutations(range(3), 2):
                    local, remote, expected = list(states), list(states), list(states)
                    local[local_index] = not local[local_index]
                    remote[remote_index] = not remote[remote_index]
                    expected[local_index] = not expected[local_index]
                    expected[remote_index] = not expected[remote_index]
                    with self.subTest(labels=labels, states=states, local=local_index, remote=remote_index):
                        self.assertEqual(merge_note(checklist(states), checklist(local), checklist(remote))["note"],
                                         checklist(expected))

    def test_adjacent_checkbox_changes_merge(self):
        base = note("- [ ] Apples\n- [ ] Bread\n")
        local = note("- [ ] Apples\n- [x] Bread\n")
        remote = note("- [x] Apples\n- [ ] Bread\n")
        result = merge_note(base, local, remote)
        self.assertIsNone(result["conflict"])
        self.assertEqual(result["note"], note("- [x] Apples\n- [x] Bread\n"))

    def test_adjacent_line_edits_merge_without_a_shared_unchanged_line(self):
        base = note("red apples\nfresh bread")
        local = note("green apples\nfresh bread")
        remote = note("red apples\nwarm bread")
        self.assertEqual(merge_note(base, local, remote)["note"], note("green apples\nwarm bread"))

    def test_independent_words_merge_but_same_word_changes_do_not(self):
        base = note("Buy milk today")
        self.assertEqual(merge_note(base, note("Buy bread today"), note("Buy milk tomorrow"))["note"],
                         note("Buy bread tomorrow"))
        conflict = merge_note(note("cat"), note("hat"), note("car"))
        self.assertIsNone(conflict["note"])
        self.assertEqual(conflict["conflict"]["parts"][0]["base"], "cat")

    def test_refinement_preserves_whitespace_and_markdown(self):
        base = note("  - [ ] **Apples**\r\n  - [ ] *Bread*\r\n")
        local = note(base["body"].replace("[ ] *Bread*", "[x] *Bread*"))
        remote = note(base["body"].replace("[ ] **Apples**", "[x] **Apples**"))
        self.assertEqual(merge_note(base, local, remote)["note"], note(base["body"].replace("[ ]", "[x]")))

    def test_checking_and_deleting_the_same_item_still_conflict(self):
        base = note("- [ ] Apples\n- [ ] Bread\n")
        local = note("- [x] Apples\n- [ ] Bread\n")
        remote = note("- [ ] Bread\n")
        self.assertIsNone(merge_note(base, local, remote)["note"])

    def test_refinement_is_bounded(self):
        base = note("word " * 5000)
        result = merge_note(base, note(base["body"] + "ours"), note(base["body"] + "theirs"))
        self.assertIsNone(result["note"])

    def test_independent_changes_and_deletion(self):
        base = note("one\nseparator\nthree\n")
        local = note("ONE\nseparator\nthree\n")
        remote = note("one\nseparator\n")
        self.assertEqual(merge_note(base, local, remote)["note"], note("ONE\nseparator\n"))

    def test_identical_changes_appear_once(self):
        base, edited = note("original"), note("edited\nnew")
        self.assertEqual(merge_note(base, edited, edited)["note"], edited)
        self.assertEqual(merge_note(base, base, edited)["note"], edited)
        self.assertEqual(merge_note(base, edited, base)["note"], edited)

    def test_title_and_body_are_independent(self):
        self.assertEqual(merge_note(note("body"), note("body", "New"), note("edited"))["note"],
                         note("edited", "New"))

    def test_conflicts_require_all_choices(self):
        base, local, remote = note("old", "Old"), note("ours", "Ours"), note("theirs", "Theirs")
        conflict = merge_note(base, local, remote)["conflict"]
        self.assertEqual({part["field"] for part in conflict["parts"]}, {"title", "body"})
        resolution = {"id": conflict["id"], "choices": {"title:0": "local"}}
        self.assertIsNone(merge_note(base, local, remote, resolution)["note"])
        resolution["choices"]["body:0"] = "both"
        self.assertEqual(merge_note(base, local, remote, resolution)["note"], note("ours\ntheirs", "Ours"))

    def test_resolution_is_bound_to_all_three_versions(self):
        base, local, remote = note("old"), note("ours"), note("theirs")
        conflict = merge_note(base, local, remote)["conflict"]
        resolution = {"id": conflict["id"], "choices": {"body:0": "local"}}
        self.assertEqual(merge_note(base, local, remote, resolution)["note"], local)
        self.assertIsNone(merge_note(base, local, note("new phone edit"), resolution)["note"])
        self.assertIsNone(merge_note(base, note("new local edit"), remote, resolution)["note"])

    def test_unicode_crlf_and_trailing_newlines(self):
        base = note("café\r\nseparator\r\n漢字")
        local = note("☕\r\nseparator\r\n漢字")
        remote = note("café\r\nseparator\r\n日本語\r\n")
        self.assertEqual(merge_note(base, local, remote)["note"], note("☕\r\nseparator\r\n日本語\r\n"))

    def test_insertion_at_same_position_is_reviewed(self):
        merged = merge_note(note("a\nz\n"), note("a\nx\nz\n"), note("a\ny\nz\n"))
        self.assertIsNone(merged["note"])
        part = merged["conflict"]["parts"][0]
        self.assertEqual((part["local"], part["remote"]), ("x\n", "y\n"))

    def test_invalid_and_excessive_content_fails_closed(self):
        for value in (None, {"body": []}, note("x" * (2 * 1024 * 1024 + 1)), note("\n" * 20001)):
            with self.assertRaises(ValueError):
                merge_note(value, note(""), note(""))


class AlignmentTests(unittest.TestCase):
    def test_arbitrary_provider_records_use_the_same_alignment(self):
        original = [{"label": "Same", "checked": False}, {"label": "Same", "checked": False}, {"label": "Footer"}]
        edited = [{"label": "Same", "checked": True}, {"label": "Same", "checked": False}, {"label": "New footer"}]
        spans = align(original, edited, key=lambda item: item["label"])
        self.assertEqual([(span.kind, span.before_start, span.before_end, span.after_start, span.after_end)
                          for span in spans], [("equal", 0, 2, 0, 2), ("replace", 2, 3, 2, 3)])

    def test_partial_removal_of_indistinguishable_records_is_ambiguous(self):
        with self.assertRaises(AmbiguousAlignment):
            align(["Same", "Same"], ["Same"], key=str)
        self.assertEqual(align(["Same", "Same"], [], key=str)[0].kind, "delete")


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="note-note-merge-tests-")
        self.addCleanup(self.temp.cleanup)

    def store(self, provider="test", account="account", document="note"):
        return MergeStore(self.temp.name, provider, account, document, stale_seconds=120)

    def test_next_save_retains_remote_edits_not_yet_shown(self):
        with self.store() as store:
            view = store.open(note("a\nseparator\nz"))["view"]
            store.stage(view, note("A\nseparator\nz"))
            merged = store.prepare(note("a\nseparator\nZ"))["note"]
            store.commit(merged)
        with self.store() as store:
            store.stage(view, note("AA\nseparator\nz"))
            self.assertEqual(store.prepare(merged)["note"], note("AA\nseparator\nZ"))

    def test_draft_and_conflict_survive_process_restart(self):
        with self.store() as store:
            view = store.open(note("base"))["view"]
            store.stage(view, note("ours"))
            conflict = store.prepare(note("theirs"))["conflict"]
            path = store.path
        with self.store() as store:
            recovered = store.open(note("theirs"))
            self.assertTrue(recovered["recovered"])
            self.assertEqual(recovered["body"], "ours")
            self.assertEqual(recovered["conflict"], conflict)
            resolution = {"id": conflict["id"], "choices": {"body:0": "both"}}
            store.commit(store.prepare(note("theirs"), resolution)["note"])
            self.assertIsNone(store._state["draft"])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

    def test_another_view_cannot_replace_a_pending_draft(self):
        remote = note("remote change")
        for prepared in (False, True):
            with self.subTest(prepared=prepared):
                document = str(prepared)
                with self.store(document=document) as store:
                    first = store.open(note("base"))["view"]
                    second = store.open(note("base"))["view"]
                    store.stage(first, note("editor A draft"))
                    if prepared:
                        self.assertIsNotNone(store.prepare(remote)["conflict"])
                    before = store.path.read_bytes()
                with self.store(document=document) as store:
                    with self.assertRaises(DraftOwnedByAnotherView):
                        store.stage(second, note("base\neditor B addition"))
                    self.assertEqual(store.path.read_bytes(), before)
                    self.assertEqual(store.recover()["body"], "editor A draft")
                    self.assertEqual(store.open(remote)["view"], first)
                    # Only the owner can supersede its draft. Once committed,
                    # the second view can merge against its own original base.
                    store.stage(first, note("base\neditor A addition"))
                    saved = store.prepare(remote)["note"]
                    store.commit(saved)
                    store.stage(second, note("BASE"))
                    self.assertEqual(store.recover()["body"], "BASE")

    def test_another_view_cannot_erase_a_partial_write(self):
        with self.store() as store:
            first = store.open(note("base"))["view"]
            second = store.open(note("base"))["view"]
            store.stage(first, note("saved body", "Pending title"))
            store.prepare(note("base"))
            store.commit(note("saved body"), accepted_fields=("body",))
            before = store.path.read_bytes()
            with self.assertRaises(DraftOwnedByAnotherView):
                store.stage(second, note("other draft"))
            self.assertEqual(store.path.read_bytes(), before)
            self.assertEqual(store.recover()["title"], "Pending title")

    def test_recovery_rechecks_an_old_coarse_checkbox_conflict(self):
        base = note("- [ ] Apples\n- [ ] Bread")
        local = note("- [ ] Apples\n- [x] Bread")
        remote = note("- [x] Apples\n- [ ] Bread")
        with self.store() as store:
            view = store.open(base)["view"]
            store.stage(view, local)
            store.prepare(remote)
            store._state["draft"]["conflict"] = {"id": "old-engine", "parts": []}
            store._persist()
        with self.store() as store:
            recovered = store.open(remote)
            self.assertTrue(recovered["retry"])
            self.assertNotIn("conflict", recovered)
            self.assertEqual(recovered["body"], local["body"])
            self.assertIsNotNone(store._state["draft"])
            # A retry must still merge against a fresh remote response.
            latest = note("- [x] Apples\n- [ ] Bread\n- [ ] Coffee")
            store.stage(recovered["view"], recovered)
            result = store.prepare(latest)
            self.assertEqual(result["note"], note("- [x] Apples\n- [x] Bread\n- [ ] Coffee"))

    def test_stale_read_does_not_undo_an_acknowledged_save(self):
        with self.store() as store:
            view = store.open(note("old"))["view"]
            store.stage(view, note("first"))
            store.commit(store.prepare(note("old"))["note"])
            store.stage(view, note("second"))
            with self.assertRaises(StaleRemote):
                store.prepare(note("old"))
            self.assertEqual(store._state["draft"]["local"], note("second"))
            self.assertEqual(store.prepare(note("first"))["note"], note("second"))
            with patch("notemerge.store.time.time", return_value=store._state["writtenAt"] + 121):
                store.check_remote(note("old"))  # a later intentional revert can be reviewed

    def test_active_editor_survives_many_saves(self):
        with self.store() as store:
            remote = note("0")
            view = store.open(remote)["view"]
            for index in range(30):
                store.stage(view, note(str(index + 1)))
                remote = store.prepare(remote)["note"]
                store.commit(remote)
            self.assertIn(view, store._state["views"])
            self.assertLessEqual(len(store._state["views"]), 12)
            self.assertLessEqual(len(store._state["history"]), 3)

    def test_partial_write_keeps_failed_title_and_advances_body(self):
        with self.store() as store:
            view = store.open(note("old"))["view"]
            store.stage(view, note("first", "New title"))
            store.prepare(note("old"))
            store.commit(note("first"), accepted_fields=("body",))
            self.assertIsNotNone(store._state["draft"])
            store.stage(view, note("second", "New title"))
            self.assertEqual(store.prepare(note("first"))["note"], note("second", "New title"))

    def test_recovery_api_does_not_require_a_remote_snapshot(self):
        with self.store() as store:
            self.assertIsNone(store.recover())
            view = store.open(note("original"))["view"]
            store.stage(view, note("pending"))
        with self.store() as store:
            recovered = store.recover()
            self.assertEqual(recovered["body"], "pending")
            self.assertEqual(recovered["view"], view)
            self.assertTrue(recovered["recovered"])

    def test_invalid_baseline_and_corrupt_journal_are_not_overwritten(self):
        with self.store() as store:
            with self.assertRaises(ValueError):
                store.stage("missing", note("ours"))
            path = store.path
        path.write_text("broken")
        with self.assertRaises(ValueError):
            with self.store():
                pass
        self.assertEqual(path.read_text(), "broken")

    def test_failed_persistence_prevents_starting_a_save(self):
        with self.store() as store:
            view = store.open(note("old"))["view"]
            with patch("notemerge.store.save_private", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    store.stage(view, note("ours"))

    def test_identities_are_isolated_and_cannot_escape_storage(self):
        first = self.store(document="../../outside")
        self.assertEqual(first.directory.parent, Path(self.temp.name))
        paths = {self.store(provider=p, account=a).directory for p in ("one", "two") for a in ("a", "b")}
        self.assertEqual(len(paths), 4)


if __name__ == "__main__":
    unittest.main()
