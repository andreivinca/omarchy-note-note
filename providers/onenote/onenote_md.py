"""OneNote page HTML <-> Markdown, in the dialect Qt's TextEdit reads and
writes (GitHub-style task lists, tables, `*italic*`, `_underline_`).

Only what round-trips is converted; anything else marks the page as not
editable (see convert()["editable"]) so the UI opens it read-only.
"""
import html as _html
import re
from html.parser import HTMLParser

# OneNote note tags -> a prefix we can recognise again on save.
TAG_PREFIX = {
    "important": "⭐ ", "question": "❓ ", "idea": "💡 ", "critical": "❗ ",
    "remember-for-later": "📌 ", "contact": "👤 ", "address": "🏠 ", "phone-number": "📞 ",
    "web-site-to-visit": "🔗 ", "definition": "📖 ", "to-do-priority-1": "🔴 ", "to-do-priority-2": "🟡 ",
}
PREFIX_TAG = {v.strip(): k for k, v in TAG_PREFIX.items()}
BLOCK_TAGS = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "tr", "td", "th", "br", "cite", "body", "html", "head", "title"}
LOSSY_TAGS = {"object", "iframe", "video", "audio", "math", "svg"}
GAP = "\u00a0"   # an empty line, see Converter.block("br")
# OneNote's own paragraphs are written with zero margins; without a style it
# applies 5.5pt above and below, which reads as extra spacing on every line.
P_STYLE = ' style="margin-top:0pt;margin-bottom:0pt"'
NBSP4 = "\u00a0" * 4
INDENT_PX = 36        # one indent level, as OneNote's own "increase indent"


class Node:
    __slots__ = ("tag", "attrs", "children", "text")

    def __init__(self, tag, attrs=None, text=None):
        self.tag, self.attrs, self.children, self.text = tag, dict(attrs or []), [], text


