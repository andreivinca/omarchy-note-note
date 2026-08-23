"""A tiny HTML tree, built with the standard library's own parser.

Qt writes well-formed HTML, so this stays deliberately small: enough to walk
blocks and inline runs, and nothing that would tempt anyone to treat it as a
general HTML implementation.
"""
from html.parser import HTMLParser

# Written as <br/> or <hr/>; never carry children.
VOID_TAGS = {"br", "hr", "img", "meta", "link", "input"}
# Everything a document's structure is made of; the rest is inline.
SKIPPED_TAGS = {"head", "style", "script", "title", "meta"}


class Node:
    __slots__ = ("tag", "attrs", "children", "text", "parent")

    def __init__(self, tag, attrs=None, text=None, parent=None):
        self.tag = tag
        self.attrs = dict(attrs or [])
        self.children = []
        self.text = text
        self.parent = parent

    @property
    def style(self):
        return self.attrs.get("style", "")

    def find(self, tag):
        """Direct children with this tag."""
        return [c for c in self.children if c.tag == tag]

    def __repr__(self):                                    # debugging only
        return "<%s %r>" % (self.tag or "text", self.text if self.tag is None else self.attrs)


class _Builder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("body")
        self.stack = [self.root]
        self.skipping = 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIPPED_TAGS:
            self.skipping += 1
            return
        if self.skipping:
            return
        node = Node(tag, attrs, parent=self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        if not self.skipping:
            self.stack[-1].children.append(Node(tag, attrs, parent=self.stack[-1]))

    def handle_endtag(self, tag):
        if tag in SKIPPED_TAGS:
            self.skipping = max(0, self.skipping - 1)
            return
        if self.skipping or tag in VOID_TAGS:
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        if not self.skipping:
            self.stack[-1].children.append(Node(None, text=data, parent=self.stack[-1]))


def parse(html):
    """HTML -> a `body` Node. Qt's wrapper document is unwrapped for us."""
    builder = _Builder()
    builder.feed(html or "")
    builder.close()
    body = builder.root.find("body")
    if body:
        return body[0]
    html_nodes = builder.root.find("html")
    if html_nodes:
        inner = html_nodes[0].find("body")
        if inner:
            return inner[0]
    return builder.root
