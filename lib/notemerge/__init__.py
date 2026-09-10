"""Provider-independent three-way merging of plain-text or Markdown notes.

Providers supply comparable snapshots, fetch/write their own remote content,
and decide which document features they can preserve. No network or UI here.
"""
from .merge import fingerprint, merge_note, snapshot
from .alignment import AmbiguousAlignment, align, text_key
from .store import DraftOwnedByAnotherView, MergeStore, StaleRemote

__all__ = ["AmbiguousAlignment", "DraftOwnedByAnotherView", "MergeStore", "StaleRemote",
           "align", "fingerprint", "merge_note", "snapshot", "text_key"]
