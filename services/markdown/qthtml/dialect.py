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
# markers with it — so an empty checkbox carries one non-breaking space. It is
# the only filler character left in the pipeline.
EMPTY_ITEM = "\u00a0"

# Markdown has no empty paragraph, so a deliberate blank line is stored on
# disk as a paragraph holding this character, and shown as an empty one.
BLANK_PARAGRAPH = "\u00a0"

DEFAULT_HIGHLIGHT = "#f9e2af"
# A highlight is a light marker colour, so the text on it needs its own dark
# ink — the editor's foreground is the theme's, and on a dark theme it would
# be light-on-light. `reader` ignores colour, so this never reaches the note.
DEFAULT_HIGHLIGHT_INK = "#1e1e2e"

# Qt paints links itself and writes the painting back as a span inside the
# anchor; that span is decoration, never underline the user asked for.
LINK_COLOUR = "#0000ff"


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