class TreeBuilder(HTMLParser):
    VOID = {"br", "img", "meta", "link", "hr", "input"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("root")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(Node(tag, attrs))

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(Node(None, text=data))



# Plain text from the backend must not be read as Markdown by the editor:
# escape inline markers, and line starts that would become a heading, list,
# quote, rule or table. Qt re-escapes on save; our parser unescapes.
_INLINE_ESC = re.compile(r"([\\*_`~\[\]<>|])")
_LINE_ESC = re.compile(r"^(\s*)([#>+\-*]|[-=]{3,}\s*$|\|)")
_LINE_NUM = re.compile(r"^(\s*\d+)([.)])")


def escape_text(text):
    return _INLINE_ESC.sub(r"\\\1", text)


def escape_line_start(text):
    m = _LINE_NUM.match(text)
    if m:                      # "1. x" -> "1\. x"
        return text[:m.start(2)] + "\\" + text[m.start(2):]
    m = _LINE_ESC.match(text)
    if not m:
        return text
    return text[:m.start(2)] + "\\" + text[m.start(2):]


# ---------------------------------------------------------------- HTML -> Markdown

class Converter:
    def __init__(self, image_path_for=None):
        self.lines = []
        # What the previous emitted block was: consecutive plain paragraphs
        # are joined with hard line breaks, because OneNote writes one <p>
        # per visual line and Markdown would otherwise flow them together.
        self.last = None
        self.editable = True
        # [{"src", "alt", "width", "local"}] — what the page's images are and
        # where each one was cached, so a save can hand the same resource back.
        self.images = []
        # (src, declared width or 0) -> url/path to show
        self.image_path_for = image_path_for or (lambda src, width: None)

    # -- inline --------------------------------------------------------
    def inline(self, node):
        out = []
        for c in node.children:
            if c.tag is None:
                out.append(escape_text(re.sub(r"\s+", " ", c.text)))
            elif c.tag in ("b", "strong"):
                inner = self.inline(c).strip()
                out.append("**%s**" % inner if inner else "")
            elif c.tag in ("i", "em"):
                inner = self.inline(c).strip()
                out.append("*%s*" % inner if inner else "")
            elif c.tag == "u":
                inner = self.inline(c).strip()
                out.append("_%s_" % inner if inner else "")
            elif c.tag == "a":
                inner = self.inline(c).strip() or c.attrs.get("href", "")
                href = c.attrs.get("href", "")
                out.append("[%s](%s)" % (inner, href) if href else inner)
            elif c.tag == "br":
                out.append("\n")
            elif c.tag == "img":
                # The display-size rendition, not data-fullres-src: the editor
                # shows images at their natural size.
                src = c.attrs.get("src") or c.attrs.get("data-fullres-src", "")
                alt = c.attrs.get("alt", "")
                try:
                    width = int(float(c.attrs.get("width", "0") or 0))
                except ValueError:
                    width = 0
                local = self.image_path_for(src, width)
                if local:
                    # The page can be written back: the save hands this same
                    # resource to OneNote again, by the src it came from.
                    self.images.append({"src": src, "alt": alt, "width": width, "local": local})
                    out.append("![%s](%s)" % (alt, local))
                else:
                    # Not shown means not held: editing could only lose it.
                    self.editable = False
                    out.append("[image: %s]" % (alt or "not shown"))
            elif c.tag in LOSSY_TAGS:
                self.editable = False
                out.append("[unsupported: %s]" % c.tag)
            elif c.tag in ("span", "code", "font", "sup", "sub", "s", "strike", "del", "cite"):
                tag = c.attrs.get("data-tag", "")
                inner = self.inline(c)
                # OneNote writes formatting as styled spans, not <b>/<i>/<u>.
                style = c.attrs.get("style", "").replace(" ", "").lower()
                core = inner.strip()
                if core:
                    lead = inner[:len(inner) - len(inner.lstrip())]
                    trail = inner[len(inner.rstrip()):]
                    if "font-weight:bold" in style or re.search(r"font-weight:[6-9]00", style):
                        core = "**%s**" % core
                    if "font-style:italic" in style:
                        core = "*%s*" % core
                    if "text-decoration:underline" in style:
                        core = "_%s_" % core
                    if "text-decoration:line-through" in style or c.tag in ("s", "strike", "del"):
                        core = "~~%s~~" % core
                    if "background-color:" in style and "background-color:transparent" not in style:
                        core = "==%s==" % core           # highlight
                    inner = lead + core + trail
                if tag.startswith("to-do"):
                    inner = ("[x] " if tag.endswith("completed") else "[ ] ") + inner.lstrip()
                elif tag in TAG_PREFIX:
                    inner = TAG_PREFIX[tag] + inner.lstrip()
                out.append(inner)
            else:
                out.append(self.inline(c))
        return "".join(out)

    # -- blocks --------------------------------------------------------
    def para_prefix(self, node):
        tag = node.attrs.get("data-tag", "")
        if tag.startswith("to-do"):
            return "- [x] " if tag.endswith("completed") else "- [ ] "
        if tag in TAG_PREFIX:
            return TAG_PREFIX[tag]
        if tag:
            self.editable = False
        return ""

    def block(self, node, depth=0):
        t = node.tag
        if t not in ("p", "cite", None):
            self.last = None
        if t is None:
            txt = node.text.strip()
            if txt:
                self.lines.append(re.sub(r"\s+", " ", txt))
            return
        if t in ("head", "title", "style", "script", "meta"):
            return
        if t in ("html", "body", "div", "root"):
            if t == "div" and self.lines and self.lines[-1] != "":
                self.lines.append("")
            for c in node.children:
                self.block(c, depth)
            return
        if t == "img":
            # OneNote keeps an image as a sibling of the paragraphs, not
            # inside one. Writing it as its own Markdown block is what lets a
            # save rewrite the text around it and leave the image alone.
            text = self.inline(_wrap(node)).strip()
            if text:
                if self.lines and self.lines[-1] != "":
                    self.lines.append("")
                self.lines.append(text)
                self.lines.append("")
            self.last = None
            return
        if t == "p" and not self.inline(node).strip() and any(c.tag == "br" for c in node.children):
            self.block(Node("br"), depth)      # <p><br/></p>: an empty line
            return
        if t == "p" or t == "cite":
            text = self.inline(node).strip()
            prefix = self.para_prefix(node) if t == "p" else "*"
            if t == "p":
                m = re.search(r"margin-left:\s*([\d.]+)(px|pt)", node.attrs.get("style", ""))
                if m:
                    val = float(m.group(1)) * (1.333 if m.group(2) == "pt" else 1.0)
                    text = NBSP4 * max(0, int(round(val / INDENT_PX))) + text
            if t == "cite":
                text = "*%s*" % text if text else ""
                prefix = ""
            if text and not prefix and node.children and node.children[0].tag is None:
                text = escape_line_start(text)
            if text or prefix.startswith("- ["):
                plain = not prefix
                if plain and self.last == "p" and self.lines and self.lines[-1] != "":
                    self.lines[-1] = self.lines[-1] + "  "        # hard break
                elif self.last is not None and self.last != ("p" if plain else "item") and self.lines and self.lines[-1] != "":
                    self.lines.append("")                          # text <-> list boundary
                self.lines.append(prefix + text.replace("\n", "  \n"))
                self.last = "p" if plain else "item"
            return
        if t in ("h1", "h2", "h3", "h4", "h5", "h6"):
            text = self.inline(node).strip()
            if text:
                if self.lines and self.lines[-1] != "":
                    self.lines.append("")
                self.lines.append("#" * int(t[1]) + " " + text)
                self.lines.append("")
            return
        if t in ("ul", "ol"):
            n = 0
            for c in node.children:
                if c.tag == "li":
                    n += 1
                    self.list_item(c, t, n, depth)
                elif c.tag == "br":
                    pass
                else:
                    self.block(c, depth)
            if depth == 0:
                self.lines.append("")
            return
        if t == "li":
            self.list_item(node, "ul", 1, depth)
            return
        if t == "table":
            self.table(node)
            return
        if t == "br":
            # A bare <br/> between blocks is a visual empty line in OneNote.
            # Markdown has no such thing, so it becomes a paragraph holding a
            # single non-breaking space, which the editor draws as a blank line.
            if self.lines and self.lines[-1] not in ("", GAP):
                self.lines.append("")
                self.lines.append(GAP)
                self.lines.append("")
            self.last = None
            return
        if t == "img":
            self.lines.append(self.inline(Node("span", children_of=None) if False else _wrap(node)).strip())
            return
        if t in LOSSY_TAGS:
            self.editable = False
            self.lines.append("[unsupported: %s]" % t)
            return
        # unknown container: descend
        for c in node.children:
            self.block(c, depth)

    def list_item(self, node, kind, n, depth):
        inline_nodes, sublists = [], []
        for c in node.children:
            (sublists if c.tag in ("ul", "ol") else inline_nodes).append(c)
        holder = Node("span")
        holder.children = inline_nodes
        text = self.inline(holder).strip()
        marker = ("%d. " % n) if kind == "ol" else "- "
        if text.startswith("[ ] ") or text.startswith("[x] "):
            marker = "- "
        elif inline_nodes and inline_nodes[0].tag is None:
            text = escape_line_start(text)
        self.lines.append("  " * depth + marker + text.replace("\n", " "))
        for s in sublists:
            self.block(s, depth + 1)

    def table(self, node):
        rows = []
        for tr in _find_all(node, "tr"):
            cells = []
            for td in tr.children:
                if td.tag in ("td", "th"):
                    cells.append(self.inline(td).replace("\n", " ").replace("|", "\\|").strip())
            rows.append(cells)
        if not rows:
            return
        width = max(len(r) for r in rows)
        rows = [r + [""] * (width - len(r)) for r in rows]
        if self.lines and self.lines[-1] != "":
            self.lines.append("")
        self.lines.append("| " + " | ".join(rows[0]) + " |")
        self.lines.append("|" + "|".join(["---"] * width) + "|")
        for r in rows[1:]:
            self.lines.append("| " + " | ".join(r) + " |")
        self.lines.append("")

    def result(self):
        out, blank = [], True
        for l in self.lines:
            if l.strip() or l == GAP:
                out.append(l if l == GAP else l[:len(l.rstrip()) + (2 if l.endswith("  ") else 0)]); blank = False
            elif not blank:
                out.append(""); blank = True
        while out and out[-1] in ("", GAP):
            out.pop()
        return "\n".join(out)


def _wrap(node):
    holder = Node("span")
    holder.children = [node]
    return holder


def _find_all(node, tag):
    found = []
    for c in node.children:
        if c.tag == tag:
            found.append(c)
        else:
            found.extend(_find_all(c, tag))
    return found


# The data-id we put on every text run we write, so a later save can find the
# div again. OneNote keeps data-id through an update; the generated id (which
# is the only thing a replace can target) changes on every write, so it has to
# be read back each time.
TEXT_RUN_ID = "nn-text-%d"


def page_structure(html):
    """The page's top-level runs, as a save needs to see them.

        [{"kind": "text",  "id": "div:{…}", "dataId": "nn-text-0"},
         {"kind": "image", "id": "img:{…}", "src": "https://…/resources/…"}]

    Anything else at the top level (a stray paragraph OneNote or another
    client added) is reported as a text run with no data-id, which is enough
    for the save to notice the page is not ours to patch piecemeal.
    """
    tb = TreeBuilder()
    tb.feed(html)
    bodies = _find_all(tb.root, "body") or [tb.root]
    outer = None
    for body in bodies:
        for c in body.children:
            if c.tag == "div":
                outer = c
                break
    if outer is None:
        return []
    runs = []
    for c in outer.children:
        if c.tag == "img":
            runs.append({"kind": "image", "id": c.attrs.get("id", ""),
                         "src": c.attrs.get("src") or c.attrs.get("data-fullres-src", "")})
        elif c.tag is None and not (c.text or "").strip():
            continue
        else:
            runs.append({"kind": "text", "id": c.attrs.get("id", ""), "dataId": c.attrs.get("data-id", "")})
    return runs


def html_to_markdown(html, image_path_for=None):
    tb = TreeBuilder()
    tb.feed(html)
    title = ""
    for t in _find_all(tb.root, "title"):
        title = "".join(c.text for c in t.children if c.tag is None).strip()
    conv = Converter(image_path_for)
    for body in (_find_all(tb.root, "body") or [tb.root]):
        conv.block(body)
    return {"title": title, "body": conv.result(), "editable": conv.editable, "images": conv.images}


# ---------------------------------------------------------------- Markdown -> OneNote HTML
#
# Markdown is parsed by the vendored mistune (services/markdown/parse.py);
# this is only the renderer into the HTML OneNote accepts.

import os as _os
import sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "..", "..", "services", "markdown"))
from parse import parse as _parse  # noqa: E402

