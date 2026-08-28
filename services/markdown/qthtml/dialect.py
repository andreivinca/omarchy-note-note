"""The HTML dialect Qt's rich text engine round-trips.

A `TextEdit` with `textFormat: RichText` holds a QTextDocument: assigning
`text` runs Qt's HTML reader, `getFormattedText()` runs its writer. The
writer emits **appearance, not semantics** — a heading comes back as a font
size, a quote as paragraph margins, a code block as a font family. This
module is the one place that vocabulary is written down: `writer` emits it,
`reader` recognises it, and nothing else needs to know it.

Measured on Qt 6.11 (docs/engine-notes.md). The document reaches a fixpoint
after one pass, so these are the values that come *back*, not merely the ones
we send.
"""
import re

# Headings survive as a font size on a span; the tag does not survive at all
# for the document's first block, so size is the only reliable signal.
HEADING_FONT_SIZE = {1: "xx-large", 2: "x-large", 3: "large"}
FONT_SIZE_HEADING = {size: level for level, size in HEADING_FONT_SIZE.items()}

BOLD_WEIGHT = 700
# A heading is drawn bold, so bold *inside* one has to be heavier or it cannot
# be told from the heading itself: 700 there is the heading, 900 is the author.
HEAVY_WEIGHT = 900
MONO_FAMILY = "monospace"

# One "increase indent" step, and the margins Qt gives a <blockquote>. A quote
# is the pair (both margins set); an indent sets the left one only.
INDENT_PX = 36
QUOTE_PX = 40

# Checkbox state rides on the list item's class attribute.
CHECK_CLASS = {False: "unchecked", True: "checked"}
CLASS_CHECK = {name: state for state, name in CHECK_CLASS.items()}

# Qt drops a list item with no content — and takes the whole list's checkbox
# markers with it — so an empty checkbox carries one non-breaking space.
EMPTY_ITEM = "\u00a0"

# An empty line inside a code block carries one non-breaking space *inside*
# the monospace span. A `<br />` there is not enough: Qt drops the span around
# a bare break, the line stops being monospace, and the block reads back as
# two blocks with a blank between them. `reader` strips the filler from a code
# line's ends, so it never reaches the note — and neither does one left over
# from typing beside it.
EMPTY_CODE_LINE = "\u00a0"

# Markdown has no empty paragraph, so a deliberate blank line is stored on
# disk as a paragraph holding this character, and shown as an empty one.
BLANK_PARAGRAPH = "\u00a0"

# An image that is the very first thing in a list item is painted ~200px too
# high by Qt's text engine (measured on 6.11; a paragraph is fine, and so is
# the same item once anything precedes the image). One non-breaking space in
# front of it is invisible and enough; `reader` strips it again.
IMAGE_LEAD = "\u00a0"

DEFAULT_HIGHLIGHT = "#f9e2af"
# A highlight is a light marker colour, so the text on it needs its own dark
# ink — the editor's foreground is the theme's, and on a dark theme it would
# be light-on-light. `reader` ignores colour, so this never reaches the note.
DEFAULT_HIGHLIGHT_INK = "#1e1e2e"

# Qt paints links itself and writes the painting back as a span inside the
# anchor; that span is decoration, never underline the user asked for
# (`reader.anchor`, which is why colour is never read back at all).
#
# Left to itself Qt paints them #0000ff, which is unreadable on a dark theme
# and shouts on a light one, so `writer` states the colour on every anchor.
# This is the fallback for a caller that names none; the app passes a colour
# leaned toward the theme's own text (see Notes.qml, linkColour) — the same
# hue on any theme, the contrast the foreground already had. Like the
# highlight, it never reaches the note: it lives in the document only.
DEFAULT_LINK = "#4282d7"

# A quote's ink. The margins are what `reader` recognises; the colour is for
# the eye — without it a quote is indistinguishable from a plain indent. The
# app passes the theme's foreground at reduced strength (Notes.qml, quoteInk)
# and draws the classic bar itself, over the document (NoteEditor, quote
# bars): Qt rich text has no block borders, so the bar cannot live in the
# document at all. `reader` never reads colour, so the ink stays in the
# document only.
DEFAULT_QUOTE_INK = "#9399b2"

# The marker behind a code block. This one is dialect, not decoration: an
# all-monospace paragraph WITH a block background — and without a quote's
# margins — is a code block; all-monospace without one is a paragraph of
# inline code (before the marker, `x` alone on a line came back as a fenced
# block), and on a quote's margins it is a quote of inline code. Qt keeps
# the background on the paragraph and copies it onto no existing span
# (measured on 6.11), so it never collides with the highlight, whose
# background sits on spans. Only its *presence* means anything: the marker
# is transparent (a transparent background is still a brush, and Qt round-
# trips `background-color:transparent`), and the editor draws the visible
# slab itself, over the document (NoteEditor, code slabs). Even a faint
# real colour here would show: Qt Quick paints a block background for the
# first block of a run but not for blocks split from it (measured on 6.11).
DEFAULT_CODE_BACKGROUND = "transparent"

# The text's padding inside that slab: code lines carry it as a left margin
# (readers ignore a code line's margins), and the editor draws the slab
# reaching the same distance back over it.
CODE_PAD_PX = 14


# Qt's writer brackets its output with these; on the way back *in* they make
# Qt treat the HTML as a pasted fragment, which merges the first block into the
# cursor's block and silently drops its format (a heading becomes a paragraph,
# a list stops being a list). Strip them from anything handed back to Qt.
FRAGMENT_MARKERS = re.compile(r"<!--(?:Start|End)Fragment-->")


def strip_fragment_markers(html):
    return FRAGMENT_MARKERS.sub("", html or "")


def style_map(value):
    """A `style` attribute as a dict: `font-size:large; font-weight:700`."""
    out = {}
    for part in (value or "").split(";"):
        name, sep, val = part.partition(":")
        if sep:
            out[name.strip().lower()] = val.strip().lower()
    return out


def px(value, default=0):
    """`36px` -> 36. Qt writes px everywhere; anything else is not ours."""
    try:
        return int(float(str(value).strip().rstrip("px").strip()))
    except (TypeError, ValueError):
        return default


def indent_level(style):
    """Indent steps on a block, ignoring the margins that mean "quote"."""
    if is_quote(style):
        return 0
    return max(0, px(style.get("margin-left")) // INDENT_PX)


def is_quote(style):
    """Qt has no blockquote: it is a paragraph inset from *both* sides."""
    return px(style.get("margin-left")) >= QUOTE_PX and px(style.get("margin-right")) >= QUOTE_PX


def heading_level(style):
    """The heading level a span's font size stands for, or 0."""
    return FONT_SIZE_HEADING.get(style.get("font-size", ""), 0)


def is_bold(style, minimum=BOLD_WEIGHT):
    """Bold, at or above the weight that counts as bold in this context."""
    weight = style.get("font-weight", "")
    if weight in ("bold", "bolder"):
        return minimum <= BOLD_WEIGHT
    try:
        return int(weight) >= minimum
    except ValueError:
        return False


def is_mono(style):
    return MONO_FAMILY in style.get("font-family", "").replace("'", "").replace('"', "")


def has_block_background(style):
    """The slab behind a code block, whatever colour the theme gave it."""
    return "background-color" in style
