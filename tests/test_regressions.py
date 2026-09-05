"""Content preservation and confirmed IO regressions; temporary files only."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / path) for path in (
    "lib", "services/markdown", "providers/local", "providers/notion")]
import fileio  # noqa: E402 — plugin modules are imported from the source tree
import readfile  # noqa: E402 — plugin modules are imported from the source tree
import operations  # noqa: E402 — plugin modules are imported from the source tree
import images  # noqa: E402 — plugin modules are imported from the source tree
import notion_md  # noqa: E402 — plugin modules are imported from the source tree
from mdtext import code_span, code_fence  # noqa: E402 — plugin modules are imported from the source tree
from parse import parse, walk_text  # noqa: E402 — plugin modules are imported from the source tree
from qthtml import dialect, to_html, to_markdown  # noqa: E402 — plugin modules are imported from the source tree


class Files(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="note-note-files-")
        self.root = Path(self.work.name)
        self.note = self.root / "note.md"
        self.note.write_text("original", encoding="utf-8")

    def tearDown(self):
        self.work.cleanup()

    def operation(self, action, **payload):
        return operations.execute(dict(root=str(self.root), file=str(self.note), action=action, **payload))

    def test_empty_missing_refused_and_oversize_are_distinct(self):
        self.note.write_bytes(b"")
        self.assertEqual(readfile.read_document(self.note, 8)["text"], "")
        self.assertEqual(readfile.read_document(self.root / "missing", 8)["kind"], "missing")
        link = self.root / "link"
        link.symlink_to(self.note)
        self.assertIn("error", readfile.read_document(link, 8))
        self.note.write_text("漢" * 4, encoding="utf-8")
        result = readfile.read_document(self.note, 8)
        self.assertEqual(result["kind"], "too-large")
        self.assertNotIn("text", result)
        self.assertEqual(readfile.read_document(self.note, 12)["bytes"], 12)

    def test_invalid_utf8_is_not_an_editable_replacement(self):
        self.note.write_bytes(b"before\xffafter")
        self.assertEqual(readfile.read_document(self.note, 100)["kind"], "invalid-encoding")

    def test_failed_commit_preserves_original_and_cleans_temporary(self):
        with patch.object(fileio.os, "replace", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                fileio.write_atomic(self.note, "replacement")
        self.assertEqual(self.note.read_text(), "original")
        self.assertEqual(list(self.root.iterdir()), [self.note])

    def test_failed_create_delete_and_section_are_errors(self):
        with self.assertRaises(FileNotFoundError):
            fileio.write_atomic(self.root / "missing" / "note.md", "new")
        self.note.unlink()
        self.note.mkdir()
        with self.assertRaises(ValueError):
            self.operation("remove")
        (self.root / "occupied").write_text("existing file")
        with self.assertRaises(FileExistsError):
            self.operation("section", key="occupied")

    def test_save_and_delete_cannot_recreate_a_removed_note(self):
        self.operation("save", title="New", body="newest")
        self.assertIn("newest", self.note.read_text())
        self.operation("remove")
        with self.assertRaises(FileNotFoundError):
            self.operation("save", title="Old", body="stale")
        self.assertFalse(self.note.exists())

    def test_failed_image_copy_keeps_note_unchanged(self):
        with patch.object(images, "STAGING", str(self.root)):
            with self.assertRaises(OSError):
                self.operation("save", title="", body="![](file://" + str(self.root / "absent.png") + ")")
        self.assertEqual(self.note.read_text(), "original")

    def test_versions_distinguish_writes_within_one_second(self):
        os.utime(self.note, ns=(1_000_000_001, 1_000_000_001))
        first = readfile.read_document(self.note, 100)["version"]
        os.utime(self.note, ns=(1_000_000_002, 1_000_000_002))
        self.assertNotEqual(first, readfile.read_document(self.note, 100)["version"])
        result = subprocess.run([sys.executable, str(ROOT / "providers/local/list.py"), str(self.root), "10000"],
                                capture_output=True, text=True, check=True)
        self.assertIn("1000000002", result.stdout)

    def test_image_fifo_and_symlink_return_without_waiting(self):
        fifo = self.root / "image.png"
        os.mkfifo(fifo)
        script = "from qthtml.imagesize import width_of; import sys; print(width_of(sys.argv[1]))"
        env = dict(os.environ, PYTHONPATH=str(ROOT / "services/markdown"))
        result = subprocess.run([sys.executable, "-c", script, str(fifo)], env=env,
                                capture_output=True, text=True, timeout=2, check=True)
        self.assertEqual(result.stdout.strip(), "0")


class Content(unittest.TestCase):
    def test_notion_preserves_long_plain_styled_and_code_text(self):
        text = "漢" * 2101
        cases = [text, "**" + text + "**", code_span(text), "```\n" + text + "\n```"]
        for markdown in cases:
            with self.subTest(markdown=markdown[:12]):
                blocks = notion_md.markdown_to_blocks(markdown)
                notion_md.append_batches(blocks)
                rich = blocks[0][blocks[0]["type"]]["rich_text"]
                self.assertEqual("".join(item["text"]["content"] for item in rich), text)
                self.assertTrue(all(len(item["text"]["content"]) <= 2000 for item in rich))
                if rich[0].get("annotations"):
                    self.assertEqual(rich[0]["annotations"], rich[1]["annotations"])

    def test_notion_chunked_annotations_serialize_as_one_run(self):
        for annotation in ("code", "bold", "italic"):
            rich = [{"plain_text": "a" * 2000, "annotations": {annotation: True}},
                    {"plain_text": "b", "annotations": {annotation: True}}]
            markdown = notion_md.rich_to_md(rich)
            self.assertEqual(walk_text(parse(markdown)), "a" * 2000 + "b")

    def test_notion_preserves_links_across_chunks(self):
        rich = notion_md.text_items("a" * 2001, {"bold": True}, "https://example.com")
        self.assertEqual(rich[0]["text"]["link"], rich[1]["text"]["link"])
        with self.assertRaises(ValueError):
            notion_md.text_items("a", link="x" * 2001)

    def test_notion_rejects_unrepresentable_payload_before_mutation(self):
        import notion
        calls = []
        payload = {"title": "changed", "body": "a" * 200001}
        with patch.object(notion, "read_payload", return_value=payload), \
             patch.object(notion, "api", side_effect=lambda *a, **kw: calls.append(a)), \
             patch.object(notion, "fail", side_effect=ValueError):
            with self.assertRaises(ValueError):
                notion.cmd_update("page", "-")
        self.assertEqual(calls, [])
        with self.assertRaises(ValueError):
            notion_md.validate_payload({"children": [{"type": "divider", "divider": {}}] * 101})

    def test_markdown_code_delimiters_preserve_literal_backticks(self):
        for value in ("a`b", "`edge`", "a``b", " a "):
            markdown = code_span(value)
            saved = to_markdown(to_html(markdown))
            self.assertEqual(walk_text(parse(saved)), value)
        value = "first\n```\nlast"
        fence = code_fence(value)
        saved = to_markdown(to_html(fence + "\n" + value + "\n" + fence))
        self.assertEqual(parse(saved)[0]["raw"], value + "\n")

    def test_literal_highlight_markers_are_escaped_on_fallback(self):
        self.assertEqual(walk_text(parse(to_markdown("<p>==literal==</p>"))), "==literal==")

    def test_document_dialect_agrees_across_adapters(self):
        js = (ROOT / "ui/Dialect.js").read_text()
        for name in ("QUOTE_PX", "CODE_PAD_PX", "MAX_IMAGE_DISPLAY", "LINE_HEIGHT_PCT"):
            match = re.search(r"var " + name + r" = (\d+)", js)
            self.assertIsNotNone(match, name)
            self.assertEqual(int(match[1]), getattr(dialect, name), name)
        native = (ROOT / "cpp/textblocks.h").read_text()
        self.assertEqual(int(re.search(r"constexpr qreal percent = (\d+)", native)[1]), dialect.LINE_HEIGHT_PCT)


if __name__ == "__main__":
    unittest.main()