_QUOTE_STYLE = ' style="margin-left:20pt;color:#595959"'


def _inline_html(tokens, image_ref=None):
    out = []
    for t in tokens or []:
        ty = t["type"]
        if ty == "text":
            out.append(_html.escape(t.get("raw", ""), quote=False))
        elif ty == "softbreak":
            out.append(" ")
        elif ty == "linebreak":
            out.append("\n")                    # paragraph split, see _paragraphs()
        elif ty == "strong":
            out.append("<b>%s</b>" % _inline_html(t.get("children"), image_ref))
        elif ty == "emphasis":
            out.append("<i>%s</i>" % _inline_html(t.get("children"), image_ref))
        elif ty == "underline":
            out.append("<u>%s</u>" % _inline_html(t.get("children"), image_ref))
        elif ty == "strikethrough":
            out.append("<s>%s</s>" % _inline_html(t.get("children"), image_ref))
        elif ty == "mark":
            out.append('<span style="background-color:#FFFF00">%s</span>' % _inline_html(t.get("children"), image_ref))
        elif ty == "codespan":
            out.append('<span style="font-family:Consolas">%s</span>' % _html.escape(t.get("raw", ""), quote=False))
        elif ty == "link":
            out.append('<a href="%s">%s</a>' % (_html.escape(t.get("attrs", {}).get("url", ""), quote=True), _inline_html(t.get("children"), image_ref)))
        elif ty == "image":
            out.append(_img_html(t, image_ref))
        elif ty == "inline_html":
            out.append(_html.escape(t.get("raw", ""), quote=False))
        else:
            out.append(_inline_html(t.get("children"), image_ref) if t.get("children")
                       else _html.escape(t.get("raw", ""), quote=False))
    return "".join(out)


