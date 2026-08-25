"""Round-trip tests for the editor's document format.

The property that matters is not that a conversion looks right, but that the
loop closes:

    markdown -> to_html -> [Qt's document] -> to_markdown -> markdown

Anything Qt rewrites on the way through shows up here as a diff. The Qt leg
runs the offscreen QML runtime, so this needs no shell and no display; it is
skipped with a warning when `qml6` is missing.

    python3 services/markdown/qthtml/selftest.py [--verbose]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from qthtml import convert, to_html, to_markdown  # noqa: E402

# Each case is a note as it would sit on disk. The awkward ones are here
# because Qt's *Markdown* writer used to corrupt them (docs/engine-notes.md);
# they are the reason the editor moved to rich text.
CASES = {
    "headings": "# One\n\n## Two\n\n### Three\n",
    "inline": "para **b** *i* _u_ ~~s~~ ==hi== `c` [l](http://x)\n",
    "heading with formatting": "## Head with ==mark== and *italic*\n",
    "heading with bold": "## Head with **bold** inside\n",
    "heading with a link": "### See [the docs](https://example.com)\n",
    "quote with formatting": "> quoted **bold** and ==mark==\n",
    "item with a link": "- [ ] read [the docs](https://example.com) **today**\n",
    "long paragraph": (
        "This is a fairly long paragraph of ordinary prose that runs well past eighty "
        "columns, because Qt's Markdown writer used to fold it into two.\n"),
    "escapes": "a - b # c 1. d * e\n",
    "lists": "- bullet\n  - nested\n- second\n",
    "ordered": "1. first\n2. second\n",
    "checkboxes": "- [ ] todo\n- [x] done\n",
    "empty checkbox": "- [ ] \n- [x] done\n",
    "quote": "> quoted line\n",
    "quote then table": "> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |\n",
    "code block": "```\ncode = 1\ncode = 2\n```\n",
    "code after quote": "> quoted\n\n```\nx = 1\n```\n",
    "table": "| a | b |\n|---|---|\n| 1 | 2 |\n",
    "rule": "---\n",
    "blank line": "one\n\n \n\ntwo\n",
    "indent": "plain\n\n    indented once\n",
    "highlight in bold": "**bold with ==highlight== inside**\n",
    "link with text": "see [the docs](https://example.com/a%29b)\n",
    "link in bold": "**see [the docs](https://example.com)**\n",
    "link in a list": "- see [docs](https://example.com)\n- plain\n",
    "formatting in a cell": "| a | b |\n|---|---|\n| **bold** | ==hi== |\n",
    "formatting in an item": "- **bold** item\n- [x] ==done== well\n",
    "nested emphasis": "**bold with *italic* inside**\n",
    "two indents": "plain\n\n\u00a0\u00a0\u00a0\u00a0one\n\n\u00a0\u00a0\u00a0\u00a0\u00a0\u00a0\u00a0\u00a0two\n",
    "arithmetic": "2 * 3 = 6 and 4 _ 5\n",
    "snake case": "call user_name_field and other_thing\n",
    "hash and dash": "a #tag and a - dash mid sentence\n",
    "html-ish text": "a \\<div> tag & an ampersand\n",
    "unicode": "caf\u00e9 \u2014 \u4e2d\u6587 \u2713 \U0001f600\n",
    "deep list": "- one\n  - two\n    - three\n",
    "mixed list": "1. first\n2. second\n\n- bullet\n",
    "hard break": "line one  \nline two\n",
    "image": "![a picture](file:///tmp/note-note-test.png)\n",
    "image between text": "before\n\n![](file:///tmp/note-note-test.png)\n\nafter\n",
    "image with a remote url": "![shot](https://graph.microsoft.com/v1.0/me/onenote/resources/abc/$value)\n",
    "image opening a list item": "- item\n- ![pic](file:///tmp/note-note-test.png) after\n- last\n",
    "linked image opening a list item": "- item\n- [![pic](file:///tmp/note-note-test.png)](https://example.com) after\n- last\n",
    "long note": (
        "# Shopping\n\nBuy these **today**:\n\n- [ ] milk\n- [x] eggs\n- [ ] bread\n\n"
        "> remember the ==coupon==\n\n| item | qty |\n|---|---|\n| apples | 3 |\n\n"
        "```\ntotal = 12\n```\n\nSee [the list](https://example.com/list).\n"),
}

# Two paths run here, because the app has two:
#   saved  — our HTML into the document, straight back out. Every save.
#   reread — the document handed its own HTML again, as a toolbar action does.
#            Qt's fragment markers are stripped first (see dialect); without
#            that the first block of the note silently loses its format.
QML_TEMPLATE = """
import QtQuick
Window {
  visible: true
  TextEdit { id: e; textFormat: TextEdit.RichText; font.family: "sans-serif"; width: 600 }
  function strip(html) { return html.replace(/<!--(Start|End)Fragment-->/g, "") }
  Timer { interval: 60; running: true; onTriggered: {
    var cases = %s, out = {}
    for (var key in cases) {
      e.text = cases[key]
      var saved = e.getFormattedText(0, e.length)
      e.text = strip(saved)
      var reread = e.getFormattedText(0, e.length)
      e.text = strip(reread)
      // How Qt itself counts blocks: a paragraph separator starts one, and so
      // does each table cell (docs/engine-notes.md).
      e.text = strip(saved)
      var plain = e.getText(0, e.length), blocks = 1
      for (var i = 0; i < plain.length; i++)
        if (plain.charCodeAt(i) === 0x2029 || plain.charCodeAt(i) === 0xFDD0) blocks++
      out[key] = { saved: saved, reread: reread, blocks: blocks,
                   stable: strip(reread) === strip(e.getFormattedText(0, e.length)) }
    }
    console.error("<<<RESULT>>>" + JSON.stringify(out) + "<<<END>>>")
    Qt.exit(0)
  } }
}
"""


def through_qt(documents):
    """{name: html} -> {name: {html, fixpoint}} as Qt itself rewrites them."""
    script = QML_TEMPLATE % json.dumps(documents)
    with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False) as handle:
        handle.write(script)
        path = handle.name
    try:
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
        proc = subprocess.run(["qml6", path], capture_output=True, text=True, timeout=120, env=env)
    finally:
        os.unlink(path)
    blob = proc.stderr.split("<<<RESULT>>>")
    if len(blob) < 2:
        raise RuntimeError("no result from qml6:\n" + proc.stderr[-2000:])
    return json.loads(blob[1].split("<<<END>>>")[0])


def report(name, stage, expected, actual, verbose):
    print("  FAIL  %-18s (%s)" % (name, stage))
    if verbose:
        print("        expected: %r" % expected)
        print("        actual:   %r" % actual)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    failures = 0
    print("pure round-trip (markdown -> html -> markdown)")
    documents = {}
    for name, markdown in CASES.items():
        html = to_html(markdown)
        documents[name] = html
        back = to_markdown(html)
        if back.strip() != markdown.strip():
            failures += 1
            report(name, "pure", markdown, back, args.verbose)
    print("  %d/%d cases" % (len(CASES) - failures, len(CASES)))

    print("through Qt (markdown -> html -> document -> html -> markdown)")
    try:
        rendered = through_qt(documents)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("  SKIPPED: %s" % error)
        return 1 if failures else 0

    qt_failures = 0
    for name, markdown in CASES.items():
        result = rendered.get(name)
        if not result:
            qt_failures += 1
            report(name, "qt", markdown, None, args.verbose)
            continue
        if not result["stable"]:
            qt_failures += 1
            report(name, "document fixpoint", "stable html", "unstable", args.verbose)
        for stage in ("saved", "reread"):
            back = to_markdown(result[stage])
            if back.strip() != markdown.strip():
                qt_failures += 1
                report(name, stage, markdown, back, args.verbose)

        # The caret map is only useful if it counts blocks the way Qt does.
        counted = convert(result["saved"])["count"]
        if counted != result["blocks"]:
            qt_failures += 1
            report(name, "block map", "%d blocks" % result["blocks"], "%d mapped" % counted, args.verbose)
    print("  %d/%d cases" % (len(CASES) - qt_failures, len(CASES)))

    total = failures + qt_failures
    print("\n%s" % ("all green" if not total else "%d failure(s)" % total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
