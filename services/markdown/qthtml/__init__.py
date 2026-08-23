"""Markdown <-> the HTML a RichText `TextEdit` holds.

The editor's document is HTML because Markdown cannot express what the editor
must keep — a highlight, an empty paragraph, an indent, a checkbox with no
text. Notes on disk and the provider contract stay Markdown, so this package
is the boundary between the two, and the only place that knows Qt's dialect.

    to_html(markdown)  -> HTML to assign to TextEdit.text
    to_markdown(html)  -> Markdown from TextEdit.getFormattedText()
    convert(html)      -> {"markdown": str, "blocks": [int]} — the same
                          Markdown, plus the document block each line came
                          from, which is how the toolbar finds the caret's line

Both directions are pure functions of their input; `dialect` holds the
vocabulary they share. See `python3 -m qthtml --help` for the command line the
QML side uses, and `selftest.py` for the round-trip property that matters:
markdown -> html -> (Qt) -> html -> markdown must reach a fixpoint.
"""
from .reader import convert, to_markdown
from .writer import to_html

__all__ = ["convert", "to_html", "to_markdown"]