def _lone_image(token):
    """A paragraph that is nothing but an image: OneNote keeps images as
    siblings of the paragraphs, not inside them, and only a top-level image
    can be left untouched while the text around it is rewritten."""
    kids = [c for c in token.get("children") or [] if not (c["type"] == "text" and not c.get("raw", "").strip())]
    return len(kids) == 1 and kids[0]["type"] == "image"


def _img_html(token, image_ref):
    """An image token -> the <img> OneNote accepts, through the caller's
    resolver: an existing page resource keeps its own src, a local file is
    uploaded as a part of the request, and anything the resolver refuses is
    written as its alt text rather than silently dropped."""
    attrs = token.get("attrs", {})
    url, alt = attrs.get("url", ""), _alt_of(token)
    width = 0
    src = url
    if image_ref:
        src, width = image_ref(url, alt)
    if not src:
        return _html.escape("[image: %s]" % (alt or "not shown"), quote=False)
    size = ' width="%d"' % width if width else ""
    return '<img src="%s" alt="%s"%s/>' % (_html.escape(src, quote=True), _html.escape(alt, quote=True), size)


def _alt_of(token):
    kids = token.get("children") or []
    return "".join(c.get("raw", "") for c in kids if c["type"] == "text") or token.get("attrs", {}).get("alt", "")


