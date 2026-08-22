"""Markdown -> AST for the providers, on top of the vendored mistune.

Parses the dialect Qt's TextEdit writes: GitHub task lists, tables,
~~strikethrough~~, ==highlight== (mark), and `_underline_` (Qt stores
underline as _x_, italic as *x*). Backslash escapes come out resolved, soft wraps appear as `softbreak`
and "two spaces + newline" as `linebreak`. Renderers live with the providers.
"""
import os
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


def parse(markdown):
    """Markdown text -> list of mistune AST tokens."""
    return _md(markdown.replace("\r", ""))


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
