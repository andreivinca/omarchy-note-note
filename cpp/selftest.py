"""Agreement test for the two ways the editor finds quote blocks.

The native inspector (textblocks.h) reads block formats from the document;
the fallback (ui/QuoteBars.js) scans the document's serialised HTML. Both
must place the same bars, or a machine without the built library sees
different decorations than one with it. Every round-trip case from the
converter's selftest runs through a real Qt document offscreen, and the two
answers are compared — the exact JS shipped in ui/QuoteBars.js, not a copy.

    sh cpp/build.sh
    python3 cpp/selftest.py [--verbose]

Skipped with a warning when the library is not built or `qml6` is missing.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services", "markdown"))
from qthtml import to_html            # noqa: E402
from qthtml.selftest import CASES     # noqa: E402

MODULE = os.path.join(ROOT, "cpp", "build", "NoteNoteText")
QUOTEBARS = os.path.join(ROOT, "ui", "QuoteBars.js")

QML_TEMPLATE = """
import QtQuick
import "%(module)s"
import "%(quotebars)s" as QuoteBars
Window {
  visible: true
  TextEdit { id: e; textFormat: TextEdit.RichText; font.family: "sans-serif"; width: 600 }
  TextBlocks { id: tb; document: e.textDocument }
  Timer { interval: 60; running: true; onTriggered: {
    var cases = %(cases)s, out = {}
    for (var key in cases) {
      e.text = cases[key]
      out[key] = {
        native: QuoteBars.runsFromBlocks(tb.blocks()),
        scanned: QuoteBars.runs(e.getFormattedText(0, e.length), e.getText(0, e.length))
      }
    }
    console.error("<<<RESULT>>>" + JSON.stringify(out) + "<<<END>>>")
    Qt.exit(0)
  } }
}
"""


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if not os.path.isdir(MODULE):
        print("SKIPPED: %s not built (sh cpp/build.sh)" % MODULE)
        return 0

    documents = {name: to_html(markdown) for name, markdown in CASES.items()}
    script = QML_TEMPLATE % {"module": "file://" + MODULE,
                             "quotebars": "file://" + QUOTEBARS,
                             "cases": json.dumps(documents)}
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
        elif args.verbose and (native["quote"] or native["code"]):
            print("  ok    %-24s %r" % (name, native))
    print("  %d/%d cases" % (len(CASES) - failures, len(CASES)))
    print("\n%s" % ("all green" if not failures else "%d failure(s)" % failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
