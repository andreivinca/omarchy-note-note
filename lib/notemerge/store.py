"""Private recovery journals and editing baselines shared by all providers.

A view tracks the last *local* document accepted from that editor. The remote
can include additional merged edits the editor has not displayed yet. Keeping
these separate lets the next autosave build on its own actual editing base.
"""
import fcntl
import json
import os
from pathlib import Path
import time
import uuid

from provider_io import save_private
from .merge import fingerprint, merge_note, snapshot


class StaleRemote(Exception):
    """The backend returned a known version from before our last write."""


class DraftOwnedByAnotherView(ValueError):
    """Resolve the pending draft before another editor starts a save."""


class MergeStore:
    def __init__(self, root, provider, account, document, normalize=snapshot, stale_seconds=0):
        if not all(isinstance(value, str) and value for value in (provider, account, document)):
            raise ValueError("merge storage requires provider, account and document identities")
        self.directory = Path(root) / fingerprint([provider, account, document])
        self.path = self.directory / "state.json"
        self._state = None
        self.lock = None
        self.normalize = normalize
        self.stale_seconds = stale_seconds

    def note(self, value):
        return snapshot(self.normalize(snapshot(value)))

    def __enter__(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(self.directory / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        self.lock = os.fdopen(fd, "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            try:
                with self.path.open(encoding="utf-8") as stream:
                    self._state = json.load(stream)
            except FileNotFoundError:
                self._state = {"version": 1, "views": {}, "draft": None, "history": [],
                              "expected": None, "stale": []}
            if self._state.get("version") != 1 or not isinstance(self._state.get("views"), dict):
                raise ValueError("unrecognized merge journal; recovery data was preserved")
            return self
        except BaseException:
            self.lock.close()
            raise

    def __exit__(self, *exc):
        self.lock.close()

    def _persist(self):
        save_private(str(self.path), self._state)

    def _view(self, note, protected=None):
        token = uuid.uuid4().hex
        self._state["views"][token] = self.note(note)
        # Older tabs fail closed if their token expires. An unresolved draft
        # always retains its original baseline, including across restarts.
        protected = protected or (self._state.get("draft") or {}).get("view")
        for old in list(self._state["views"]):
            if len(self._state["views"]) <= 12:
                break
            if old != protected:
                del self._state["views"][old]
        return token

    def check_remote(self, remote):
        remote = self.note(remote)
        expected = self._state["expected"]
        recent = time.time() - self._state.get("writtenAt", 0) < self.stale_seconds
        if recent and expected and remote != self.note(expected) and fingerprint(remote) in self._state["stale"]:
            raise StaleRemote("the provider has not yet returned the previous save")

    def recover(self):
        """Return a pending editor draft, without requiring a remote read."""
        draft = self._state["draft"]
        if draft:
            result = dict(draft["local"], view=draft["view"], recovered=True)
            if draft.get("conflict"):
                # Re-evaluate persisted conflicts with the current engine.
                # A clean result still needs a new remote fetch before save.
                base = draft["base"]
                current = merge_note(self.note(base), self.note(draft["local"]), self.note(draft["remote"]))
                if current["conflict"]:
                    result["conflict"] = current["conflict"]
                else:
                    result["retry"] = True
            return result
        return None

    def open(self, remote, recover=True):
        recovered = self.recover() if recover else None
        if recovered is not None:
            return recovered
        remote = self.note(remote)
        self.check_remote(remote)
        token = self._view(remote)
        self._persist()
        return dict(remote, view=token)

    def stage(self, view, local):
        """Persist local intent, replacing only this view's own pending draft."""
        if view not in self._state["views"]:
            raise ValueError("the original note version is unavailable; reopen the note before saving")
        pending = self._state["draft"]
        if pending and pending["view"] != view:
            raise DraftOwnedByAnotherView("another editing view has unsaved changes; resolve its draft before saving")
        self._state["draft"] = {"view": view, "base": self.note(self._state["views"][view]),
                               "local": self.note(local)}
        self._persist()

    def prepare(self, remote, resolution=None):
        self.check_remote(remote)
        draft = self._state["draft"]
        base = self.note(draft["base"])
        remote = self.note(remote)
        result = merge_note(base, self.note(draft["local"]), remote, resolution)
        draft.update(remote=remote, target=result["note"], conflict=result["conflict"])
        self._persist()  # The three inputs survive a failed/uncertain write.
        return result

    def commit(self, saved, accepted_fields=("title", "body")):
        """Acknowledge saved fields, keeping the remaining local intent staged.

        The adapter supplies the actual saved snapshot and names the fields
        its backend accepted. Baseline advancement and recovery belong here.
        """
        saved = self.note(saved)
        draft = self._state["draft"]
        fields = set(accepted_fields)
        if not fields or not fields.issubset(saved):
            raise ValueError("accepted fields must name saved note fields")
        accepted = self.note(self._state["views"][draft["view"]])
        for field in fields:
            accepted[field] = draft["local"][field]
        self._state["views"][draft["view"]] = accepted
        self._state["history"] = (self._state["history"] + [dict(draft, saved=saved, accepted=sorted(fields))])[-3:]
        stale = self._state["stale"] + [fingerprint(draft["remote"])]
        self._state["stale"] = list(dict.fromkeys(stale))[-12:]
        self._state["expected"] = saved
        self._state["writtenAt"] = time.time()
        if fields == set(saved):
            self._state["draft"] = None
        else:
            self._state["draft"] = dict(draft, base=accepted, remote=saved)
        token = self._view(saved, protected=draft["view"])
        self._persist()
        return dict(saved, view=token)

    def discard(self):
        """Called only after the provider confirms deletion of this note."""
        self._state["draft"] = None
        self._state["views"] = {}
        self._state["expected"] = None
        self._state["stale"] = []
        self._persist()
