"""Agreement test for the two ways the editor finds quote blocks and
checkbox items — and the inspector's image side, which has no fallback to
agree with and is asserted against the document directly.

The native inspector (textblocks.h) reads block formats from the document;
the fallback (ui/QuoteBars.js) scans the document's serialised HTML. Both
must place the same bars, or a machine without the built library sees
different decorations than one with it. Every round-trip case from the
converter's selftest runs through a real Qt document offscreen, and the two
answers are compared — the exact JS shipped in ui/QuoteBars.js, not a copy.

The image phase loads a real PNG into a document, asserts `images()` sees
its natural size and the display cap the converter applied, resizes it with
`setImageWidth()`, and closes the loop: the document's own HTML must read
back as `![alt](src){width=N}`.

The table-gap phase presses a real Return (QtTest) at the end of a list
sitting above a table — baring the block Qt hides — and asserts
`fillEmptyBlocksBeforeTables()` gives the caret's row its height back with
one filler, undone together with the split (docs/engine-notes.md).

    sh cpp/build.sh
    python3 cpp/selftest.py [--verbose]

Skipped with a warning when the library is not built or `qml6` is missing.
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services", "markdown"))
from qthtml import dialect, to_html, to_markdown  # noqa: E402
from qthtml.selftest import CASES     # noqa: E402

MODULE = os.path.join(ROOT, "cpp", "build", "NoteNoteText")
QUOTEBARS = os.path.join(ROOT, "ui", "QuoteBars.js")

QML_TEMPLATE = """
import QtQuick
import QtTest
import "%(module)s"
import "%(quotebars)s" as QuoteBars
Window {
  visible: true
  property var out: ({})
  TextEdit { id: e; textFormat: TextEdit.RichText; font.family: "sans-serif"; width: 600 }
  TextBlocks { id: tb; document: e.textDocument }
  TestCase { id: tc; name: "selftest"; when: windowShown }
  // The caret row's clearance under the table: the first cell's top minus
  // the caret line's bottom — negative while the table is drawn over it.
  function rowGap() {
    var t = e.getText(0, e.length), i = 0
    while (i < t.length && t.charCodeAt(i) !== 0xFDD0) i++
    var cur = e.positionToRectangle(e.cursorPosition)
    return e.positionToRectangle(i + 1).y - (cur.y + cur.height)
  }
  Timer { interval: 60; running: true; onTriggered: {
    var cases = %(cases)s
    for (var key in cases) {
      e.text = cases[key]
      out[key] = {
        native: QuoteBars.runsFromBlocks(tb.blocks()),
        scanned: QuoteBars.runs(e.getFormattedText(0, e.length), e.getText(0, e.length)),
        boxesNative: QuoteBars.boxesFromBlocks(tb.blocks()),
        boxesScanned: QuoteBars.boxes(e.getFormattedText(0, e.length), e.getText(0, e.length))
      }
    }
    // The image phase reads on a second tick, giving the document's
    // resource loading time to settle before natural sizes are asked for.
    e.text = %(imagehtml)s
  } }
  Timer { interval: 400; running: true; onTriggered: {
    var img = { before: tb.images() }
    if (img.before.length === 1) {
      img.applied = tb.setImageWidth(img.before[0].position, 300)
      img.after = tb.images()
      img.html = e.getFormattedText(0, e.length)
    }
    out.images = img
    // The table-gap phase: Enter at the list's end bares a block Qt hides,
    // the filler must give the row back, and one undo must take the row and
    // its filler out together (textblocks.h, fillEmptyBlocksBeforeTables).
    e.text = %(gaphtml)s
    e.forceActiveFocus()
    e.cursorPosition = e.getText(0, e.length).indexOf("three") + 5
    var gap = { lenBefore: e.length }
    tc.keyClick(Qt.Key_Return)
    gap.bared = rowGap()
    gap.filled = tb.fillEmptyBlocksBeforeTables()
    gap.fixed = rowGap()
    gap.filler = gap.filled < 0 ? "" : e.getText(gap.filled, gap.filled + 1)
    e.undo()
    gap.lenUndone = e.length
    out.tableGap = gap
    // The line-height phase: a note opened empty holds the one block the
    // writer never styled; typing into it stays at Qt's default until
    // normalizeLineHeights restores the dialect's value (textblocks.h).
    e.text = ""
    e.forceActiveFocus()
    tc.keyClick(Qt.Key_X)
    var lh = { typed: e.getFormattedText(0, e.length) }
    tb.normalizeLineHeights()
    lh.normalized = e.getFormattedText(0, e.length)
    out.lineHeight = lh
    console.error("<<<RESULT>>>" + JSON.stringify(out) + "<<<END>>>")
    Qt.exit(0)
  } }
}
"""

# The list whose last item sits right above a table — the shape Enter bares
# a hidden block in (docs/engine-notes.md).
GAP_MARKDOWN = "1. one\n2. two\n3. three\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"


def make_png(path, width, height):
    """A small but real PNG, so the document can load and measure it."""
    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + b"\x80\x80\x80" * width for _ in range(height))
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def has_quote(markdown):
    """Whether the note holds a quote — fences skipped, code is not a quote."""
    fence = False
    for line in markdown.split("\n"):
        if line.strip().startswith("```"):
            fence = not fence
        elif not fence and line.startswith("> "):
            return True
    return False


def has_code(markdown):
    """Whether the note holds a fenced code block."""
    return "```" in markdown


def box_states(markdown):
    """The note's checkboxes in document order, True for a checked one —
    fences skipped, a `- [x]` inside code is text."""
    out, fence = [], False
    for line in markdown.split("\n"):
        stripped = line.strip()
        if stripped.startswith("```"):
            fence = not fence
            continue
        if (not fence and stripped[:5] in ("- [ ]", "- [x]", "- [X]")
                and (len(stripped) == 5 or stripped[5] == " ")):
            out.append(stripped[3].lower() == "x")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if not os.path.isdir(MODULE):
        print("SKIPPED: %s not built (sh cpp/build.sh)" % MODULE)
        return 0

    documents = {name: to_html(markdown) for name, markdown in CASES.items()}
    png_dir = tempfile.mkdtemp(prefix="note-note-selftest-")
    png = os.path.join(png_dir, "shot.png")
    make_png(png, 800, 600)
    image_markdown = "![shot](file://%s)\n" % png
    script = QML_TEMPLATE % {"module": "file://" + MODULE,
                             "quotebars": "file://" + QUOTEBARS,
                             "cases": json.dumps(documents),
                             "imagehtml": json.dumps(to_html(image_markdown)),
                             "gaphtml": json.dumps(to_html(GAP_MARKDOWN))}
    with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False) as handle:
        handle.write(script)
        path = handle.name
    try:
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
        proc = subprocess.run(["qml6", path], capture_output=True, text=True, timeout=120, env=env)
    except (OSError, subprocess.SubprocessError) as error:
        print("SKIPPED: %s" % error)
        return 0
    finally:
        os.unlink(path)
        os.unlink(png)
        os.rmdir(png_dir)
    blob = proc.stderr.split("<<<RESULT>>>")
    if len(blob) < 2:
        print("FAILED to run qml6:\n" + proc.stderr[-2000:])
        return 1
    results = json.loads(blob[1].split("<<<END>>>")[0])

    failures = 0
    print("native block formats vs the HTML scan")
    for name, markdown in CASES.items():
        result = results.get(name, {})
        native, scanned = result.get("native"), result.get("scanned")
        boxes_native, boxes_scanned = result.get("boxesNative"), result.get("boxesScanned")
        if native != scanned:
            failures += 1
            print("  FAIL  %-24s native %r != scanned %r" % (name, native, scanned))
        elif has_quote(markdown) != bool(native["quote"]):
            failures += 1
            print("  FAIL  %-24s markdown %s a quote, found %r"
                  % (name, "holds" if has_quote(markdown) else "holds no", native["quote"]))
        elif has_code(markdown) != bool(native["code"]):
            failures += 1
            print("  FAIL  %-24s markdown %s a code block, found %r"
                  % (name, "holds" if has_code(markdown) else "holds no", native["code"]))
        elif boxes_native != boxes_scanned:
            failures += 1
            print("  FAIL  %-24s native boxes %r != scanned %r" % (name, boxes_native, boxes_scanned))
        elif [box["checked"] for box in boxes_native] != box_states(markdown):
            failures += 1
            print("  FAIL  %-24s markdown holds boxes %r, found %r"
                  % (name, box_states(markdown), boxes_native))
        elif args.verbose and (native["quote"] or native["code"] or boxes_native):
            print("  ok    %-24s %r %r" % (name, native, boxes_native))
    print("  %d/%d cases" % (len(CASES) - failures, len(CASES)))

    print("images: natural size, the display cap, and the corner-handle resize")
    image_failures = check_images(results.get("images") or {}, image_markdown, args.verbose)
    failures += image_failures
    print("  %s" % ("ok" if not image_failures else "%d failure(s)" % image_failures))

    print("table gap: the filler under a list split above a table")
    gap_failures = check_table_gap(results.get("tableGap") or {}, args.verbose)
    failures += gap_failures
    print("  %s" % ("ok" if not gap_failures else "%d failure(s)" % gap_failures))

    print("line height: typing into a note opened empty")
    height_failures = check_line_height(results.get("lineHeight") or {}, args.verbose)
    failures += height_failures
    print("  %s" % ("ok" if not height_failures else "%d failure(s)" % height_failures))

    print("\n%s" % ("all green" if not failures else "%d failure(s)" % failures))
    return 1 if failures else 0


def check_images(result, image_markdown, verbose):
    """One 800x600 PNG through the whole loop: `images()` must see the
    natural size and the converter's display cap; `setImageWidth(300)` must
    stick, scale the height by the aspect, and read back from the document's
    own HTML as the note's `{width=300}`."""
    checks = []
    before, after = result.get("before") or [], result.get("after") or []
    checks.append(("one image found", len(before) == 1, before))
    if len(before) == 1:
        img = before[0]
        checks.append(("natural size", (img["naturalWidth"], img["naturalHeight"]) == (800, 600), img))
        checks.append(("display cap applied", img["width"] == dialect.MAX_IMAGE_DISPLAY, img))
        checks.append(("height follows the aspect", img["height"] == 480, img))
        checks.append(("bottom on the baseline", img["ascent"] >= img["height"], img))
        checks.append(("resize applied", result.get("applied") is True, result.get("applied")))
    if len(after) == 1:
        checks.append(("resized width", after[0]["width"] == 300, after[0]))
        checks.append(("resized height by aspect", after[0]["height"] == 225, after[0]))
        back = to_markdown(result.get("html") or "")
        expected = image_markdown.replace(")\n", "){width=300}\n")
        checks.append(("reads back as the note's width", back == expected, back))
    failures = 0
    for name, ok, actual in checks:
        if not ok:
            failures += 1
            print("  FAIL  %-28s %r" % (name, actual))
        elif verbose:
            print("  ok    %-28s" % name)
    return failures