def _tagged(text):
    """Split a leading checkbox / note-tag prefix off plain text -> (tag, rest)."""
    m = re.match(r"\[( |x|X)\] ?(.*)$", text)
    if m:
        return ("to-do:completed" if m.group(1).lower() == "x" else "to-do"), m.group(2)
    for prefix, tag in PREFIX_TAG.items():
        if text.startswith(prefix + " ") or text == prefix:
            return tag, text[len(prefix):].lstrip()
    return None, text


def _tag_prefix(tokens):
    """A leading note-tag prefix (⭐ …) or checkbox in plain text -> (tag, tokens)."""
    if tokens and tokens[0]["type"] == "text":
        raw = tokens[0].get("raw", "")
        tag, rest = _tagged(raw)
        if tag:
            rest_tok = dict(tokens[0]); rest_tok["raw"] = rest
            return tag, [rest_tok] + list(tokens[1:])
    return None, tokens


def _paragraphs(tokens, image_ref=None):
    """A paragraph's inline tokens -> list of (tag, html) per visual line:
    a hard line break starts a new OneNote paragraph."""
    out, cur = [], []
    for t in tokens or []:
        if t["type"] == "linebreak":
            out.append(cur); cur = []
        else:
            cur.append(t)
    out.append(cur)
    result = []
    for line in out:
        tag, line = _tag_prefix(line)
        result.append((tag, _inline_html(line, image_ref)))
    return result


def _p(tag, html):
    level = 0
    while html.startswith("\u00a0" * 4):
        html = html[4:]
        level += 1
    style = P_STYLE if not level else ' style="margin-top:0pt;margin-bottom:0pt;margin-left:%dpx"' % (level * INDENT_PX)
    if tag:
        return '<p data-tag="%s"%s>%s</p>' % (tag, style, html)
    return "<p%s>%s</p>" % (style, html)


def _render_blocks(tokens, out, depth=0, image_ref=None):
    for t in tokens or []:
        ty = t["type"]
        if ty == "blank_line":
            continue
        if ty == "paragraph":
            text = walk_text_local(t.get("children"))
            if text.strip() == "" and GAP in text:
                out.append("<br/>")               # an explicit empty line
                continue
            if _lone_image(t):
                out.append(_img_html(t["children"][0], image_ref))
                continue
            for tag, html in _paragraphs(t.get("children"), image_ref):
                out.append(_p(tag, html))
        elif ty == "heading":
            lvl = min(max(t.get("attrs", {}).get("level", 1), 1), 6)
            out.append("<h%d>%s</h%d>" % (lvl, _inline_html(t.get("children"), image_ref), lvl))
        elif ty == "thematic_break":
            out.append("<p%s>———</p>" % P_STYLE)
        elif ty == "block_code":
            code = _html.escape(t.get("raw", "").rstrip("\n"), quote=False).replace("\n", "<br/>")
            out.append('<p%s><span style="font-family:Consolas">%s</span></p>' % (P_STYLE, code))
        elif ty == "block_quote":
            inner = []
            _render_blocks(t.get("children"), inner, depth, image_ref)
            out.extend(i.replace("<p" + P_STYLE, "<p" + _QUOTE_STYLE, 1) if i.startswith("<p") else i for i in inner)
        elif ty == "list":
            _render_list(t, out, depth, image_ref)
        elif ty == "table":
            _render_table(t, out, image_ref)
        elif ty in ("block_text",):
            for tag, html in _paragraphs(t.get("children"), image_ref):
                out.append(_p(tag, html))
        else:
            if t.get("children"):
                _render_blocks(t["children"], out, depth, image_ref)


