"""The HTML Qt's rich text engine writes -> Markdown.

Qt's writer keeps appearance, not semantics, so this is where appearance is
read back as meaning: a font size becomes a heading, both margins become a
quote, a monospace run becomes code. Every rule it applies is named in
`dialect`; nothing here invents one of its own.

The unit of work is a *chunk* — one or more Markdown lines plus the kind of
block that produced them — because two neighbouring monospace paragraphs are
one fenced code block, and that can only be seen once both have been read.

The result is then verified: it is re-parsed, and if a single character of the
note's text would have changed meaning, the whole document is rendered again
with strict escaping. Under-escaping is the one failure that silently edits
someone's note, so it is the one failure that is checked for.
"""
from . import dialect
from . import htmltree
from ._vendor import parse, walk_text
from .imagesize import local_path, width_of
from .mdtext import escape_inline, escape_line_start

# Four non-breaking spaces per level: Markdown has no paragraph indent, and
# this is the form the providers already translate into a real one.
INDENT_TEXT = "\u00a0" * 4

# Marks the inline reader as being inside a heading: there, the heading's own
# weight is not bold, and only the heavier weight the writer uses is.
IN_HEADING = frozenset({"heading"})

# Inline markers, applied outermost first. `code` is not here: a code span
# takes no formatting inside it.
INLINE_MARKERS = (
    ("highlight", "=="),
    ("bold", "**"),
    ("italic", "*"),
    ("underline", "_"),
    ("strike", "~~"),
)


NO_BLOCK = -1


def to_markdown(html, base=""):
    """HTML from a RichText `TextEdit` -> Markdown text, as it belongs on
    disk: trailing blank lines are the editor's (the line the caret parks on
    after leaving a block), not the note's, so they are trimmed here — and
    only here. `convert` keeps them, because the toolbar's caret map must
    name every line the caret can be on; trimming there sent block tools to
    the line above whenever the caret sat on a trailing blank."""
    markdown = convert(html, base)["markdown"]
    lines = markdown.rstrip("\n").split("\n") if markdown else []
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines) + "\n" if lines else ""


def convert(html, base=""):
    """Markdown plus the line -> block map the editor needs for the caret.

        {"markdown": str, "blocks": [int], "count": int}

    `blocks[i]` is the index of the document paragraph line `i` came from,
    counted the way Qt counts them (docs/engine-notes.md): every paragraph,
    list item, table cell and rule is one, in document order. `base` is the
    note's own directory — how a relative image is measured, the same way
    `writer` measures it (see `_Reader.image_width`).
    """
    tree = htmltree.parse(dialect.strip_fragment_markers(html))
    result = _Reader(strict=False, base=base).render(tree)
    if _loses_text(result["markdown"], tree):
        result = _Reader(strict=True, base=base).render(tree)
    return result


class _Chunk:
    """Markdown lines, plus the document paragraph each line came from.

    The toolbar works in Markdown lines but the caret lives at a document
    position, so every line remembers its block. `NO_BLOCK` marks a line that
    is not one — the blank line between two blocks, or a table's `---` row.
    """
    __slots__ = ("kind", "lines", "blocks")

    def __init__(self, kind, lines, blocks=None):
        self.kind = kind
        self.lines = lines
        self.blocks = blocks if blocks is not None else [NO_BLOCK] * len(lines)


