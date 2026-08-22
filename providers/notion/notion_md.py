"""Notion blocks <-> Markdown, in the dialect Qt's TextEdit reads and writes.

Supported both ways: paragraph, heading_1..3, bulleted_list_item,
numbered_list_item, to_do, quote, code, divider, and nested children as
indentation. Rich text: bold, italic, underline, strikethrough, code, links.
Anything else marks the page as not editable (see blocks_to_markdown()).
"""
import re

SUPPORTED = {"paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item",
             "numbered_list_item", "to_do", "quote", "code", "divider", "toggle"}


# ---------------------------------------------------------------- blocks -> markdown

def rich_to_md(rich):
    out = []
    for r in rich or []:
        t = r.get("plain_text", "")
        a = r.get("annotations", {})
        if not t:
            continue
        lead = t[:len(t) - len(t.lstrip())]
        trail = t[len(t.rstrip()):]
        core = t.strip()
        if core:
            if a.get("code"):
                core = "`%s`" % core
            if a.get("bold"):
                core = "**%s**" % core
            if a.get("italic"):
                core = "*%s*" % core
            if a.get("underline"):
                core = "_%s_" % core
            if a.get("strikethrough"):
                core = "~~%s~~" % core
            href = r.get("href")
            if href:
                core = "[%s](%s)" % (core, href)
        out.append(lead + core + trail)
    return "".join(out)


def blocks_to_markdown(blocks, depth=0):
    """blocks: [{type, <type>: {...}, children: [...]}] -> (markdown, editable)."""
    lines, editable, prev = [], True, None
    pad = "  " * depth
    for b in blocks:
        t = b.get("type")
        body = b.get(t, {}) or {}
        text = rich_to_md(body.get("rich_text"))
        kids = b.get("children") or []
        if t not in SUPPORTED:
            editable = False
            lines.append(pad + "[unsupported: %s]" % t)
            prev = t
            continue
        if t == "divider":
            lines.append("")
            lines.append(pad + "---")
            lines.append("")
        elif t.startswith("heading_"):
            if lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "#" * int(t[-1]) + " " + text)
            lines.append("")
        elif t == "paragraph":
            if prev == "paragraph" and lines and lines[-1] != "":
                lines[-1] = lines[-1] + "  "      # consecutive paragraphs: hard break
            elif prev not in (None, "paragraph") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + text if text else pad + " ")
        elif t == "bulleted_list_item" or t == "toggle":
            if prev not in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "- " + text)
        elif t == "numbered_list_item":
            if prev not in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "1. " + text)
        elif t == "to_do":
            if prev not in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + ("- [x] " if body.get("checked") else "- [ ] ") + text)
        elif t == "quote":
            if lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "> " + text)
            lines.append("")
        elif t == "code":
            if lines and lines[-1] != "":
                lines.append("")
            lang = body.get("language", "") or ""
            lines.append(pad + "```" + ("" if lang in ("plain text", "plain_text") else lang))
            for l in "".join(r.get("plain_text", "") for r in body.get("rich_text", [])).split("\n"):
                lines.append(pad + l)
            lines.append(pad + "```")
            lines.append("")
        if kids:
            sub, ok = blocks_to_markdown(kids, depth + 1)
            if not ok:
                editable = False
            lines.extend(sub.split("\n"))
        prev = t
    # tidy blank runs
    out, blank = [], True
    for l in lines:
        if l.strip() or l.endswith(" "):
            out.append(l)
            blank = False
        elif not blank:
            out.append("")
            blank = True
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out), editable


# ---------------------------------------------------------------- markdown -> blocks

_LINK = re.compile(r"\[([^\]]*)\]\(([^)\s]+)\)")
_TOKEN = re.compile(r"(\*\*.+?\*\*|~~.+?~~|`[^`]+`|(?<![\w*])\*(?!\s)[^*]+?(?<!\s)\*(?![\w*])|(?<!\w)_(?!\s)[^_]+?(?<!\s)_(?!\w))")


