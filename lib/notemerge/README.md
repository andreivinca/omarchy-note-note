# Shared note merging

`notemerge` is the common Python merge layer for providers. It has no Graph,
Notion, filesystem-note format, editor, or network dependencies. `merge3`
0.0.16 is bundled unmodified under `_vendor/merge3/`, including its
GPL-2.0-or-later license. No pip installation is needed.

`merge_note(base, local, remote, resolution=None)` takes snapshots with text
`title` and `body` fields. A provider without a title supplies `""`. Bodies may
be plain text or Markdown. Titles are atomic fields; bodies merge by lines,
preserving whitespace, Unicode and trailing newlines. Entry labels align
independently of checkbox states, including when nearby prose changes.
Repeated labels retain their occurrence order. A partial insertion, removal,
or rename of indistinguishable repeated entries requires review.
Conflicting line groups are refined into corresponding entries and insertion
gaps, then whole words within one entry. Words never align across separate
entries; checking a deleted item remains a conflict. Line terminators merge
independently, so appending a line can combine with editing the preceding line.
Word refinement is bounded to 4,096 tokens per input line. Independent edits
merge; identical changes appear once. Overlapping edits return structured conflicts
and **no writable note**. The library never inserts textual conflict markers.

Each conflict contains an ID and parts with `id`, `field`, `base`, `local`, and
`remote`. Resolution is `{id, choices: {part_id: choice}}`. A choice is `local`,
`remote`, `both`, or `{text: "a manually combined passage"}`. Every conflict
needs a choice, and the ID binds choices to all three snapshots. An outdated
resolution cannot overwrite changes that arrived during review.

## Provider integration

Keep `lib/` on the Python import path. An adapter supplies an optional pure
normalizer, a stable account ID, and its own read/write functions:

```python
from notemerge import MergeStore

with MergeStore(state_directory, provider_id, account_id, page_id) as journal:
    loaded = journal.recover()
    if loaded is None:
        loaded = journal.open(fetch_note())
    # Return loaded["view"] with the note; retain it for that editor.

# Before an actual save, using that same editing view:
with MergeStore(state_directory, provider_id, account_id, page_id) as journal:
    journal.stage(view, local_note)
    remote = fetch_note()
    result = journal.prepare(remote, resolution)
    if result["conflict"]:
        return_conflict(result["conflict"])
    else:
        write_note(result["note"])
        saved = journal.commit(result["note"])
        return_saved_note(saved)
```

The adapter must validate representability and use conditional writes when
its backend supports them. On a version mismatch, fetch and merge again;
never force the write. All network I/O belongs to the adapter. The library's
local lock serializes processes on this device, not other devices.

Preserve unchanged backend element identities when writing the merged result.
The public `align(before, after, key)` function accepts arbitrary provider
records and returns immutable spans with `kind`, `before_start`, `before_end`,
`after_start`, and `after_end`. A hashable key describes an entry's identity;
None denotes a separator. An `equal` span means aligned identities, so the
adapter must still compare their complete contents. `text_key(text)` supplies
the same Markdown identity rule used by the text merger. `AmbiguousAlignment`
means the adapter lacks evidence to choose the surviving repeated entry.

OneNote's `onenote_patch.py` translates these spans into Graph operations.
When the complete existing sequence is an unchanged prefix, it preserves those
elements and appends the additions directly, even if they repeat an existing
label. Other edits still require unambiguous alignment. It updates paragraphs
and individual list items, preserves bare blank lines,
and edits existing paragraphs inside table cells. One plan is simulated and
checked for both content equality and preservation of unchanged IDs and
attributes. There is no whole-page or whole-list replacement fallback.
Unsupported restructures, missing targets, and failed validation keep the
draft and report an error. Table row/column changes and edits without a
separate Graph target must be made in OneNote. Uncertain inserts and uploads
are never automatically repeated, including after HTTP 503. The Microsoft
transport distinguishes replaying a safe read (`RetryPolicy.REPLAY`),
restarting a replacement job with a fresh read and merge (`RESTART`), and
returning an uncertain mutation to its caller (`NEVER`). Account cooldowns
are recorded under every policy; they do not authorize replaying a write.
An explicit 429 rejection can be retried because that request was refused.

Checkbox state changes preserve the existing HTML carrier, whether it is a
paragraph or a tagged span inside a list item. Unrelated styles and attributes
are retained, and numbered checklists keep their ordered-list structure.

Keep the active editing view separate from the provider's body cache. A poll
must not replace it. After a successful merge, the returned view describes the
merged note for a future load. Keep sending the old view until that merged
note is actually displayed. Its baseline advances to the last local input,
so typing during a save does not accidentally remove remote additions or
produce conflicts with our own previous save. `NoteSession.editingView` is
assigned only after a current load has been displayed. Every save captures
that token with its document, including through delayed conversion, selection
changes, failed saves, and recovery. Provider caches never own the active
editing baseline; stale load replies cannot update it.

`open()` restores a pending draft before the remote note. Providers return
`recovered: true` and any `conflict` to `NoteSession`; the host marks that
document unsaved and presents the common conflict view. A save returns
`{error, conflict}` to request review. The optional fifth `save` argument
contains `{view, resolution}`. Providers that do not opt in keep their existing
behavior. A returned save view is only for a future accepted load.

`recover()` reads pending local intent without fetching the remote service.
`commit(saved, accepted_fields=("body",))` acknowledges a partial write while
retaining the title draft and advancing only the accepted local body. The
adapter supplies the actual saved snapshot; journal internals are private.

A pending draft belongs to one editing view. `stage()` may supersede that
view's earlier intent, but raises `DraftOwnedByAnotherView` before changing
storage if another view owns a pending draft. This includes unresolved
conflicts, interrupted writes, and partial commits. Recover and resolve that
draft first; after its full commit, another view may stage its own changes
against its own baseline. Callers must retain any rejected local input in
their editor until it can be staged. The local lock protects this ownership
check across processes.

Recovered conflicts are re-evaluated with the current engine. If an older
conflict is now mergeable, `retry: true` asks the host to retry its staged
save, including a fresh remote read. The conflict view also offers an explicit
retry; neither path supplies forced conflict choices.

## Storage and limits

Journals are separated by hashes of provider, account and document IDs. Use
the backend's stable user ID, not a display name or a rotating access token.
Directories are private (0700) and atomic JSON writes use 0600 files. A
missing baseline or corrupt journal fails closed. Unresolved drafts are never
aged out. Twelve views and three recent save snapshots are retained per note;
the active saving view and pending draft are protected during pruning.

Snapshots are limited to 2 MiB per field and 20,000 lines. Providers remain
responsible for their own format and attachment limits. Snapshots preserve
attachment references; providers must retain referenced attachment bytes if
they need durable attachment recovery beyond their normal image cache.

`stale_seconds` defaults to zero. Eventually consistent providers can opt in
to rejecting recently observed pre-save versions for a bounded interval.
OneNote uses 120 seconds and retries those reads through its request queue.
This catches known stale responses; it cannot identify every stale response
or distinguish every intentional revert immediately.

OneNote currently has no verified conditional page-content write in this
integration. Fetch–merge–write reduces lost updates but is not atomic with a
phone's save. Recovery snapshots contain the local and observed remote inputs;
they cannot recover a remote edit that the API never returned to this client.

Run `python3 lib/notemerge/selftest.py` and
`python3 providers/onenote/merge_selftest.py` for synthetic merge, recovery,
concurrency and provider integration checks.
