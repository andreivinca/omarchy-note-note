"""Command line for the QML side: one conversion per run, payload on stdin.

    python3 -m qthtml to-html      [--highlight '#f9e2af'] [--highlight-ink '#1e1e2e']
                                   [--link '#4282d7'] [--quote-ink '#9399b2']
                                   [--code-background '#313244'] [--base /dir]
    python3 -m qthtml to-markdown  [--with-map] [--base /dir]

`--base` is the note's own directory, for both directions: it is how an image
the note names by a relative path is found and measured (the display cap for
large images, and telling that cap from a width the author chose).

`--with-map` answers with JSON — the Markdown, the document block each line
came from, and how many blocks there are — which is what lets the toolbar turn
a caret position into a Markdown line.

Payloads arrive on stdin rather than argv so a note never appears in the
process list (docs/security.md rule 2). The options are parsed by hand
because `argparse` costs more to import than the conversion costs to run, and
the editor pays that on every save.
"""
import json
import sys

if __package__ in (None, ""):                      # run as a path, not a module
    sys.path.insert(0, __file__.rsplit("/", 2)[0])
    from qthtml import convert, dialect, to_html, to_markdown
else:
    from . import convert, dialect, to_html, to_markdown

# One note; far above any note the editor will open, and bounded on purpose.
MAX_BYTES = 8 * 1024 * 1024

FLAGS = {"--highlight": "highlight", "--highlight-ink": "ink", "--link": "link",
         "--quote-ink": "quote_ink", "--code-background": "code_background",
         "--base": "base"}


def parse_args(argv):
    options = {"highlight": dialect.DEFAULT_HIGHLIGHT, "ink": dialect.DEFAULT_HIGHLIGHT_INK,
               "link": dialect.DEFAULT_LINK, "quote_ink": dialect.DEFAULT_QUOTE_INK,
               "code_background": dialect.DEFAULT_CODE_BACKGROUND, "base": "", "map": False}
    if not argv or argv[0] not in ("to-html", "to-markdown"):
        raise SystemExit(__doc__)
    direction, rest = argv[0], argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag == "--with-map":
            options["map"] = True
        elif flag in FLAGS and rest:
            options[FLAGS[flag]] = rest.pop(0)
        else:
            raise SystemExit("qthtml: unknown option %r" % flag)
    return direction, options


def main(argv=None):
    direction, options = parse_args(sys.argv[1:] if argv is None else argv)

    payload = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(payload) > MAX_BYTES:
        sys.stderr.write("qthtml: input over %d bytes\n" % MAX_BYTES)
        return 1
    text = payload.decode("utf-8", "replace")

    if direction == "to-html":
        sys.stdout.write(to_html(text, options["highlight"], options["ink"], options["link"],
                                 options["quote_ink"], options["code_background"], options["base"]))
    elif options["map"]:
        json.dump(convert(text, options["base"]), sys.stdout)
    else:
        sys.stdout.write(to_markdown(text, options["base"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
