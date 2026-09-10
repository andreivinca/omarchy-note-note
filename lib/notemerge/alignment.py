"""Ordered sequence alignment shared by text mergers and provider adapters.

Keys describe an entry independently of its mutable attributes. Repeated
keys retain their occurrence order. If only some indistinguishable entries
are added or removed, there is no identity evidence: callers must request
review instead of choosing an arbitrary surviving entry.
"""
from collections import Counter
from dataclasses import dataclass
from difflib import SequenceMatcher
import re


class AmbiguousAlignment(ValueError):
    """Text alone cannot identify which repeated entry changed."""


@dataclass(frozen=True)
class Span:
    kind: str
    before_start: int
    before_end: int
    after_start: int
    after_end: int


CHECKBOX = re.compile(r"^([ \t]*(?:(?:[-+*]|[0-9]+[.)])[ \t]+)?\[)[ xX](\])", re.MULTILINE)


def text_key(text):
    """A Markdown entry's label and structure, independent of check states.

    This is only an alignment key. Callers still compare the complete entry
    to detect changes to its check state, whitespace, and terminal newline.
    None denotes a separator without its own identity.
    """
    value = CHECKBOX.sub(r"\1 \2", text).rstrip("\r\n")
    return value if value.strip() else None


def _occurrences(keys):
    seen = Counter()
    result = []
    for key in keys:
        result.append((key, seen[key]))
        seen[key] += 1
    return result


def align(before, after, key):
    """Return immutable spans between sequences of arbitrary provider values.

    `key(value)` must return a hashable identity, or None for separators.
    Equal spans mean matching identities, not necessarily equal content.
    Replacements remain explicit spans; adapters decide which operations
    their backend supports. There is no HTML, network, or storage policy here.
    """
    old_keys, new_keys = [key(value) for value in before], [key(value) for value in after]
    old_counts, new_counts = Counter(old_keys), Counter(new_keys)
    for identity in old_counts.keys() & new_counts.keys():
        old_count, new_count = old_counts[identity], new_counts[identity]
        if identity is not None and old_count != new_count and max(old_count, new_count) > 1:
            raise AmbiguousAlignment("cannot identify which repeated entry was inserted, removed, or renamed")
    matcher = SequenceMatcher(None, _occurrences(old_keys), _occurrences(new_keys), autojunk=False)
    return tuple(Span(*span) for span in matcher.get_opcodes())


class LineMatcher:
    """merge3 matcher that anchors entry identities but compares actual text.

    A changed checkbox is never declared an unchanged line. Its identity
    only determines which original entry that change belongs to.
    """

    def __init__(self, isjunk, before, after):
        self.before = before
        self.after = after

    def get_matching_blocks(self):
        blocks = []
        for span in align(self.before, self.after, text_key):
            if span.kind != "equal":
                continue
            for old, new in zip(range(span.before_start, span.before_end), range(span.after_start, span.after_end)):
                if self.before[old] != self.after[new]:
                    continue
                if blocks and blocks[-1][0] + blocks[-1][2] == old and blocks[-1][1] + blocks[-1][2] == new:
                    start, target, length = blocks[-1]
                    blocks[-1] = (start, target, length + 1)
                else:
                    blocks.append((old, new, 1))
        blocks.append((len(self.before), len(self.after), 0))
        return blocks
