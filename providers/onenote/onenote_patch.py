"""Translate shared sequence alignment into identity-preserving Graph edits.

Planning has no I/O. Unsupported edits and invalid simulations are errors;
neither authorizes a broader replacement. Graph capabilities are documented
at https://learn.microsoft.com/en-us/graph/onenote-update-page.
"""
import copy
from dataclasses import dataclass
import html

from notemerge import AmbiguousAlignment, align, text_key
from onenote_md import Converter, Node, TreeBuilder

REPLACEABLE = {"p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "img"}
LISTS = {"ul", "ol"}
LAYOUT = {"html", "body", "div"}


class UnsupportedEdit(ValueError):
    """The available Graph targets cannot preserve this edit's neighbours."""


class InvalidPlan(ValueError):
    """A planned operation violated the document or preservation contract."""


@dataclass(frozen=True)
class Plan:
    commands: tuple
    simulated: str
    preserved_ids: frozenset


def parse(source):
    builder = TreeBuilder()
    builder.feed(source)
    return builder.root


def walk(node):
    yield node
    for child in node.children:
        yield from walk(child)


def serialize(node, keep_ids=False):
    if node.tag is None:
        return html.escape(node.text or "", quote=False)
    content = "".join(serialize(child, keep_ids) for child in node.children)
    if node.tag == "root":
        return content
    attrs = "".join(' %s="%s"' % (key, html.escape(value or "", quote=True))
                    for key, value in node.attrs.items() if keep_ids or key != "id")
    if node.tag in TreeBuilder.VOID:
        return "<%s%s/>" % (node.tag, attrs)
    return "<%s%s>%s</%s>" % (node.tag, attrs, content, node.tag)


def children(node):
    return [child for child in node.children
            if child.tag not in {"head", "title", "meta", "style"}
            and (child.tag is not None or (child.text or "").strip())]


def elements(root):
    """Flatten layout wrappers, leaving lists and tables as nested scopes."""
    result = []
    for node in children(root):
        if node.tag in LAYOUT:
            result.extend(elements(node))
        else:
            result.append(node)
    return result


def text(node):
    converter = Converter(lambda src, width: src)
    converter.block(node)
    return converter.result()


def identity(node):
    return text_key(text(node))


def target(node):
    value = node.attrs.get("id", "")
    if node.tag not in REPLACEABLE or not value.startswith(node.tag + ":"):
        raise UnsupportedEdit("OneNote supplied no editable target for this %s element" % (node.tag or "text"))
    return value


def replacement(old, new):
    if identity(old) != identity(new):
        return new
    # Only checkbox state differs. The carrier may be the paragraph itself
    # or an inline span inside a list item. Preserve its original HTML and
    # tag kind, including formatting that Markdown cannot represent.
    updated = copy.deepcopy(old)
    original = checkbox_carriers(updated)
    desired = checkbox_carriers(new)
    if len(original) != 1 or len(desired) != 1:
        raise UnsupportedEdit("this checkbox has no unique state carrier")
    carrier = original[0]
    tag = carrier.attrs["data-tag"].removesuffix(":completed")
    if desired[0].attrs["data-tag"].endswith(":completed"):
        tag += ":completed"
    carrier.attrs["data-tag"] = tag
    if text(updated) != text(new):
        raise UnsupportedEdit("this checkbox state cannot be changed without altering its content")
    return updated


def checkbox_carriers(node):
    return [child for child in walk(node) if child.attrs.get("data-tag", "").startswith("to-do")]


class _Planner:
    def __init__(self, tree):
        self.tree = tree
        self.insertions = []
        self.replacements = []
        self.retained = {}

    def retain(self, node, subtree=True):
        for original in walk(node) if subtree else (node,):
            identifier = original.attrs.get("id")
            if identifier:
                content = serialize(original, keep_ids=True) if subtree else None
                self.retained[identifier] = (original.tag, dict(original.attrs), content)

    def sequence(self, before, after, container):
        for span in align(before, after, identity):
            old = before[span.before_start:span.before_end]
            new = after[span.after_start:span.after_end]
            shared = min(len(old), len(new))
            for original, desired in zip(old, new):
                self.update(original, desired)
            for original in old[shared:]:
                self.replacements.append({"target": target(original), "action": "replace", "content": "<div></div>"})
            if new[shared:]:
                self.insert(new[shared:], before, span.before_end, container)

    def insert(self, additions, before, index, container):
        content = "".join(serialize(node) for node in additions)
        if index < len(before) and before[index].tag in REPLACEABLE:
            command = {"target": target(before[index]), "action": "insert", "position": "before"}
        elif index > 0 and before[index - 1].tag in REPLACEABLE:
            command = {"target": target(before[index - 1]), "action": "insert", "position": "after"}
        elif not before and container.tag in LISTS | {"body", "div"}:
            identifier = container.attrs.get("id")
            if container.tag != "body" and not identifier:
                raise UnsupportedEdit("OneNote supplied no target for this empty container")
            command = {"target": identifier or "body", "action": "append"}
        else:
            raise UnsupportedEdit("OneNote supplied no insertion target at this position")
        self.insertions.append(dict(command, content=content))

    def update(self, old, new):
        if text(old) == text(new):
            self.retain(old)
            return
        if old.tag == new.tag and old.tag in LISTS:
            self.retain(old, subtree=False)
            self.sequence(children(old), children(new), old)
            return
        if old.tag == new.tag == "li" and any(child.tag in LISTS for child in old.children + new.children):
            self.nested_item(old, new)
            return
        if old.tag == new.tag == "table":
            self.table(old, new)
            return
        if any(child.tag in REPLACEABLE for child in list(walk(old))[1:]):
            raise UnsupportedEdit("this restructure would replace nested elements; edit it in OneNote")
        self.replacements.append({"target": target(old), "action": "replace",
                                  "content": serialize(replacement(old, new))})

    def nested_item(self, old, new):
        def inline(item):
            holder = Node("li")
            holder.children = [child for child in item.children if child.tag not in LISTS]
            return text(holder)

        if inline(old) != inline(new):
            raise UnsupportedEdit("this list text has no separate target from its nested list; edit it in OneNote")
        self.retain(old, subtree=False)
        self.sequence([child for child in old.children if child.tag in LISTS],
                      [child for child in new.children if child.tag in LISTS], old)

    def table(self, old, new):
        # Graph cannot replace rows or cells. A cell's existing paragraph can
        # be edited without destroying the identities of the other cells.
        old_rows = [node for node in walk(old) if node.tag == "tr"]
        new_rows = [node for node in walk(new) if node.tag == "tr"]
        if len(old_rows) != len(new_rows):
            raise UnsupportedEdit("OneNote cannot change this table's rows without rebuilding it")
        self.retain(old, subtree=False)
        converter = Converter(lambda src, width: src)
        for old_row, new_row in zip(old_rows, new_rows):
            old_cells = [node for node in children(old_row) if node.tag in {"td", "th"}]
            new_cells = [node for node in children(new_row) if node.tag in {"td", "th"}]
            if len(old_cells) != len(new_cells):
                raise UnsupportedEdit("OneNote cannot change this table's columns without rebuilding it")
            self.retain(old_row, subtree=False)
            for old_cell, new_cell in zip(old_cells, new_cells):
                if converter.inline(old_cell) == converter.inline(new_cell):
                    self.retain(old_cell)
                    continue
                content = children(old_cell)
                if len(content) != 1 or content[0].tag != "p":
                    raise UnsupportedEdit("this table cell has no editable paragraph; edit it in OneNote")
                self.retain(old_cell, subtree=False)
                paragraph = Node("p")
                paragraph.children = new_cell.children
                self.update(content[0], paragraph)

    def finish(self):
        # Insertions use original anchors, which still exist before any
        # replacements. Simulate exactly that same command order.
        commands = tuple(self.insertions + self.replacements)
        simulated = simulate(self.tree, commands)
        by_id = {node.attrs["id"]: node for node in walk(simulated) if node.attrs.get("id")}
        for identifier, (tag, attrs, content) in self.retained.items():
            kept = by_id.get(identifier)
            if kept is None or kept.tag != tag or kept.attrs != attrs:
                raise InvalidPlan("an unchanged element lost its identity")
            if content is not None and serialize(kept, keep_ids=True) != content:
                raise InvalidPlan("an unchanged element was modified")
        return Plan(commands, serialize(simulated, keep_ids=True), frozenset(self.retained))


def simulate(tree, commands):
    """Apply the public Graph operations, independently of the alignment."""
    tree = copy.deepcopy(tree)
    for command in commands:
        identifier = command["target"]
        if identifier == "body":
            bodies = [node for node in walk(tree) if node.tag == "body"]
            parent = bodies[0] if bodies else tree
            node = next((child for child in parent.children if child.tag == "div"), parent)
        else:
            matches = [(parent, node) for parent in walk(tree) for node in parent.children
                       if node.attrs.get("id") == identifier]
            if len(matches) != 1:
                raise InvalidPlan("an operation targets a missing or repeated element")
            parent, node = matches[0]
        content = parse(command["content"]).children
        if command["action"] == "append":
            node.children.extend(content)
        else:
            position = parent.children.index(node)
            if command["action"] == "replace":
                parent.children[position:position + 1] = content
            elif command["action"] == "insert":
                position += int(command["position"] == "after")
                parent.children[position:position] = content
            else:
                raise InvalidPlan("unsupported operation")
    return tree


def plan(current, desired):
    """Return a validated Plan, or raise UnsupportedEdit/InvalidPlan."""
    tree, desired_tree = parse(current), parse(desired)
    bodies = [node for node in walk(tree) if node.tag == "body"]
    body = bodies[0] if bodies else tree
    planner = _Planner(tree)
    try:
        planner.sequence(elements(body), elements(desired_tree), body)
    except AmbiguousAlignment as error:
        raise UnsupportedEdit(str(error)) from error
    return planner.finish()
