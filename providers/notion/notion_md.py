"""Notion blocks <-> Markdown, in the dialect Qt's TextEdit reads and writes.

Supported both ways: paragraph, heading_1..3, bulleted_list_item,
numbered_list_item, to_do, quote, code, divider, and nested children as
indentation. Rich text: bold, italic, underline, strikethrough, code, links.
Anything else marks the page as not editable (see blocks_to_markdown()).
"""


# All renderers share escaping and code delimiters.
import os as _os
import sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "..", "..", "services", "markdown"))
from mdtext import escape_text, escape_line_start, code_span, code_fence  # noqa: E402
from parse import parse as _parse  # noqa: E402
SUPPORTED = {"paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item",
             "numbered_list_item", "to_do", "quote", "code", "divider", "toggle"}



# ---------------------------------------------------------------- blocks -> markdown

def _joined_rich(rich):
    """Backend chunk limits must not introduce adjacent Markdown delimiters."""
    out = []
    for item in rich or []:
        if (out and out[-1].get("annotations", {}) == item.get("annotations", {})
                and out[-1].get("href") == item.get("href")):
            out[-1]["plain_text"] += item.get("plain_text", "")
        else:
            out.append(dict(item, plain_text=item.get("plain_text", "")))
    return out


def rich_to_md(rich):
    out = []
    for r in _joined_rich(rich):
        t = r.get("plain_text", "")
        a = r.get("annotations", {})
        if not t:
            continue
        t = t if a.get("code") else escape_text(t)
        lead = t[:len(t) - len(t.lstrip())]
        trail = t[len(t.rstrip()):]
        core = t.strip()
        if core:
            if a.get("code"):
                core = code_span(core)
            if a.get("bold"):
                core = "**%s**" % core
            if a.get("italic"):
                core = "*%s*" % core
            if a.get("underline"):
                core = "_%s_" % core
            if a.get("strikethrough"):
                core = "~~%s~~" % core
            if str(a.get("color", "")).endswith("_background"):
                core = "==%s==" % core
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
            first = (body.get("rich_text") or [{}])[0]
            ann = first.get("annotations") or {}
            plain_start = not ann.get("bold") and not ann.get("italic") and not ann.get("code") and not first.get("href")
            lines.append((pad + (escape_line_start(text) if plain_start else text)) if text else pad + " ")
        elif t == "bulleted_list_item" or t == "toggle":
            if prev not in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "- " + escape_line_start(text))
        elif t == "numbered_list_item":
            if prev not in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "1. " + escape_line_start(text))
        elif t == "to_do":
            if prev not in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle") and lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + ("- [x] " if body.get("checked") else "- [ ] ") + escape_line_start(text))
        elif t == "quote":
            if lines and lines[-1] != "":
                lines.append("")
            lines.append(pad + "> " + text)
            lines.append("")
        elif t == "code":
            if lines and lines[-1] != "":
                lines.append("")
            lang = body.get("language", "") or ""
            code = "".join(r.get("plain_text", "") for r in body.get("rich_text", []))
            fence = code_fence(code)
            lines.append(pad + fence + ("" if lang in ("plain text", "plain_text") else lang))
            for l in code.split("\n"):
                lines.append(pad + l)
            lines.append(pad + fence)
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
#
# Markdown is parsed by the vendored mistune (services/markdown/parse.py);
# this is only the renderer into Notion blocks.



TEXT_LIMIT = 2000
ARRAY_LIMIT = 100
PAYLOAD_LIMIT = 500 * 1024
BLOCK_LIMIT = 1000


def text_items(text, annotations=None, link=None):
    """Keep every character, with the same metadata on each bounded entry."""
    if not isinstance(text, str):
        raise ValueError("note text must be a string")
    if link and len(link) > TEXT_LIMIT:
        raise ValueError("a link exceeds Notion's 2000-character limit")
    out = []
    for start in range(0, len(text), TEXT_LIMIT):
        item = {"type": "text", "text": {"content": text[start:start + TEXT_LIMIT]}}
        if annotations:
            item["annotations"] = dict(annotations)
        if link:
            item["text"]["link"] = {"url": link}
        out.append(item)
    return out


def validate_payload(payload):
    """Check the complete representation before any backend mutation."""
    import json
    blocks = 0

    def visit(value):
        nonlocal blocks
        if isinstance(value, list):
            if len(value) > ARRAY_LIMIT:
                raise ValueError("a Notion array exceeds 100 entries; split the paragraph or document")
            for item in value:
                visit(item)
        elif isinstance(value, dict):
            if value.get("type") in SUPPORTED:
                blocks += 1
            for key, item in value.items():
                if key in ("content", "url") and isinstance(item, str) and len(item) > TEXT_LIMIT:
                    raise ValueError("Notion text or link exceeds 2000 characters")
                visit(item)

    visit(payload)
    if blocks > BLOCK_LIMIT or len(json.dumps(payload).encode("utf-8")) > PAYLOAD_LIMIT:
        raise ValueError("the note exceeds Notion's request size limit")
    return payload