def _render_list(t, out, depth, image_ref=None):
    items = t.get("children") or []
    ordered = t.get("attrs", {}).get("ordered", False)
    # A top-level list made only of checkboxes is how OneNote's own to-do
    # paragraphs come back from the editor; write them as such.
    if depth == 0 and items and all(i["type"] == "task_list_item" for i in items) and not any(_has_sublist(i) for i in items):
        for i in items:
            tag = "to-do:completed" if i.get("attrs", {}).get("checked") else "to-do"
            out.append(_p(tag, _item_inline(i, image_ref)))
        return
    out.append("<ol>" if ordered else "<ul>")
    for i in items:
        li = ["<li>"]
        if i["type"] == "task_list_item":
            tag = "to-do:completed" if i.get("attrs", {}).get("checked") else "to-do"
            li.append('<span data-tag="%s">%s</span>' % (tag, _item_inline(i, image_ref)))
        else:
            li.append(_item_inline(i, image_ref))
        for c in i.get("children") or []:
            if c["type"] == "list":
                sub = []
                _render_list(c, sub, depth + 1, image_ref)
                li.extend(sub)
        li.append("</li>")
        out.append("".join(li))
    out.append("</ol>" if ordered else "</ul>")


def _has_sublist(item):
    return any(c["type"] == "list" for c in item.get("children") or [])


def _item_inline(item, image_ref=None):
    parts = []
    for c in item.get("children") or []:
        if c["type"] in ("block_text", "paragraph"):
            parts.append(" ".join(h for _, h in _paragraphs(c.get("children"), image_ref)))
    return " ".join(parts)


def _render_table(t, out, image_ref=None):
    rows = []
    for part in t.get("children") or []:
        if part["type"] == "table_head":
            rows.append([_inline_html(c.get("children"), image_ref) for c in part.get("children") or []])
        elif part["type"] == "table_body":
            for r in part.get("children") or []:
                rows.append([_inline_html(c.get("children"), image_ref) for c in r.get("children") or []])
    out.append('<table style="border:1px solid;border-collapse:collapse">')
    for r in rows:
        out.append("<tr>" + "".join('<td style="border:1px solid">%s</td>' % (c or "<br/>") for c in r) + "</tr>")
    out.append("</table>")


def walk_text_local(tokens):
    out = []
    for t in tokens or []:
        if t["type"] in ("text", "codespan"):
            out.append(t.get("raw", ""))
        elif t["type"] == "softbreak":
            out.append(" ")
        elif t["type"] == "linebreak":
            out.append("\n")
        else:
            out.append(walk_text_local(t.get("children")))
    return "".join(out)


def markdown_to_runs(md, image_ref=None):
    """Markdown -> the page as OneNote sees it: a list of runs.

        [{"kind": "text", "html": "<p>…</p><p>…</p>"},
         {"kind": "image", "html": "<img …/>", "url": "file:///…"}]

    Text runs are what a save rewrites; image runs are what it leaves alone.
    Keeping them apart is the whole reason a page with images can be edited:
    OneNote cannot delete or replace a paragraph, only a whole div, so the
    text between two images is written as one div that can be replaced on its
    own — with the images beside it never touched (docs/engine-notes.md).
    """
    blocks = []
    _render_blocks(_parse(md or ""), blocks, 0, image_ref)
    runs, text = [], []
    for html in blocks:
        if html.startswith("<img"):
            if text:
                runs.append({"kind": "text", "html": "".join(text)})
                text = []
            ref = re.search(r'src="([^"]*)"', html)
            runs.append({"kind": "image", "html": html, "ref": _html.unescape(ref.group(1)) if ref else ""})
        else:
            text.append(html)
    if text:
        runs.append({"kind": "text", "html": "".join(text)})
    return runs


def markdown_to_onenote_html(md, image_ref=None):
    out = []
    _render_blocks(_parse(md), out, 0, image_ref)
    return "\n".join(out) or "<p%s></p>" % P_STYLE
