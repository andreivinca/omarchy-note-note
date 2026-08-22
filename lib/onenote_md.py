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


# ---------------------------------------------------------------- HTML -> Markdown

class Converter:
    def __init__(self, image_path_for=None):
        self.lines = []
        # What the previous emitted block was: consecutive plain paragraphs
        # are joined with hard line breaks, because OneNote writes one <p>
        # per visual line and Markdown would otherwise flow them together.
        self.last = None
        self.editable = True
        self.images = []          # [(src, alt)]
        # (src, declared width or 0) -> url/path to show
        self.image_path_for = image_path_for or (lambda src, width: src)

    # -- inline --------------------------------------------------------
    def inline(self, node):
        out = []
        for c in node.children:
            if c.tag is None:
                out.append(re.sub(r"\s+", " ", c.text))
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
                self.images.append((src, alt))
                self.editable = False          # images cannot be written back yet
                try:
                    width = int(float(c.attrs.get("width", "0") or 0))
                except ValueError:
                    width = 0
                out.append("![%s](%s)" % (alt, self.image_path_for(src, width)))
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
        if t == "p" or t == "cite":
            text = self.inline(node).strip()
            prefix = self.para_prefix(node) if t == "p" else "*"
            if t == "cite":
                text = "*%s*" % text if text else ""
                prefix = ""
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

_INLINE_RULES = [
    (re.compile(r"\*\*(.+?)\*\*"), r"<b>\1</b>"),
    (re.compile(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"), r"<i>\1</i>"),
    (re.compile(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"), r"<u>\1</u>"),
    (re.compile(r"~~(.+?)~~"), r"<s>\1</s>"),
    (re.compile(r"`(.+?)`"), r"<span style=\"font-family:Consolas\">\1</span>"),
]
_LINK = re.compile(r"\[([^\]]*)\]\(([^)\s]+)\)")


def md_inline(text):
    text = text.replace("\\|", "|")
    # links first (their URL must not be touched by the emphasis rules)
    parts, pos = [], 0
    for m in _LINK.finditer(text):
        parts.append(_inline_plain(text[pos:m.start()]))
        parts.append('<a href="%s">%s</a>' % (_html.escape(m.group(2), quote=True), _inline_plain(m.group(1))))
        pos = m.end()
    parts.append(_inline_plain(text[pos:]))
    return "".join(parts)


def _inline_plain(text):
    s = _html.escape(text, quote=False)
    for rx, rep in _INLINE_RULES:
        s = rx.sub(rep, s)
    return s


def _tagged(text):
    """Split a leading note-tag prefix / checkbox off a paragraph's text."""
    m = re.match(r"\[( |x|X)\] ?(.*)$", text)
    if m:
        return ("to-do:completed" if m.group(1).lower() == "x" else "to-do"), m.group(2)
    for prefix, tag in PREFIX_TAG.items():
        if text.startswith(prefix + " ") or text == prefix:
            return tag, text[len(prefix):].lstrip()
    return None, text


_LIST = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
_HEAD = re.compile(r"^(#{1,6})\s+(.*)$")


def markdown_to_onenote_html(md):
    lines = md.replace("\r", "").split("\n")
    out, i = [], 0
    list_stack = []   # [(indent, kind)]
    prev_plain, gap = False, False     # a blank line between two plain paragraphs is a visual gap

    def close_lists(to_indent=-1):
        while list_stack and list_stack[-1][0] > to_indent:
            out.append("</li></%s>" % list_stack.pop()[1])

    while i < len(lines):
        line = lines[i]
        if not line.strip():
            close_lists()
            if GAP in line:                 # an explicit empty line (see GAP)
                out.append("<br/>")
                prev_plain, gap = False, False
            else:
                gap = True
            i += 1
            continue
        m = _HEAD.match(line)
        if m:
            close_lists()
            out.append("<h%d>%s</h%d>" % (len(m.group(1)), md_inline(m.group(2).strip()), len(m.group(1))))
            prev_plain, gap = False, False
            i += 1
            continue
        if line.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-+", lines[i + 1]):
            close_lists()
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                rows.append(cells)
                i += 1
            rows = [r for k, r in enumerate(rows) if k != 1]     # drop the separator row
            out.append('<table style="border:1px solid;border-collapse:collapse">')
            for r in rows:
                out.append("<tr>" + "".join('<td style="border:1px solid">%s</td>' % (md_inline(c) or "<br/>") for c in r) + "</tr>")
            out.append("</table>")
            prev_plain, gap = False, False
            continue
        m = _LIST.match(line)
        if m:
            indent = len(m.group(1).expandtabs(4))
            kind = "ol" if m.group(2)[0].isdigit() else "ul"
            tag, text = _tagged(m.group(3).strip())
            if indent == 0 and tag and tag.startswith("to-do") and not list_stack:
                # A top-level checkbox is a OneNote to-do paragraph, not a bullet.
                out.append('<p data-tag="%s">%s</p>' % (tag, md_inline(text)))
                prev_plain, gap = False, False
                i += 1
                continue
            if list_stack and indent > list_stack[-1][0]:
                out[-1] = out[-1][:-len("</li>")] if out and out[-1].endswith("</li>") else out[-1]
                out.append("<%s><li>" % kind)
                list_stack.append((indent, kind))
            else:
                close_lists(indent)
                if list_stack and list_stack[-1][0] == indent:
                    out.append("</li><li>")
                else:
                    out.append("<%s><li>" % kind)
                    list_stack.append((indent, kind))
            content = md_inline(text)
            out.append('<span data-tag="%s">%s</span>' % (tag, content) if tag else content)
            prev_plain, gap = False, False
            # mark the li as open; closed by the next sibling or close_lists
            out[-1] = out[-1]  # no-op for clarity
            i += 1
            continue
        close_lists()
        tag, text = _tagged(line.strip())
        para = md_inline(text.replace("  \n", "<br/>"))
        if not tag and prev_plain and gap:
            out.append("<br/>")
        out.append('<p data-tag="%s">%s</p>' % (tag, para) if tag else "<p>%s</p>" % para)
        prev_plain, gap = not tag, False
        i += 1
    close_lists()
    # The list builder emits "<ul><li>" ... "</li></ul>" with "</li><li>" between
    # items; join with newlines for readability.
    return "\n".join(out) or "<p></p>"