class _Reader:
    def __init__(self, strict=False, base=""):
        self.strict = strict
        self.base = base
        self.next_block = 0

    def render(self, body):
        return _join(_merge_code(_drop_leading_spacer(self.walk(body))), self.next_block)

    def take(self, count=1):
        """Claim the next `count` document blocks and return the first."""
        first = self.next_block
        self.next_block += count
        return first

    # ---- blocks ---------------------------------------------------------

    def walk(self, node):
        out = []
        for child in node.children:
            out.extend(self.block(child))
        return out

    def block(self, node):
        if node.tag is None:
            text = (node.text or "").strip()
            return [_Chunk("text", [self.text_line(text)])] if text else []
        if node.tag == "hr":
            return [_Chunk("rule", ["---"], [self.take()])]
        if node.tag in ("ul", "ol"):
            return [self.list(node)]
        if node.tag == "table":
            lines, blocks = self.table(node)
            return [_Chunk("table", lines, blocks)]
        if node.tag == "blockquote":
            # Qt writes a quote as margins, never as a tag; this is for HTML
            # from elsewhere.
            inner = self.walk(node)
            return [_Chunk("text",
                           ["> " + line for chunk in inner for line in chunk.lines],
                           [block for chunk in inner for block in chunk.blocks])]
        if node.tag in ("p", "h1", "h2", "h3", "h4", "h5", "h6", "div"):
            return self.paragraph(node)
        return self.walk(node)                         # a wrapper we don't model

    def paragraph(self, node):
        at = self.take()
        style = dialect.style_map(node.style)
        body = self.inline(node.children)

        if not body.strip():
            # An empty block still carrying the code marker is an empty line
            # *inside* a code block — the one typing Enter there makes — not
            # a blank between blocks: read it as code or the fence splits.
            if dialect.has_block_background(style) and not dialect.is_quote(style):
                return [_Chunk("code", [""], [at])]
            return [_Chunk("blank", [dialect.BLANK_PARAGRAPH], [at])]

        level = self.heading_level(node, style)
        if level:
            head = self.inline(node.children, IN_HEADING).strip()
            return [_Chunk("heading", ["#" * level + " " + head], [at])]

        if self.is_code(node, style):
            lines = [_code_line(line) for line in self.plain(node.children).split("\n")]
            return [_Chunk("code", lines, [at] * len(lines))]

        prefix = "> " if dialect.is_quote(style) else INDENT_TEXT * dialect.indent_level(style)
        # A blank line's filler with text typed in front of it (the editor
        # keeps the caret ahead of the filler): the same leftover a code
        # line sheds, never the author's, so off it comes. Only the tail —
        # a *leading* U+00A0 run is an indent (INDENT_TEXT), not a filler.
        if body.endswith(dialect.BLANK_PARAGRAPH):
            body = body[:-1]
        lines = [prefix + escape_line_start(line) for line in body.split("\n")]
        return [_Chunk("text", lines, [at] * len(lines))]

    def heading_level(self, node, style):
        """A heading is a font size — on the block, or on a span covering it."""
        if node.tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            return min(int(node.tag[1]), 3)
        level = dialect.heading_level(style)
        if level:
            return level
        spans = [c for c in node.children if c.tag == "span"]
        loose = "".join(c.text or "" for c in node.children if c.tag is None)
        if len(spans) == 1 and not loose.strip():
            return dialect.heading_level(dialect.style_map(spans[0].style))
        return 0

    def is_code(self, node, style):
        """A code block is a paragraph of monospace runs on a block
        background, without a quote's margins: all-monospace with no slab is
        a paragraph of inline code (`` `x` `` alone on a line, or a run the
        code tool set), and on a quote's margins it is a quote of inline
        code, whatever background pasted HTML may have brought along."""
        if not dialect.has_block_background(style) or dialect.is_quote(style):
            return False
        runs = [c for c in node.children if c.tag == "span"]
        loose = "".join(c.text or "" for c in node.children if c.tag is None)
        return bool(runs) and not loose.strip() and all(
            dialect.is_mono(dialect.style_map(c.style)) for c in runs)

    # ---- lists ----------------------------------------------------------

    def list(self, node, depth=0):
        """Returns a chunk: one Markdown line per item, nested items after it."""
        ordered = node.tag == "ol"
        lines, blocks = [], []
        for index, item in enumerate(node.find("li"), start=1):
            body = self.inline([c for c in item.children if c.tag not in ("ul", "ol")]).strip()
            if body == dialect.EMPTY_ITEM:
                body = ""
            lines.append("  " * depth + self.marker(item, ordered, index) + body)
            blocks.append(self.take())
            for nested in item.children:
                if nested.tag in ("ul", "ol"):
                    inner = self.list(nested, depth + 1)
                    lines.extend(inner.lines)
                    blocks.extend(inner.blocks)
        return _Chunk("list", lines, blocks)

    def marker(self, item, ordered, index):
        checked = dialect.CLASS_CHECK.get(item.attrs.get("class", ""))
        if checked is not None:
            return "- [x] " if checked else "- [ ] "
        return "%d. " % index if ordered else "- "

    # ---- tables ---------------------------------------------------------

    def table(self, node):
        """Every cell is a document block; a row is one Markdown line."""
        rows, starts = [], []
        for row in _rows(node):
            cells = [cell for cell in row.children if cell.tag in ("td", "th")]
            if not cells:
                continue
            starts.append(self.take(len(cells)))
            rows.append([self.cell(cell) for cell in cells])
        if not rows:
            return [], []
        width = max(len(row) for row in rows)
        rows = [row + [""] * (width - len(row)) for row in rows]
        lines = [_row(rows[0]), "|" + "|".join(["---"] * width) + "|"]
        blocks = [starts[0], NO_BLOCK]
        for index, row in enumerate(rows[1:], start=1):
            lines.append(_row(row))
            blocks.append(starts[index])
        return lines, blocks

    def cell(self, node):
        paragraphs = [self.inline(p.children).strip() for p in node.children if p.tag == "p"]
        text = " ".join(p for p in paragraphs if p) or self.inline(node.children).strip()
        return text.replace("|", "\\|").replace("\n", " ")

    # ---- inline ---------------------------------------------------------
    #
    # Qt does not nest formatting: `**bold with ==mark== inside**` comes back
    # as three sibling spans that each repeat `font-weight:700`. So the text is
    # read into a flat list of runs carrying their styles, and the markers are
    # placed afterwards, around the longest stretch of runs that shares one.

    def plain(self, nodes):
        """The visible text, with no Markdown at all — code and headings."""
        out = []
        for node in nodes or []:
            if node.tag is None:
                out.append(node.text or "")
            elif node.tag == "br":
                out.append("\n")
            elif node.tag == "a":
                out.append(self.plain(node.children).strip() or node.attrs.get("href", ""))
            else:
                out.append(self.plain(node.children))
        return "".join(out)

    def inline(self, nodes, active=frozenset()):
        return _emit(self.runs(nodes, active), active)

    def runs(self, nodes, active=frozenset()):
        out = []
        for node in nodes or []:
            if node.tag is None:
                out.append(_Run(self.text_run(node.text or ""), active))
            elif node.tag == "br":
                out.append(_Run("  \n", frozenset()))     # markers never span a break
            elif node.tag == "a":
                out.append(self.anchor(node, active))
            elif node.tag == "img":
                out.append(_Run("![%s](%s)%s" % (node.attrs.get("alt", ""), node.attrs.get("src", ""),
                                                 self.image_width(node)), active))
            elif node.tag == "span":
                style = dialect.style_map(node.style)
                if dialect.is_mono(style):
                    out.append(_Run("`%s`" % self.plain(node.children), active))
                else:
                    out.extend(self.runs(node.children, active | self.styles_of(style, active)))
            else:
                out.extend(self.runs(node.children, active))
        return out

    def anchor(self, node, active):
        """A link Qt wrote inside bold text: the bold belongs outside the link,
        or `**see [docs](url)**` comes back as `**see** [**docs**](url)`."""
        href = node.attrs.get("href", "")
        inner = self.runs(node.children, active | {"link"})
        shared = frozenset.intersection(*[run.styles for run in inner]) if inner else frozenset()
        shared -= {"link"}
        text = _emit(inner, active | shared | {"link"}).strip()
        return _Run("[%s](%s)" % (text or href, href.replace(")", "%29")), active | shared)

    def image_width(self, node):
        """A width the author gave the image, as `{width=N}` after it — the
        marker `parse` folds back into the token. The display cap the writer
        puts on a large image that names no width is not the author's and
        stays out of the note: a width equal to the cap, on an image the cap
        would have applied to, is the cap (dialect.MAX_IMAGE_DISPLAY)."""
        width = dialect.px(node.attrs.get("width"), 0)
        if width <= 0:
            return ""
        if width == dialect.MAX_IMAGE_DISPLAY:
            natural = width_of(local_path(node.attrs.get("src", ""), self.base))
            if natural > dialect.MAX_IMAGE_DISPLAY:
                return ""
        return "{width=%d}" % width

    def styles_of(self, style, active):
        decoration = style.get("text-decoration", "")
        found = set()
        if "background-color" in style:
            found.add("highlight")
        minimum = dialect.HEAVY_WEIGHT if "heading" in active else dialect.BOLD_WEIGHT
        if dialect.is_bold(style, minimum):
            found.add("bold")
        if style.get("font-style") == "italic":
            found.add("italic")
        # Qt paints a link's own underline; inside an anchor that is decoration.
        if "underline" in decoration and "link" not in active:
            found.add("underline")
        if "line-through" in decoration:
            found.add("strike")
        return frozenset(found) - active

    def text_run(self, text):
        return escape_inline(text, self.strict)

    def text_line(self, text):
        return escape_line_start(escape_inline(text, self.strict))


