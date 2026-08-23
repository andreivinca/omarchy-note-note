"""Writing text back out as Markdown, without it being read as Markdown again.

Escaping is deliberately *minimal*: a note that says `2 * 3 = 6` must not grow
a backslash on every save, which is exactly the complaint that Qt's own
Markdown writer earned. A marker is escaped only where it could actually
open or close something — and `reader` verifies the result by re-parsing it,
falling back to `strict` escaping if a single character would have changed
the meaning.
"""
import re

ALWAYS = set("\\`")
# `*` and `~` only mean something next to a non-space character; a lone one
# between spaces is literal in every dialect we care about.
ADJACENT = set("*~")
LINE_START = re.compile(r"^(\s*)([#>]|[-+*](?=\s)|[-=]{3,}\s*$|\|)")
LINE_NUMBER = re.compile(r"^(\s*\d+)([.)])")
STRICT = re.compile(r"([\\*_`~\[\]<>|])")


def escape_inline(text, strict=False):
    """Escape what would otherwise be read as inline Markdown."""
    if not text:
        return ""
    if strict:
        return STRICT.sub(r"\\\1", text)
    link_ahead = "](" in text
    out = []
    for index, char in enumerate(text):
        before = text[index - 1] if index else " "
        after = text[index + 1] if index + 1 < len(text) else " "
        escape = (char in ALWAYS
                  or (char in ADJACENT and not (before.isspace() and after.isspace()))
                  or (char == "_" and _emphasises(before, after))
                  or (char == "<" and (after.isalpha() or after == "/"))
                  or (char in "[]" and link_ahead))
        out.append("\\" + char if escape else char)
    return "".join(out)


def _emphasises(before, after):
    """Could this underscore open or close emphasis?

    Markdown does not read `user_name_field` as emphasis: an underscore only
    counts next to a word boundary, which is why `*` and `_` need different
    rules and why the naive one put a backslash in every identifier.
    """
    opens = not (before.isalnum() or before == "_") and not after.isspace()
    closes = not (after.isalnum() or after == "_") and not before.isspace()
    return opens or closes


def escape_line_start(line):
    """A line start that would become a heading, list, quote, rule or table.

    `**bold**` is not a bullet: only `- `, `+ ` and `* ` followed by a space
    are, which is what keeps emphasis at the start of a line intact.
    """
    line = LINE_START.sub(r"\1\\\2", line or "")
    return LINE_NUMBER.sub(r"\1\\\2", line)
