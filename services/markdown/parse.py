"""Markdown -> AST for the providers, on top of the vendored mistune.

Parses the dialect Qt's TextEdit writes: GitHub task lists, tables,
~~strikethrough~~, ==highlight== (mark), and `_underline_` (Qt stores
underline as _x_, italic as *x*). Backslash escapes come out resolved, soft wraps appear as `softbreak`
and "two spaces + newline" as `linebreak`. Renderers live with the providers.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mistune  # noqa: E402
from mistune.plugins.formatting import _parse_to_end  # noqa: E402

UNDERLINE_PATTERN = r"(?<![\w_])_(?!\s)(?:\\_|[^_\n])+?(?<!\s)_(?![\w_])"


def _parse_underline(inline, m, state):
    # Reuse mistune's delimited-span parser; marker is "_", one character.
    pos = m.start() + 1
    text = m.group(0)[1:-1]
    new_state = state.copy()
    new_state.src = text
    children = inline.render(new_state)
    state.append_token({"type": "underline", "children": children})
    return m.end()


def _underline_plugin(md):
    md.inline.register("underline", UNDERLINE_PATTERN, _parse_underline, before="emphasis")


_md = mistune.create_markdown(renderer=None, plugins=["task_lists", "strikethrough", "table", "mark", _underline_plugin])

# A display width the author chose, written right after an image the way
# pandoc writes attributes: `![alt](pic.png){width=320}`. mistune leaves it
# as literal text after the image token; `parse` folds it into the token's
# attrs, so every renderer sees a width and no reader ever sees the marker
# as note text. Anything not exactly this shape stays what it is: text.
IMAGE_WIDTH = re.compile(r"^\{width=(\d{1,5})\}")


def _absorb_image_widths(tokens):
    for index, token in enumerate(tokens[:-1]):
        follower = tokens[index + 1]
        if token.get("type") != "image" or follower.get("type") != "text":
            continue
        m = IMAGE_WIDTH.match(follower.get("raw", ""))
        if not m:
            continue
        token.setdefault("attrs", {})["width"] = int(m.group(1))
        follower["raw"] = follower["raw"][m.end():]
    tokens[:] = [t for t in tokens if not (t.get("type") == "text" and t.get("raw") == "")]
    for token in tokens:
        if token.get("children"):
            _absorb_image_widths(token["children"])


def parse(markdown):
    """Markdown text -> list of mistune AST tokens."""
    tokens = _md(markdown.replace("\r", ""))
    _absorb_image_widths(tokens)
    return tokens


def walk_text(tokens):
    """Plain text of an inline token list (links/emphasis flattened)."""
    out = []
    for t in tokens or []:
        if t["type"] in ("text", "codespan"):
            out.append(t.get("raw", ""))
        elif t["type"] == "softbreak":
            out.append(" ")
        elif t["type"] == "linebreak":
            out.append("\n")
        else:
            out.append(walk_text(t.get("children")))
    return "".join(out)