class _Run:
    """A stretch of text and the styles active over it."""
    __slots__ = ("text", "styles")

    def __init__(self, text, styles):
        self.text = text
        self.styles = frozenset(styles)


def _emit(runs, active=frozenset()):
    """Runs -> Markdown, wrapping each marker around as much as it covers."""
    out = []
    index = 0
    while index < len(runs):
        extra = runs[index].styles - active
        if not extra:
            out.append(runs[index].text)
            index += 1
            continue
        name, marker = next((n, m) for n, m in INLINE_MARKERS if n in extra)
        end = index
        while end < len(runs) and name in (runs[end].styles - active):
            end += 1
        out.append(_wrap(marker, _emit(runs[index:end], active | {name})))
        index = end
    return "".join(out)


def _wrap(marker, body):
    """`** bold **` is not bold: whitespace has to sit outside the markers."""
    stripped = body.strip()
    if not stripped:
        return body
    lead = body[:len(body) - len(body.lstrip())]
    tail = body[len(body.rstrip()):]
    return lead + marker + stripped + marker + tail


def _code_line(line):
    """One filler (dialect.EMPTY_CODE_LINE) may sit at either end of a code
    line: the writer's empty-line filler, or the same character left where the
    user typed beside it. It is never the author's — the editor has no way to
    type one — so one comes off each end."""
    if line.startswith(dialect.EMPTY_CODE_LINE):
        line = line[1:]
    if line.endswith(dialect.EMPTY_CODE_LINE):
        line = line[:-1]
    return line