def check_table_gap(result, verbose):
    """Enter at the end of a list right above a table bares a block Qt then
    hides, drawing the table over the caret's row (docs/engine-notes.md).
    `fillEmptyBlocksBeforeTables()` must put the dialect's blank filler in,
    give the row its height back, and join the edit — one undo removes the
    row and the filler together. The first check pins Qt's behaviour: the
    day it fails, Qt lays the bare block out itself and the filler can go."""
    checks = [
        ("Qt still hides the bare block", result.get("bared", 0) < 0, result.get("bared")),
        ("a position was filled", result.get("filled", -1) >= 0, result.get("filled")),
        ("with the dialect's blank", result.get("filler") == "\u00a0", result.get("filler")),
        ("the row has its height back", result.get("fixed", -1) >= 0, result.get("fixed")),
        ("one undo removes row and filler",
         result.get("lenUndone") == result.get("lenBefore"),
         (result.get("lenUndone"), result.get("lenBefore"))),
    ]
    failures = 0
    for name, ok, actual in checks:
        if not ok:
            failures += 1
            print("  FAIL  %-28s %r" % (name, actual))
        elif verbose:
            print("  ok    %-28s" % name)
    return failures


def check_line_height(result, verbose):
    """A note opened empty holds the one block the writer never styled, so
    text typed there sits at Qt's default line height until
    `normalizeLineHeights()` restores the dialect's — the same percent the
    writer states on every block it renders. The inspector mirrors that
    number (textblocks.h), and this is what keeps the two from drifting
    apart. The first check pins Qt's behaviour: the day it fails, empty
    documents inherit a line height on their own and the pass can go."""
    stated = "line-height:%d%%;" % dialect.LINE_HEIGHT_PCT
    checks = [
        ("Qt gave the block no line height", stated not in (result.get("typed") or ""), result.get("typed")),
        ("normalize states the dialect's", stated in (result.get("normalized") or ""), result.get("normalized")),
    ]
    failures = 0
    for name, ok, actual in checks:
        if not ok:
            failures += 1
            print("  FAIL  %-28s %r" % (name, actual))
        elif verbose:
            print("  ok    %-28s" % name)
    return failures


if __name__ == "__main__":
    sys.exit(main())
