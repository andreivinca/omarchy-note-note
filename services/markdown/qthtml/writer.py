"""Markdown -> the HTML Qt's rich text engine reads.

The Markdown is parsed once by the vendored mistune (`services/markdown/parse.py`);
this module is only the renderer. It emits the *minimal* form of the dialect —
Qt normalises it into the verbose form on the way in, and `reader` recognises
that form on the way out.
"""
import html as _html
import re
import urllib.parse

from . import dialect
from ._vendor import parse
from .imagesize import width_of

RULE = "<hr />"
# An empty block, drawn one line high. It cannot be `<p></p>` (Qt drops a
# block with nothing in it) and it must not be `<p><br /></p>`: the break
# opens a *second* line inside the block, so every deliberate blank line
# would be drawn twice as tall as one. A single non-breaking space is one
# line, one character — the same length as the break, so the caret map is
# unchanged — and `reader` reads it back as a blank line either way.
BLANK = "<p>%s</p>" % dialect.BLANK_PARAGRAPH

# Qt renders an image at natural size and clips at the pane, so anything wider
# than this gets a display width. Display only: `reader` never writes a width
# back into the note, so the note and the backends see the image untouched.
MAX_IMAGE_DISPLAY = 640

# An image opening a list item is mispainted whether or not a link wraps it
# (measured on 6.11), so the guard below must see through the anchor.
OPENS_WITH_IMAGE = re.compile(r"(?:<a [^>]*>)?<img")

# Inline spans, by AST token type. `mark` is the odd one out: its colour is
# the caller's, so it is built in `_Renderer.inline`.
INLINE_SPAN = {
    "strong": "font-weight:%d;" % dialect.BOLD_WEIGHT,
    "emphasis": "font-style:italic;",
    "underline": "text-decoration: underline;",
    "strikethrough": "text-decoration: line-through;",
    "codespan": "font-family:'%s';" % dialect.MONO_FAMILY,
}


def to_html(markdown, highlight=dialect.DEFAULT_HIGHLIGHT, ink=dialect.DEFAULT_HIGHLIGHT_INK,
            link=dialect.DEFAULT_LINK, quote_ink=dialect.DEFAULT_QUOTE_INK,
            code_background=dialect.DEFAULT_CODE_BACKGROUND):
    """Markdown text -> HTML for a RichText `TextEdit`."""
    return _Renderer(highlight, ink, link, quote_ink, code_background).document(parse(markdown or ""))


