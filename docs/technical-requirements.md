# Technical requirements

## Runtime and constraints

| Constraint | Detail |
|---|---|
| Host | `omarchy-shell` — one long-running [Quickshell](https://quickshell.org) (Qt 6 / QML) process; the plugin is loaded into it |
| Language | QML + JavaScript (ES5-era engine, see [engine-notes](engine-notes.md)), plus Python 3 for backends |
| Dependencies | **standard library only**; no `pip`, no system packages. Markdown parsing uses a *vendored* mistune (BSD-3, `services/markdown/mistune/`) |
| External binaries | `python3`, `sh`, `head`, `stat`, `awk`, `sort`, `rm`, `mkdir`, `inotifywait`, `wl-copy`, `wl-paste`, `xdg-open`; ImageMagick optional |
| Privileges | none — no sudo, no pkexec, no services, no config files of other apps |
| Sandbox | none: an Omarchy plugin runs unsandboxed inside the shell. Behave accordingly |
| Reloading | QML changes need `omarchy-restart-shell`; Python changes take effect on the next call |
| Editor format | the document is **rich text** (HTML); notes and the provider contract are **Markdown**, converted at both ends by `services/markdown/qthtml/` ([decisions](decisions.md)) |

## Layout

```
manifest.json               plugin id, kinds: ["overlay"], entry point, keepLoaded
Notes.qml                   the host
ui/NoteList.qml             sidebar (rows, drag, scrolling, the coloured page)
ui/NotebookTabs.qml         the binder rail down the left edge
ui/TabColors.js             the tab palette, and the wash both it and the page use
ui/NoteEditor.qml           title, toolbar, editor, notices and provider views
providers/PROVIDERS.md      the provider contract — the file to read first
providers/local/            Markdown folders in ~/Notes
providers/sticky/           Microsoft Sticky Notes  (sticky.py)
providers/onenote/          OneNote                 (onenote.py, onenote_md.py)
providers/notion/           Notion                  (notion.py, notion_md.py)
services/clipboard/         the clipboard's image    (Clipboard.qml, clipboard.py)
services/microsoft/         shared Graph sign-in    (Account.qml, msgraph.py)
services/markdown/          vendored mistune + parse.py (one Markdown parser)
                            qthtml/ — Markdown <-> the editor's rich text, and its selftest
                            Markdown.qml — the QML side of that conversion
examples/hello/             minimal external provider, incl. its own setup screen
docs/                       these documents
```

External providers are loaded from
`~/.config/omarchy/note-note/providers/<id>/Provider.qml` at startup.

## Responsibilities

**The host (`Notes.qml`) owns** the overlay/detached window, the header
(search, key hints, Detach), the sidebar model, selection, the editor, the
autosave state machine, keyboard shortcuts, the state file, and rendering the
device-code sign-in screen for accounts a provider created.

**The host must not** know any backend, path format, credential or API. Every
branch of the form `if (provider.id === "…")` is a design failure; the two
that exist (`local` for the default "new note" target and the autosave
debounce) are the exceptions to remove first if a third appears.

**A provider owns** its sections and rows, `load`/`save`/`create`/`remove`,
its capability flags, its own setup UI and credential storage, its caches, its
limits, and its change detection. Providers never touch the UI directly —
they emit `updated()`, `statusRequested()`, `noticeRequested()`,
`viewRequested()`, `persistRequested()`, `noteChanged()`.

The full contract, including every property, function and signal, lives in
[`../providers/PROVIDERS.md`](../providers/PROVIDERS.md). It is the API other
people write against: change it additively, never silently.

## Data model

- A note is addressed by `"<providerId>:<opaque>"`. Only the provider parses
  the part after the colon.
- A row is `{ kind, path, title, preview, icon, level, expanded, fixed,
  version }` with `kind` ∈ `note | new | action | tree | placeholder`. The host
  no longer emits `placeholder`; a provider may still want a spacer.
- `version` is an opaque change marker (file mtime, `lastModifiedDateTime`,
  `last_edited_time`). The host reloads the open note when a listing reports a
  newer version and the note has no unsaved edits.
- Host state (`~/.local/state/omarchy/note-note.json`, version 3): detached
  flag, the open tab's section key, and a `providers` object each provider owns.
  Version 2's two fold lists are ignored on read and dropped on the next write.

## Storage

| What | Where |
|---|---|
| Local notes | `~/Notes/<Notebook>/<note-*.md>`; order in `.order`, notebook order in `.notebooks` (override root with `NOTE_NOTE_DIR`) |
| Host state | `~/.local/state/omarchy/note-note.json` |
| Microsoft tokens | `~/.local/state/omarchy/note-note-ms-<provider>.json`, 0600, one per provider |
| Notion secret | `~/.local/state/omarchy/note-note-notion.json`, 0600 |
| Caches | `~/.cache/omarchy/note-note-{sticky,onenote,notion}.json`, images in `note-note-onenote-img/` (0700, files 0600) |

Nothing is written outside these paths, and nothing at all is written to a
shared temp directory (see [security.md](security.md)).

## Performance rules

- **Nothing runs while the window is hidden**: no timers, no watchers, no
  requests. `watch(false)` is called on close.
- Local changes are detected by **one** `inotifywait` process, started on
  open and killed on close (~4 MB RSS, idle at 0 % CPU), debounced 400 ms, and
  ignoring our own writes.
- Online providers get a `poll(currentPath)` every **20 s** while visible and
  must do the cheapest possible check: Sticky Notes one listing request;
  OneNote re-lists only expanded sections and re-reads the open page, every
  third tick; Notion one search, every third tick.
- Expensive listings are cached with an age (OneNote 10 min, Notion 5 min) and
  only bypassed by an explicit *Refresh* row.
- The sidebar model is a plain JS array replaced wholesale, with the scroll
  offset preserved across rebuilds. Never clear-and-refill a `ListModel`.

## Limits (must exist, must be enforced at read time)

| Input | Ceiling |
|---|---|
| Local note | 2 MiB (`maxNoteBytes`) — larger opens read-only |
| Local listing | 4 MiB (`maxListBytes`) |
| Host state file | 1 MiB (`maxStateBytes`) |
| Graph response | 8 MiB default, 4 MiB per listing/page |
| Notion response | 4 MiB; 3 requests/s pacing |
| Sticky Notes | 500 notes, 256 KiB per note body |
| OneNote | 500 sections, 3000 pages; images: 20 MiB each, 40 per page, 45 s wall-clock budget, cache pruned to 400 files / 200 MiB |
| Notion | 1000 pages, 300 blocks per page |

## Compatibility

- Target: Omarchy 4 (Quattro) / Quickshell as shipped; Qt 6.11 at time of
  writing.
- The plugin id `io.github.andreivinca.note-note` is permanent — the
  marketplace treats ids as immutable.
- Manifest `version` is bumped on every release and is what the marketplace
  displays.