# ---- assembling -----------------------------------------------------------

def _rows(node):
    for child in node.children:
        if child.tag == "tr":
            yield child
        elif child.tag in ("thead", "tbody", "tfoot"):
            for row in child.children:
                if row.tag == "tr":
                    yield row


def _row(cells):
    return "| " + " | ".join(cell.strip() for cell in cells) + " |"


SPACER_NEEDED_BY = ("rule", "table")


def _drop_leading_spacer(chunks):
    """The blank block above a leading rule or table is Qt's, not the note's."""
    if len(chunks) > 1 and chunks[0].kind == "blank" and chunks[1].kind in SPACER_NEEDED_BY:
        return chunks[1:]
    return chunks


def _merge_code(chunks):
    """Neighbouring monospace paragraphs are one fenced block."""
    merged = []
    for chunk in chunks:
        if chunk.kind == "code" and merged and merged[-1].kind == "code":
            merged[-1].lines.extend(chunk.lines)
            merged[-1].blocks.extend(chunk.blocks)
        else:
            merged.append(_Chunk(chunk.kind, list(chunk.lines), list(chunk.blocks)))
    # The fences are ours, not the document's: they belong to no block.
    return [_Chunk("fence", ["```"] + c.lines + ["```"], [NO_BLOCK] + c.blocks + [NO_BLOCK])
            if c.kind == "code" else c for c in merged]


def _join(chunks, total):
    """Blocks are separated by a blank line; items and rows inside one are
    not. Trailing blanks stay: the caret map covers every line (see
    `to_markdown`, which is where they come off for the note on disk)."""
    lines, blocks = [], []
    for index, chunk in enumerate(chunks):
        if index:
            lines.append("")
            blocks.append(NO_BLOCK)
        lines.extend(chunk.lines)
        blocks.extend(chunk.blocks)
    return {"markdown": "\n".join(lines) + "\n" if lines else "", "blocks": blocks, "count": total}


def _loses_text(markdown, tree):
    """Would reading this Markdown back give different text than the document?"""
    return _words(walk_text(parse(markdown))) != _words(_Reader().plain(tree.children))


def _words(text):
    return "".join((text or "").split())