class _Renderer:
    def __init__(self, highlight, ink, link, quote_ink=dialect.DEFAULT_QUOTE_INK,
                 code_background=dialect.DEFAULT_CODE_BACKGROUND):
        self.highlight = highlight
        self.ink = ink
        self.link = link
        self.quote_ink = quote_ink
        self.code_background = code_background

    # ---- documents and blocks ------------------------------------------

    def document(self, tokens):
        blocks = self.blocks(tokens)
        # A rule or a table cannot open the document: Qt drops the rule, and
        # puts an empty block above the table on its own. Writing that block
        # ourselves keeps our idea of the document and Qt's identical — which
        # is what the caret map depends on. `reader` takes it away again.
        if blocks and blocks[0].startswith((RULE, "<table")):
            blocks.insert(0, BLANK)
        return "\n".join(blocks)

    def blocks(self, tokens, indent=0, quote=False):
        out = []
        for token in tokens or []:
            out.extend(self.block(token, indent, quote))
        return out

    def block(self, token, indent, quote):
        kind = token["type"]
        if kind == "blank_line":
            return []
        if kind == "heading":
            return [self.heading(token)]
        if kind in ("paragraph", "block_text"):
            return [self.paragraph(token, indent, quote)]
        if kind == "block_quote":
            return self.blocks(token.get("children"), indent, quote=True)
        if kind == "block_code":
            return self.code(token, indent)
        if kind == "thematic_break":
            return [RULE]
        if kind == "list":
            return [self.list(token, indent, quote)]
        if kind == "table":
            return [self.table(token)]
        return self.blocks(token.get("children"), indent, quote)

    def heading(self, token):
        level = min(max(token.get("attrs", {}).get("level", 1), 1), 3)
        span = 'font-size:%s; font-weight:%d;' % (dialect.HEADING_FONT_SIZE[level], dialect.BOLD_WEIGHT)
        # Inside a heading the author's bold is written heavier, so that it
        # survives a document where the heading itself is already bold.
        return '<h%d><span style="%s">%s</span></h%d>' % (
            level, span, self.inline(token.get("children"), heavy=True), level)

    def paragraph(self, token, indent, quote):
        body = self.inline(token.get("children"))
        # A paragraph holding only the blank-line character *is* a blank line.
        if body.strip() in ("", dialect.BLANK_PARAGRAPH):
            return BLANK
        if quote:
            # The margins carry the meaning; the ink is what makes it read as
            # a quote rather than an indent. `reader` never reads colour.
            body = self.span("color:%s;" % self.quote_ink, body)
        return "<p%s>%s</p>" % (self.block_style(indent, quote), body)

    def code(self, token, indent):
        """Qt has no <pre>: a code block is consecutive monospace paragraphs
        on the block background that marks them as one (dialect). The visible
        slab is the editor's (NoteEditor, code slabs) — the background here
        is the marker, passed in near-invisible by the app.

        Vertical margins are zeroed or Qt's default 12px would split the
        block between lines; the neighbours' own margins keep it clear of
        them (Qt spaces blocks by the larger of the two facing margins). The
        left margin is the text's padding inside the slab the editor draws
        reaching CODE_PAD_PX back over it; `reader` ignores a code line's
        margins, so it never reads back as an indent."""
        margin = indent * dialect.INDENT_PX + dialect.CODE_PAD_PX
        style = ' style="margin-top:0px; margin-bottom:0px; margin-left:%dpx; background-color:%s;"' % (
            margin, self.code_background)
        lines = token.get("raw", "").rstrip("\n").split("\n")
        return ['<p%s><span style="font-family:\'%s\';">%s</span></p>'
                % (style, dialect.MONO_FAMILY,
                   _html.escape(line, quote=False) or dialect.EMPTY_CODE_LINE)
                for line in lines]

    def block_style(self, indent, quote):
        if quote:
            # Zeroed vertical margins so neighbouring quote paragraphs read
            # as one quote — the bar the editor draws over them (NoteEditor,
            # quote bars) spans the run without a gap; the neighbours' own
            # margins keep the block clear of everything else.
            return (' style="margin-top:0px; margin-bottom:0px;'
                    ' margin-left:%dpx; margin-right:%dpx;"'
                    % (dialect.QUOTE_PX, dialect.QUOTE_PX))
        if indent > 0:
            return ' style="margin-left:%dpx;"' % (indent * dialect.INDENT_PX)
        return ""

    # ---- lists ----------------------------------------------------------

    def list(self, token, indent, quote):
        tag = "ol" if token.get("attrs", {}).get("ordered") else "ul"
        return "<%s>%s</%s>" % (tag, "".join(self.item(i, indent, quote) for i in token.get("children") or []), tag)

    def item(self, token, indent, quote):
        checked = token.get("attrs", {}).get("checked")
        is_task = token["type"] == "task_list_item"
        body = " ".join(self.inline(c.get("children"))
                        for c in token.get("children") or []
                        if c["type"] in ("block_text", "paragraph")).strip()
        if is_task and not body:
            body = dialect.EMPTY_ITEM        # Qt drops an item with no content
        if OPENS_WITH_IMAGE.match(body):
            body = dialect.IMAGE_LEAD + body  # Qt paints a leading image in the wrong place
        nested = "".join(self.list(c, indent, quote)
                         for c in token.get("children") or [] if c["type"] == "list")
        css = ' class="%s"' % dialect.CHECK_CLASS[bool(checked)] if is_task else ""
        return "<li%s>%s%s</li>" % (css, body, nested)

    # ---- tables ---------------------------------------------------------

    def table(self, token):
        rows = []
        for part in token.get("children") or []:
            if part["type"] == "table_head":
                rows.append([self.inline(c.get("children")) for c in part.get("children") or []])
            elif part["type"] == "table_body":
                rows.extend([self.inline(c.get("children")) for c in row.get("children") or []]
                            for row in part.get("children") or [])
        # An empty cell holds one non-breaking space, not a <br />: the break
        # opens a second line inside the cell (same trap as BLANK), and the
        # reader strips the space with the cell's edges either way.
        cells = "".join("<tr>%s</tr>" % "".join("<td><p>%s</p></td>" % (c or dialect.BLANK_PARAGRAPH)
                                                for c in row)
                        for row in rows)
        # cellspacing 0 or every cell's border sits beside the table's own and
        # the grid reads doubled; the padding is what keeps text off the rules.
        return '<table border="1" cellspacing="0" cellpadding="6">%s</table>' % cells

    # ---- inline ---------------------------------------------------------

    def inline(self, tokens, heavy=False):
        out = []
        for token in tokens or []:
            kind = token["type"]
            if kind == "text":
                out.append(_html.escape(token.get("raw", ""), quote=False))
            elif kind == "codespan":
                out.append(self.span(INLINE_SPAN["codespan"], _html.escape(token.get("raw", ""), quote=False)))
            elif kind == "strong":
                weight = dialect.HEAVY_WEIGHT if heavy else dialect.BOLD_WEIGHT
                out.append(self.span("font-weight:%d;" % weight, self.inline(token.get("children"), heavy)))
            elif kind in INLINE_SPAN:
                out.append(self.span(INLINE_SPAN[kind], self.inline(token.get("children"), heavy)))
            elif kind == "mark":
                out.append(self.span("background-color:%s; color:%s;" % (self.highlight, self.ink),
                                     self.inline(token.get("children"), heavy)))
            elif kind == "link":
                url = token.get("attrs", {}).get("url", "")
                # The colour is stated here rather than left to Qt: an anchor
                # with no colour of its own is painted Qt's #0000ff.
                out.append('<a href="%s" style="color:%s;">%s</a>'
                           % (_html.escape(url, quote=True), self.link,
                              self.inline(token.get("children"), heavy)))
            elif kind == "image":
                # mistune keeps an image's alt text in its children, the way a
                # link keeps its label — not in attrs.
                url = token.get("attrs", {}).get("url", "")
                alt = "".join(c.get("raw", "") for c in token.get("children") or [] if c["type"] == "text")
                out.append('<img src="%s" alt="%s"%s />' % (_html.escape(url, quote=True),
                                                            _html.escape(alt, quote=True),
                                                            self.display_width(url)))
            elif kind == "linebreak":
                out.append("<br />")
            elif kind == "softbreak":
                out.append(" ")
            elif kind == "inline_html":
                out.append(_html.escape(token.get("raw", ""), quote=False))
            elif token.get("children"):
                out.append(self.inline(token.get("children"), heavy))
            elif token.get("raw"):
                out.append(_html.escape(token["raw"], quote=False))
        return "".join(out)

    def display_width(self, url):
        if not url.startswith("file://"):
            return ""
        natural = width_of(urllib.parse.unquote(url[len("file://"):]))
        return ' width="%d"' % MAX_IMAGE_DISPLAY if natural > MAX_IMAGE_DISPLAY else ""

    def span(self, style, body):
        return '<span style="%s">%s</span>' % (style, body)
