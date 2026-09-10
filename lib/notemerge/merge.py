"""Line merges with word-level refinement and explicitly resolved conflicts."""
from difflib import SequenceMatcher
import hashlib
import json
import re

from ._vendor.merge3 import Merge3
from .alignment import AmbiguousAlignment, LineMatcher, align, text_key

MAX_TEXT = 2 * 1024 * 1024
MAX_LINES = 20000
MAX_REFINE_TOKENS = 4096


class _TokenMatcher(SequenceMatcher):
    """Spaces and repeated checklist markers are useful alignment anchors."""

    def __init__(self, isjunk, a, b):
        super().__init__(isjunk, a, b, autojunk=False)


def _merge_words(base, local, remote):
    """Refine one line without aligning words across different entries."""
    if local == remote or remote == base:
        return local
    if local == base:
        return remote
    inputs = []
    for text in (base, local, remote):
        tokens = re.findall(r"\r\n|[\r\n]|[^\S\r\n]+|[^\s]+", text)
        if len(tokens) > MAX_REFINE_TOKENS:
            return None
        inputs.append(tokens)
    merged = []
    for part in Merge3(*inputs, sequence_matcher=_TokenMatcher).merge_groups():
        if part[0] == "conflict":
            return None
        merged.extend(part[1])
    return "".join(merged)


def _line_edits(base, changed):
    """Separate replacements/deletions of entries from insertions in gaps."""
    entries = [None] * len(base)
    insertions = {}
    for span in align(base, changed, text_key):
        old_size = span.before_end - span.before_start
        values = changed[span.after_start:span.after_end]
        if span.kind == "insert":
            insertions[span.before_start] = values
        elif span.kind != "delete":
            if old_size != len(values):
                raise AmbiguousAlignment("a structural replacement has no corresponding lines")
            entries[span.before_start:span.before_end] = values
    return entries, insertions


def _merge_line(base, local, remote):
    # Adding a following entry changes the previous line's terminator, not
    # its text. Keep those independent when the other side edits that text.
    contents = [line.rstrip("\r\n") for line in (base, local, remote)]
    endings = [line[len(content):] for line, content in zip((base, local, remote), contents)]
    content = _merge_words(*contents)
    ending = _merge_words(*endings)
    if content is None or ending is None:
        return None
    return content + ending


def _refine(group):
    """Merge aligned entries and their gaps; refine words within one entry.

    Entry state cannot migrate through a token match to an adjacent item.
    Insertions occupy gaps, and editing a deleted entry remains a conflict.
    """
    base, local, remote = group[1:]
    try:
        ours, our_insertions = _line_edits(base, local)
        theirs, their_insertions = _line_edits(base, remote)
    except AmbiguousAlignment:
        return None
    merged = []
    for index in range(len(base) + 1):
        left, right = our_insertions.get(index, []), their_insertions.get(index, [])
        if left and right and left != right:
            return None
        merged.extend(left or right)
        if index == len(base):
            break
        before, left, right = base[index], ours[index], theirs[index]
        if left == right or right == before:
            line = left
        elif left == before:
            line = right
        elif left is None or right is None:
            return None
        else:
            line = _merge_line(before, left, right)
            if line is None:
                return None
        if line is not None:
            merged.append(line)
    return "".join(merged)


def snapshot(note):
    if not isinstance(note, dict):
        raise ValueError("a note snapshot must be an object")
    result = {}
    for field in ("title", "body"):
        value = note.get(field, "")
        if not isinstance(value, str):
            raise ValueError("note %s must be text" % field)
        if len(value.encode("utf-8")) > MAX_TEXT or len(value.splitlines()) > MAX_LINES:
            raise ValueError("note is too large to merge safely")
        result[field] = value
    return result


def fingerprint(value):
    data = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def _groups(base, local, remote, field):
    if local == remote or remote == base:
        return [{"text": local}]
    if local == base:
        return [{"text": remote}]
    if field == "title":
        groups = [("conflict", [base], [local], [remote])]
    else:
        try:
            groups = list(Merge3(base.splitlines(keepends=True), local.splitlines(keepends=True),
                                 remote.splitlines(keepends=True), sequence_matcher=LineMatcher).merge_groups())
        except AmbiguousAlignment:
            # Keep complete inputs for explicit resolution. An arbitrary
            # occurrence match must never become an acknowledged save.
            return [{"id": "body:0", "field": field, "base": base, "local": local, "remote": remote}]
    parts = []
    for group in groups:
        if group[0] == "conflict":
            refined = _refine(group) if field == "body" else None
            if refined is not None:
                parts.append({"text": refined})
                continue
            parts.append({"id": "%s:%d" % (field, len(parts)), "field": field,
                          "base": "".join(group[1]), "local": "".join(group[2]),
                          "remote": "".join(group[3])})
        else:
            parts.append({"text": "".join(group[1])})
    return parts


def _chosen(part, choice):
    if choice in ("local", "remote"):
        return part[choice]
    if choice == "both":
        left, right = part["local"], part["remote"]
        separator = " / " if part["field"] == "title" else "\n"
        if not left or not right or left.endswith("\n"):
            separator = ""
        return left + separator + right
    if isinstance(choice, dict) and isinstance(choice.get("text"), str):
        return choice["text"]
    return None


def merge_note(base, local, remote, resolution=None):
    """Return {note, conflict}; never put conflict markers in a note.

Resolution is {id, choices: {part_id: local|remote|both|{text}}}. Its ID
binds every choice to all three exact inputs, so a changed remote requires
another review. Missing choices leave the entire note unsaved.
    """
    base, local, remote = snapshot(base), snapshot(local), snapshot(remote)
    identity = fingerprint([base, local, remote])
    resolution = resolution or {}
    choices = resolution.get("choices", {}) if resolution.get("id") == identity else {}
    if not isinstance(choices, dict):
        raise ValueError("conflict choices must be an object")
    result, conflicts = {}, []
    unresolved = False
    for field in ("title", "body"):
        pieces = []
        for part in _groups(base[field], local[field], remote[field], field):
            if "text" in part:
                pieces.append(part["text"])
                continue
            conflicts.append(part)
            text = _chosen(part, choices.get(part["id"]))
            if text is None:
                unresolved = True
            else:
                pieces.append(text)
        result[field] = "".join(pieces)
    if unresolved:
        return {"note": None, "conflict": {"id": identity, "parts": conflicts}}
    return {"note": snapshot(result), "conflict": None}