def append_batches(blocks):
    """Plan and validate every append before the first one is sent."""
    batches = [{"children": blocks[i:i + ARRAY_LIMIT]} for i in range(0, len(blocks), ARRAY_LIMIT)]
    for batch in batches:
        validate_payload(batch)
    return batches


def _rich(tokens, ann=None, link=None):
    """Inline tokens -> Notion rich_text array."""
    out = []
    ann = dict(ann or {})

    def emit(text):
        out.extend(text_items(text, ann, link))

    for t in tokens or []:
        ty = t["type"]
        if ty == "text":
            emit(t.get("raw", ""))
        elif ty == "softbreak":
            emit(" ")
        elif ty == "linebreak":
            emit("\n")
        elif ty == "codespan":
            a = dict(ann); a["code"] = True
            out.extend(text_items(t.get("raw", ""), a, link))
        elif ty in ("strong", "emphasis", "underline", "strikethrough"):
            a = dict(ann); a[{"strong": "bold", "emphasis": "italic", "underline": "underline", "strikethrough": "strikethrough"}[ty]] = True
            out.extend(_rich(t.get("children"), a, link))
        elif ty == "mark":
            a = dict(ann); a["color"] = "yellow_background"
            out.extend(_rich(t.get("children"), a, link))
        elif ty == "link":
            out.extend(_rich(t.get("children"), ann, t.get("attrs", {}).get("url", "") or link))
        elif ty == "image":
            emit(t.get("attrs", {}).get("url", ""))
        else:
            out.extend(_rich(t.get("children"), ann, link) if t.get("children") else [])
            if not t.get("children") and t.get("raw"):
                emit(t["raw"])
    return out


def _split_lines(tokens):
    """Inline tokens split at hard line breaks -> list of token lists."""
    out, cur = [], []
    for t in tokens or []:
        if t["type"] == "linebreak":
            out.append(cur); cur = []
        else:
            cur.append(t)
    out.append(cur)
    return out


def _para_blocks(tokens):
    blocks = []
    for line in _split_lines(tokens):
        rich = _rich(line)
        blocks.append({"type": "paragraph", "paragraph": {"rich_text": rich}})
    return blocks


def _list_blocks(t):
    blocks = []
    ordered = t.get("attrs", {}).get("ordered", False)
    for item in t.get("children") or []:
        inline, kids = [], []
        for c in item.get("children") or []:
            if c["type"] in ("block_text", "paragraph"):
                inline.extend(c.get("children") or [])
            elif c["type"] == "list":
                kids.extend(_list_blocks(c))
            else:
                kids.extend(_blocks([c]))
        text = [x for x in inline if x["type"] != "linebreak"]
        if item["type"] == "task_list_item":
            b = {"type": "to_do", "to_do": {"rich_text": _rich(text), "checked": bool(item.get("attrs", {}).get("checked"))}}
        elif ordered:
            b = {"type": "numbered_list_item", "numbered_list_item": {"rich_text": _rich(text)}}
        else:
            b = {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": _rich(text)}}
        if kids:
            b[b["type"]]["children"] = kids
        blocks.append(b)
    return blocks


def _blocks(tokens):
    out = []
    for t in tokens or []:
        ty = t["type"]
        if ty == "blank_line":
            continue
        if ty == "paragraph":
            if "".join(x.get("raw", "") for x in t.get("children") or [] if x["type"] == "text").strip() == "" and " " in "".join(x.get("raw", "") for x in t.get("children") or []):
                out.append({"type": "paragraph", "paragraph": {"rich_text": []}})
            else:
                out.extend(_para_blocks(t.get("children")))
        elif ty == "heading":
            lvl = min(max(t.get("attrs", {}).get("level", 1), 1), 3)
            key = "heading_%d" % lvl
            out.append({"type": key, key: {"rich_text": _rich(t.get("children"))}})
        elif ty == "thematic_break":
            out.append({"type": "divider", "divider": {}})
        elif ty == "block_code":
            lang = (t.get("attrs", {}).get("info") or "plain text").strip() or "plain text"
            out.append({"type": "code", "code": {"language": lang, "rich_text": text_items(t.get("raw", "").removesuffix("\n"))}})
        elif ty == "block_quote":
            inner = _blocks(t.get("children"))
            for b in inner:
                if b["type"] == "paragraph":
                    out.append({"type": "quote", "quote": {"rich_text": b["paragraph"]["rich_text"]}})
                else:
                    out.append(b)
        elif ty == "list":
            out.extend(_list_blocks(t))
        elif ty == "table":
            # Notion tables need a table block with typed rows; keep it simple and readable.
            for part in t.get("children") or []:
                rows = [part] if part["type"] == "table_head" else (part.get("children") or [])
                for r in rows:
                    cells = [_rich(c.get("children")) for c in r.get("children") or []]
                    rich = []
                    for k, c in enumerate(cells):
                        if k:
                            rich.append({"type": "text", "text": {"content": " | "}})
                        rich.extend(c)
                    out.append({"type": "paragraph", "paragraph": {"rich_text": rich}})
        elif ty == "block_text":
            out.extend(_para_blocks(t.get("children")))
        elif t.get("children"):
            out.extend(_blocks(t["children"]))
    return out


def markdown_to_blocks(md):
    return _blocks(_parse(md))
