"""Structured table cells stored as semantic HTML inside Markdown.

Pipe tables cannot hold another table. Only those richer tables use this
representation; normal tables retain their existing Markdown syntax. HTML
is parsed into the same AST as Markdown, never passed through to the editor.
"""
import html

import htmltree
import textcolor
from mistune import HTMLRenderer
from mistune.core import BlockState


def rows(node):
    """Rows belonging to this table, excluding rows of nested tables."""
    for child in node.children:
        if child.tag == "tr":
            yield child
        elif child.tag in {"thead", "tbody", "tfoot"}:
            yield from rows(child)


def nested(node):
    return any(child.tag == "table" or nested(child) for child in node.children)


def parse_table(source):
    nodes = [node for node in htmltree.parse(source).children
             if node.tag is not None or (node.text or "").strip()]
    if len(nodes) != 1 or nodes[0].tag != "table":
        raise ValueError("An HTML table must be a complete table block")
    return _table(nodes[0])


def _table(node):
    records = []
    for row in rows(node):
        cells = []
        for cell in row.children:
            if cell.tag not in {"td", "th"}:
                continue
            if any(cell.attrs.get(key, "1") != "1" for key in ("rowspan", "colspan")):
                raise ValueError("Merged table cells are not supported")
            cells.append({"type": "table_cell", "attrs": {"block": True},
                          "children": _blocks(cell.children)})
        if cells:
            records.append({"type": "table_row", "children": cells})
    if not records or any(len(row["children"]) != len(records[0]["children"]) for row in records):
        raise ValueError("A table must have equally sized rows")
    return {"type": "table", "children": [
        {"type": "table_head", "children": records[0]["children"]},
        {"type": "table_body", "children": records[1:]}
    ]}


BLOCK_TAGS = {"p", "div", "table", "ul", "ol", "blockquote", "pre", "hr",
              "h1", "h2", "h3", "h4", "h5", "h6"}
INLINE_TAGS = {"b": "strong", "strong": "strong", "i": "emphasis", "em": "emphasis",
               "u": "underline", "s": "strikethrough", "del": "strikethrough", "mark": "mark"}


def _plain(node):
    if node.tag is None:
        return node.text or ""
    return "".join(_plain(child) for child in node.children)


def _inline(nodes):
    out = []
    for node in nodes:
        tag = node.tag
        if tag is None:
            out.append({"type": "text", "raw": node.text or ""})
        elif tag in INLINE_TAGS:
            out.append({"type": INLINE_TAGS[tag], "children": _inline(node.children)})
        elif tag == "code":
            out.append({"type": "codespan", "raw": _plain(node)})
        elif tag == "br":
            out.append({"type": "linebreak"})
        elif tag == "a":
            out.append({"type": "link", "attrs": {"url": node.attrs.get("href", "")},
                        "children": _inline(node.children)})
        elif tag == "img":
            attrs = {"url": node.attrs.get("src", "")}
            if node.attrs.get("width", "").isdigit():
                attrs["width"] = int(node.attrs["width"])
            out.append({"type": "image", "attrs": attrs,
                        "children": [{"type": "text", "raw": node.attrs.get("alt", "")}]})
        elif tag == "span":
            children = _inline(node.children)
            color = textcolor.from_style(node.attrs.get("style", ""))
            if color:
                out.append({"type": "text_color", "attrs": {"color": color}, "children": children})
            else:
                out.extend(children)
        elif tag != "input":
            raise ValueError("Unsupported content in an HTML table: " + str(tag))
    return out


def _blocks(nodes):
    out, inline = [], []

    def flush():
        if inline and any(node.tag is not None or (node.text or "").strip() for node in inline):
            out.append({"type": "paragraph", "children": _inline(inline)})
        inline.clear()

    for node in nodes:
        tag = node.tag
        if tag not in BLOCK_TAGS:
            inline.append(node)
            continue
        flush()
        if tag == "table":
            out.append(_table(node))
        elif tag in {"p", "div"}:
            if any(child.tag in BLOCK_TAGS for child in node.children):
                out.extend(_blocks(node.children))
            else:
                out.append({"type": "paragraph", "children": _inline(node.children)})
        elif tag in {"ul", "ol"}:
            items = []
            for child in node.children:
                if child.tag != "li":
                    continue
                item = {"type": "list_item", "children": _blocks(child.children)}
                checks = [entry for entry in _descendants(child) if entry.tag == "input"]
                if checks:
                    item.update(type="task_list_item", attrs={"checked": "checked" in checks[0].attrs})
                items.append(item)
            out.append({"type": "list", "tight": True,
                        "attrs": {"ordered": tag == "ol", "start": int(node.attrs.get("start", "1"))},
                        "children": items})
        elif tag == "blockquote":
            out.append({"type": "block_quote", "children": _blocks(node.children)})
        elif tag == "pre":
            out.append({"type": "block_code", "raw": _plain(node)})
        elif tag == "hr":
            out.append({"type": "thematic_break"})
        else:
            out.append({"type": "heading", "attrs": {"level": int(tag[1])},
                        "children": _inline(node.children)})
    flush()
    return out


def _descendants(node):
    for child in node.children:
        yield child
        yield from _descendants(child)


class _Renderer(HTMLRenderer):
    def table(self, text):
        return "<table>" + text + "</table>"

    def table_head(self, text):
        return "<tr>" + text + "</tr>"

    def table_body(self, text):
        return text

    def table_row(self, text):
        return "<tr>" + text + "</tr>"

    def table_cell(self, text, align=None, head=False, block=False):
        return "<td>" + (text if block else "<p>" + text + "</p>") + "</td>"

    def underline(self, text):
        return "<u>" + text + "</u>"

    def strikethrough(self, text):
        return "<s>" + text + "</s>"

    def text_color(self, text, color):
        return textcolor.span(color, text)

    def mark(self, text):
        return "<mark>" + text + "</mark>"

    def task_list_item(self, text, checked=False):
        from mistune.plugins.task_lists import render_task_list_item
        return render_task_list_item(self, text, checked)

    def block_code(self, code, info=None):
        return "<pre><code>" + html.escape(code.rstrip("\n"), quote=False).replace("\n", "&#10;") + "</code></pre>"

    def image(self, text, url, title=None, width=0):
        result = super().image(text, url, title)
        return result.replace(" />", ' width="%d" />' % width) if width else result

    def softbreak(self):
        return " "


def table_markup(cells):
    """Rows of Markdown cell contents -> one canonical HTML table block."""
    from parse import parse
    renderer = _Renderer(allow_harmful_protocols=True)
    rows_html = []
    for row in cells:
        contents = [renderer.render_tokens(parse(cell), BlockState()).replace("\n", "") or "<p></p>" for cell in row]
        rows_html.append("<tr>" + "".join("<td>" + text + "</td>" for text in contents) + "</tr>")
    return "<table>" + "".join(rows_html) + "</table>"