def md_to_rich(text, link=None, ann=None):
    """Inline Markdown -> Notion rich_text array."""
    out = []
    ann = dict(ann or {})

    def emit(s, a, href=None):
        if not s:
            return
        item = {"type": "text", "text": {"content": s}}
        if href:
            item["text"]["link"] = {"url": href}
        if a:
            item["annotations"] = dict(a)
        out.append(item)

    pos = 0
    for m in _LINK.finditer(text):
        out.extend(md_to_rich(text[pos:m.start()], None, ann))
        out.extend(md_to_rich(m.group(1), m.group(2), ann))
        pos = m.end()
    rest = text[pos:]
    if pos and not rest:
        return out
    if link is not None:
        # inside a link: no further link parsing, annotations still apply
        for piece, a in _split_tokens(rest, ann):
            emit(piece, a, link)
        return out
    for piece, a in _split_tokens(rest, ann):
        emit(piece, a)
    return out


def _split_tokens(text, ann):
    pieces, pos = [], 0
    for m in _TOKEN.finditer(text):
        if m.start() > pos:
            pieces.append((text[pos:m.start()], ann))
        tok = m.group(0)
        a = dict(ann)
        if tok.startswith("**"):
            a["bold"] = True; inner = tok[2:-2]
        elif tok.startswith("~~"):
            a["strikethrough"] = True; inner = tok[2:-2]
        elif tok.startswith("`"):
            a["code"] = True; inner = tok[1:-1]
            pieces.append((inner, a)); pos = m.end(); continue
        elif tok.startswith("*"):
            a["italic"] = True; inner = tok[1:-1]
        else:
            a["underline"] = True; inner = tok[1:-1]
        pieces.extend(_split_tokens(inner, a))
        pos = m.end()
    if pos < len(text):
        pieces.append((text[pos:], ann))
    return pieces


_LIST = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
_HEAD = re.compile(r"^(#{1,3})\s+(.*)$")


def markdown_to_blocks(md):
    lines = md.replace("\r", "").split("\n")
    root = []
    stack = []   # [(indent, children_list)] for nested lists
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() and " " not in line:
            stack = []
            i += 1
            continue
        if line.strip() == " ":
            root.append({"type": "paragraph", "paragraph": {"rich_text": []}})
            stack = []
            i += 1
            continue
        if line.strip().startswith("```"):
            lang = line.strip()[3:].strip() or "plain text"
            code = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            root.append({"type": "code", "code": {"language": lang, "rich_text": [{"type": "text", "text": {"content": "\n".join(code)[:2000]}}]}})
            stack = []
            continue
        if line.strip() in ("---", "***"):
            root.append({"type": "divider", "divider": {}})
            stack = []
            i += 1
            continue
        m = _HEAD.match(line)
        if m:
            t = "heading_%d" % len(m.group(1))
            root.append({"type": t, t: {"rich_text": md_to_rich(m.group(2).strip())}})
            stack = []
            i += 1
            continue
        if line.lstrip().startswith("> "):
            root.append({"type": "quote", "quote": {"rich_text": md_to_rich(line.lstrip()[2:])}})
            stack = []
            i += 1
            continue
        m = _LIST.match(line)
        if m:
            indent = len(m.group(1).expandtabs(4))
            text = m.group(3).strip()
            todo = re.match(r"\[( |x|X)\] ?(.*)$", text)
            if todo:
                block = {"type": "to_do", "to_do": {"rich_text": md_to_rich(todo.group(2)), "checked": todo.group(1).lower() == "x"}}
            elif m.group(2)[0].isdigit():
                block = {"type": "numbered_list_item", "numbered_list_item": {"rich_text": md_to_rich(text)}}
            else:
                block = {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": md_to_rich(text)}}
            while stack and stack[-1][0] >= indent:
                stack.pop()
            target = stack[-1][1] if stack else root
            target.append(block)
            kids = block[block["type"]].setdefault("children", [])
            stack.append((indent, kids))
            i += 1
            continue
        # paragraph; trailing two spaces were a hard break -> separate paragraphs already
        root.append({"type": "paragraph", "paragraph": {"rich_text": md_to_rich(line.strip())}})
        stack = []
        i += 1
    return _strip_empty_children(root)


def _strip_empty_children(blocks):
    for b in blocks:
        body = b.get(b["type"], {})
        if "children" in body:
            if body["children"]:
                _strip_empty_children(body["children"])
            else:
                del body["children"]
    return blocks
