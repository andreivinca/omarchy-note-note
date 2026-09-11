"""The safe, portable foreground-color span used by every document adapter."""
import re

import htmltree

# CSS basic colors; custom colors use hex or RGB, including OneNote exports.
_NAMES = dict(zip(
    "black silver gray white maroon red purple fuchsia green lime olive yellow navy blue teal aqua orange".split(),
    "000000 c0c0c0 808080 ffffff 800000 ff0000 800080 ff00ff 008000 00ff00 808000 ffff00 000080 0000ff 008080 00ffff ffa500".split()))


def normalize(value):
    value = (value or "").strip().lower()
    if value in _NAMES:
        return "#" + _NAMES[value]
    if re.fullmatch(r"#[0-9a-f]{3}", value):
        return "#" + "".join(c * 2 for c in value[1:])
    if re.fullmatch(r"#[0-9a-f]{6}", value):
        return value
    match = re.fullmatch(r"rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)", value)
    if match and all(int(c) <= 255 for c in match.groups()):
        return "#" + "".join("%02x" % int(c) for c in match.groups())
    return ""


def from_style(style):
    color = ""
    for part in (style or "").split(";"):
        name, separator, value = part.partition(":")
        if separator and name.strip().lower() == "color":
            color = normalize(value)
    return color


def span(color, body):
    color = normalize(color)
    return '<span style="color:%s;">%s</span>' % (color, body) if color else body


def _parse_span(inline, match, state):
    opening = htmltree.parse(match.group(0)).children
    if len(opening) != 1 or opening[0].tag != "span":
        return None
    attrs = opening[0].attrs
    color = from_style(attrs.get("style", ""))
    if not color or set(attrs) != {"style"}:
        return None
    # Balance nested spans before parsing their contents as ordinary inline
    # Markdown. Unclosed or unsupported HTML stays literal text.
    depth = 1
    for closing in re.finditer(r"</?span\b[^>]*>", state.src[match.end():], re.I):
        depth += -1 if closing.group(0).startswith("</") else 1
        if depth:
            continue
        end = match.end() + closing.start()
        child = state.copy()
        child.src = state.src[match.end():end]
        state.append_token({"type": "text_color", "attrs": {"color": color},
                            "children": inline.render(child)})
        return match.end() + closing.end()
    return None


def plugin(md):
    md.inline.register("text_color", r"<span\b[^>]*>", _parse_span, before="inline_html")
