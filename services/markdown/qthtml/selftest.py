"""Round-trip tests for the editor's document format.

The property that matters is not that a conversion looks right, but that the
loop closes:

    markdown -> to_html -> [Qt's document] -> to_markdown -> markdown

Anything Qt rewrites on the way through shows up here as a diff. The Qt leg
runs the offscreen QML runtime, so this needs no shell and no display; it is
requires `qml6`; a missing runtime fails the suite.

    python3 services/markdown/qthtml/selftest.py [--verbose]
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from qthtml import convert, dialect, to_html, to_markdown  # noqa: E402

# Each case is a note as it would sit on disk. The awkward ones are here
# because Qt's *Markdown* writer used to corrupt them (docs/engine-notes.md);
# they are the reason the editor moved to rich text.
CASES = {
    "text color": '<span style="color:#0070c0;">Mushrooms</span>\n',
    "color in checklist": '- [x] <span style="color:#0070c0;">Mushrooms</span>\n- [ ] Milk\n',
    "color with formatting": '<span style="color:#ff0000;">**bold** and *italic* and ==mark==</span>\n',
    "color in heading": '# <span style="color:#0070c0;">Heading</span>\n',
    "color in quote": '> <span style="color:#0070c0;">Quote</span>\n',
    "color in table": '| A | B |\n|---|---|\n| <span style="color:#0070c0;">Blue</span> | plain |\n',
    "color in link": '<span style="color:#0070c0;">[link](https://example.com)</span>\n',
    "color in code span": '<span style="color:#0070c0;">`code`</span>\n',
    "adjacent colors": '<span style="color:#ff0000;">red</span><span style="color:#0070c0;">blue</span>\n',
    "color equal to link decoration": '<span style="color:#4282d7;">[link](https://example.com)</span>\n',
    "color equal to quote decoration": '> <span style="color:#9399b2;">Quote</span>\n',
    "color equal to highlight ink": '<span style="color:#1e1e2e;">==mark==</span>\n',
    "literal color HTML in code": '`<span style="color:red;">long</span>`\n',

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
    "code in ordered items": (
        "1. **Install driver:**\n\n"
        "   ```\n   install-driver --needed\n   enable-service\n   ```\n"
        "2. **Configure token:**\n\n"
        "   ```\n   name=Token\n\n   slotListIndex=0\n   ```\n"
        "3. **Sign:**\n\n   Open the PDF.\n\n   Press **Sign**.\n"),
    "code in bullet item": "- Run:\n\n  ```\n  echo one\n  echo two\n  ```\n- Done\n",
    "code in checkbox item": "- [x] Run:\n\n  ```\n  echo done\n  ```\n- [ ] Next\n",
    "nested code continuation": (
        "- outer\n  - inner\n\n    ```\n    echo inner\n    ```\n\n"
        "    inner after\n\n  outer after\n- last\n"),
    "ordered nested code": (
        "9. outer\n   - inner\n\n     ```\n     echo inner\n     ```\n"
        "10. next\n\n    ```\n    echo next\n    ```\n"),
    "paragraphs around nested list": (
        "- first\n\n  before\n  - child\n\n  after\n- second\n"),
    "list item hard break": "- first  \n  second\n- next\n",
    "code with literal fence in item": "- Run:\n\n  ````\n  before\n  ```\n  after\n  ````\n",
    "indented code in item": "- Run:\n\n  ```\n  if ready:\n      run()\n  ```\n",
    "code opening item": "- ```\n  echo hello\n  ```\n",
    "nested code at end": "- parent\n  - child\n\n    ```\n    echo child\n    ```\n",
    "quote and heading in item": "- Title\n\n  > quote\n\n  ## Heading\n- end\n",
    "checkboxes": "- [ ] todo\n- [x] done\n",
    "empty checkbox": "- [ ] \n- [x] done\n",
    "quote": "> quoted line\n",
    "quote then table": "> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |\n",
    "code block": "```\ncode = 1\ncode = 2\n```\n",
    "code with a blank line": "```\na = 1\n\nb = 2\n```\n",
    "empty code block": "```\n\n```\n",
    "inline code alone": "`x`\n",
    "quote of inline code": "> `x = 1`\n",
    "code after quote": "> quoted\n\n```\nx = 1\n```\n",
    "table": "| a | b |\n|---|---|\n| 1 | 2 |\n",
    "table with empty cells": "| a |  |\n|---|---|\n|  | 2 |\n",
    "nested table": (
        "<table><tr><td><p>Outer</p></td><td><p>Neighbour</p></td></tr><tr><td><p>before</p>"
        "<table><tr><td><p>Inner</p></td><td><p>Value</p></td></tr>"
        "<tr><td><p></p></td><td><p>2</p></td></tr></table><p>after</p>"
        "</td><td><p>untouched</p></td></tr></table>\n"),
    "nested table in empty cell": (
        "<table><tr><td><p>Outer</p></td></tr><tr><td>"
        "<table><tr><td><p>Inner</p></td></tr><tr><td><p></p></td></tr></table>"
        "</td></tr></table>\n"),
    "three table levels": (
        "<table><tr><td><p>One</p></td></tr><tr><td>"
        "<table><tr><td><p>Two</p></td></tr><tr><td>"
        "<table><tr><td><p>Three</p></td></tr><tr><td><p>deep</p></td></tr></table>"
        "</td></tr></table></td></tr></table>\n"),
    "nested table inline formatting": (
        "<table><tr><td><p><strong>Outer</strong></p></td></tr><tr><td>"
        '<p><em>before</em> <u>underlined</u> <a href="https://example.com/?a=1&amp;b=2">link</a></p>'
        "<table><tr><td><p><code>a|b</code></p></td></tr><tr><td><p><mark>marked</mark></p></td></tr></table>"
        "<p>after &lt;literal&gt; &amp; text</p></td></tr></table>\n"),
    "rule": "---\n",
    "blank line": "one\n\n \n\ntwo\n",
    "indent": "plain\n\n    indented once\n",
    "highlight in bold": "**bold with ==highlight== inside**\n",
    "link with text": "see [the docs](https://example.com/a%29b)\n",
    "link in bold": "**see [the docs](https://example.com)**\n",
    "link in a list": "- see [docs](https://example.com)\n- plain\n",
    "bare URL after a linked item": "- [First](https://example.com/first)\n- https://example.org/second?q=one&n=2\n",
    "bare URL punctuation": "See (https://example.com/a(b)). Next\n",
    "formatting in a cell": "| a | b |\n|---|---|\n| **bold** | ==hi== |\n",
    "formatting in an item": "- **bold** item\n- [x] ==done== well\n",
    "highlight in an unchecked item": "- [ ] Build an ==Omarchy== plugin\n- [ ] Ship it\n",
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
    "image with a width": "![a picture](file:///tmp/note-note-test.png){width=320}\n",
    "sized image between text": "before\n\n![](file:///tmp/note-note-test.png){width=200}\n\nafter\n",
    "sized image in a list": "- item\n- ![pic](file:///tmp/note-note-test.png){width=120} after\n- last\n",
    "sized relative image": "![shot](.assets/paste-1.png){width=240}\n",
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
import "__DIALECT_URL__" as Dialect
Window {
  visible: true
  TextEdit { id: e; textFormat: TextEdit.RichText; font.family: "sans-serif"; width: 600 }
  function strip(html) {
    return Dialect.documentHtml(html)
  }
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
    script = (QML_TEMPLATE % json.dumps(documents)).replace(
        "__DIALECT_URL__", (Path(__file__).resolve().parents[3] / "ui/Dialect.js").as_uri())
    with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False) as handle:
        handle.write(script)
        path = handle.name
    try:
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
        proc = subprocess.run(["qml6", path], capture_output=True, text=True, timeout=120, env=env)
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        raise RuntimeError("qml6 failed (%s):\n%s" % (proc.returncode, proc.stderr[-2000:]))
    blob = proc.stderr.split("<<<RESULT>>>")
    if len(blob) < 2:
        raise RuntimeError("no result from qml6:\n" + proc.stderr[-2000:])
    return json.loads(blob[1].split("<<<END>>>")[0])


def check_display_cap(verbose):
    """The display cap is display only (dialect.MAX_IMAGE_DISPLAY): a large
    image with no stated width gets it on the way in and loses it on the way
    out, while a width the author stated survives — even through a rename of
    the same number onto a small image. Needs a real file, so it lives here
    rather than in CASES (only the PNG header matters to width_of)."""
    failures = 0
    with tempfile.TemporaryDirectory() as directory:
        big = os.path.join(directory, "big.png")
        with open(big, "wb") as handle:
            handle.write(b"\x89PNG\r\n\x1a\n" + b"\0" * 8 + struct.pack(">II", 800, 600))
        cases = [
            # (name, markdown, html must contain, must read back as)
            ("cap applied", "![shot](file://%s)\n" % big,
             ' width="%d"' % dialect.MAX_IMAGE_DISPLAY, "![shot](file://%s)\n" % big),
            ("author width kept", "![shot](file://%s){width=300}\n" % big,
             ' width="300"', "![shot](file://%s){width=300}\n" % big),
            ("cap through a base", "![shot](big.png)\n",
             ' width="%d"' % dialect.MAX_IMAGE_DISPLAY, "![shot](big.png)\n"),
        ]
        for name, markdown, contains, back in cases:
            html = to_html(markdown, base=directory)
            if contains not in html:
                failures += 1
                report(name, "cap html", contains, html, verbose)
            elif to_markdown(html, base=directory) != back:
                failures += 1
                report(name, "cap markdown", back, to_markdown(html, base=directory), verbose)
    print("display cap (large image, no stated width)")
    print("  %d/3 cases" % (3 - failures))
    return failures


def check_code_chip(verbose):
    """The chip behind inline code (--code-chip) is display only: the writer
    states it beside the mono family, and `reader` answers the backticks
    before it ever looks at a background — so the colour never reaches the
    note, and is never mistaken for a highlight. Transparent (the default)
    writes no background at all."""
    failures = 0
    markdown = "`x` in ==lit== prose\n"
    chipped = to_html(markdown, code_chip="#2a2c3c")
    if "font-family:'%s'; background-color:#2a2c3c;" % dialect.MONO_FAMILY not in chipped:
        failures += 1
        report("chip stated", "chip html", "mono span with #2a2c3c", chipped, verbose)
    if to_markdown(chipped).strip() != markdown.strip():
        failures += 1
        report("chip never read back", "chip markdown", markdown, to_markdown(chipped), verbose)
    if "background-color" in to_html("`x` alone\n"):
        failures += 1
        report("no chip by default", "chip html", "no background", to_html("`x` alone\n"), verbose)
    print("code chip (inline code with --code-chip)")
    print("  %d/3 cases" % (3 - failures))
    return failures


def check_typed_filler(verbose):
    """Typing into a blank line lands in front of its U+00A0 filler (the
    editor keeps the caret there — NoteEditor.normalizeNow), so the filler
    trails the typed text and must come off on the way out — while a blank
    line alone, and a leading indent run, stay exactly what they are.
    Hand-made HTML, because to_html never writes a filler beside text."""
    failures = 0
    cases = [
        ("typed before the filler", "<p>x\u00a0</p>", "x\n"),
        ("a blank line stays blank", "<p>\u00a0</p><p>after</p>", "\u00a0\n\nafter\n"),
        ("an indent is not a filler", '<p style="margin-left:36px">x</p>', "\u00a0" * 4 + "x\n"),
    ]
    for name, html, back in cases:
        actual = to_markdown(html)
        if actual != back:
            failures += 1
            report(name, "typed filler", back, actual, verbose)
    print("typed-beside-filler (a blank line's U+00A0 with text typed into it)")
    print("  %d/%d cases" % (len(cases) - failures, len(cases)))
    return failures


def check_as_text(verbose):
    """`as_text` reads one code block as paragraphs — the code block tool
    toggling off. Each line keeps its block, so the caret map is unchanged
    in shape; the text comes out escaped the way any paragraph's is, an
    empty line as the dialect's blank; and a code block elsewhere in the
    note stays a fence."""
    failures = 0
    cases = [
        ("lines become paragraphs", "```\na = 1\n\nb = 2\n```\n", 1,
         {"markdown": "a = 1\n\n\u00a0\n\nb = 2\n", "blocks": [0, -1, 1, -1, 2], "count": 3}),
        ("the text is escaped", "```\n# not a heading\n*x* and `y`\n```\n", 0,
         {"markdown": "\\# not a heading\n\n\\*x\\* and \\`y\\`\n",
          "blocks": [0, -1, 1], "count": 2}),
        ("only the block's own fence opens", "```\nfirst\n```\n\npara\n\n```\nsecond\n```\n", 2,
         {"markdown": "```\nfirst\n```\n\npara\n\nsecond\n",
          "blocks": [-1, 0, -1, -1, 1, -1, 2], "count": 3}),
        ("an empty block becomes a blank", "```\n\n```\n", 0,
         {"markdown": "\u00a0\n", "blocks": [0], "count": 1}),
        ("code stays in its list item", "- Run\n\n  ```\n  a = 1\n\n  b = 2\n  ```\n- Done\n", 2,
         {"markdown": "- Run\n\n  a = 1\n\n  \u00a0\n\n  b = 2\n- Done\n",
          "blocks": [0, -1, 1, -1, 2, -1, 3, 4], "count": 5}),
        ("a block outside any code is a plain read", "para\n\n```\ncode\n```\n", 0,
         convert(to_html("para\n\n```\ncode\n```\n"))),
    ]
    for name, markdown, block, expected in cases:
        actual = convert(to_html(markdown), as_text=block)
        if actual != expected:
            failures += 1
            report(name, "as text", expected, actual, verbose)
    print("as text (one code block read as paragraphs)")
    print("  %d/%d cases" % (len(cases) - failures, len(cases)))
    return failures


def check_command_line(verbose):
    """The frame Markdown.qml reads: one JSON object per run, both directions.

    Markdown.qml parses stdout and treats anything that does not parse as a
    failed conversion, so the contract worth pinning is the shape of what
    __main__.py writes — an empty note is `{"html": ""}`, never nothing — and
    that a bad invocation writes nothing parseable at all.
    """
    main_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "__main__.py")

    def run(args, payload):
        proc = subprocess.run([sys.executable, main_py] + args, input=payload,
                              capture_output=True, timeout=60)
        return proc.returncode, proc.stdout.decode("utf-8", "replace")

    failures = 0
    cases = [
        ("to-html frames the note", ["to-html"], b"# x\n", {"html": to_html("# x\n")}),
        ("to-html frames an empty note", ["to-html"], b"", {"html": ""}),
        ("to-markdown answers with its map", ["to-markdown"], to_html("- a\n").encode("utf-8"),
         convert(to_html("- a\n"))),
        ("to-markdown reads a block as text", ["to-markdown", "--as-text", "0"],
         to_html("```\nx\n```\n").encode("utf-8"), convert(to_html("```\nx\n```\n"), as_text=0)),
    ]
    for name, args, payload, expected in cases:
        code, out = run(args, payload)
        try:
            actual = json.loads(out)
        except ValueError:
            actual = None
        if code != 0 or actual != expected:
            failures += 1
            report(name, "command line", expected, actual, verbose)
    bad = [("a bad invocation writes nothing", ["to-html", "--no-such-option"]),
           ("a bad block index writes nothing", ["to-markdown", "--as-text", "x"])]
    for name, args in bad:
        code, out = run(args, b"x")
        if code == 0 or out.strip():
            failures += 1
            report(name, "command line", "non-zero exit, empty stdout", (code, out), verbose)
    print("command line (the JSON frame Markdown.qml reads)")
    print("  %d/%d cases" % (len(cases) + len(bad) - failures, len(cases) + len(bad)))
    return failures


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

    failures += check_display_cap(args.verbose)
    failures += check_code_chip(args.verbose)
    failures += check_typed_filler(args.verbose)
    failures += check_as_text(args.verbose)
    failures += check_command_line(args.verbose)

    # The chip rides through Qt too: the span must keep both halves — the
    # family that means code and the colour that shows it — and still read
    # back as bare backticks.
    documents["inline code chip"] = to_html("`x` in prose\n", code_chip="#2a2c3c")

    print("through Qt (markdown -> html -> document -> html -> markdown)")
    try:
        rendered = through_qt(documents)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("  FAILED: %s" % error)
        return 1

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

    chip = rendered.get("inline code chip")
    if not chip or "background-color:#2a2c3c" not in chip["saved"]:
        qt_failures += 1
        report("inline code chip", "chip through qt", "chip kept on the span",
               chip and chip["saved"], args.verbose)
    elif any(to_markdown(chip[stage]).strip() != "`x` in prose" for stage in ("saved", "reread")):
        qt_failures += 1
        report("inline code chip", "chip through qt", "`x` in prose",
               to_markdown(chip["saved"]), args.verbose)
    print("  %d/%d cases" % (len(CASES) + 1 - qt_failures, len(CASES) + 1))

    total = failures + qt_failures
    print("\n%s" % ("all green" if not total else "%d failure(s)" % total))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
