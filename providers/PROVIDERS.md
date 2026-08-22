# Note Note providers

A provider is a QML `Item` (file `Provider.qml`) that supplies one or more
sidebar sections and the notes in them. Built-in providers live under
`providers/<id>/`; external ones under
`~/.config/omarchy/note-note/providers/<id>/Provider.qml` (a plain git clone
is enough). The host instantiates each with `host` and `services` set.

## Properties the host reads

| property            | type   | meaning |
|---------------------|--------|---------|
| `id`                | string | unique, lowercase; every note path starts with `id + ":"` |
| `name`              | string | label used in status messages |
| `markdown`          | bool   | bodies are Markdown (rendered); false = plain text |
| `hasTitle`          | bool   | notes have a separate editable title |
| `canCreate`         | bool   | `create()` is supported |
| `canDelete`         | bool   | `remove()` is supported |
| `canReorder`        | bool   | rows may be dragged within a section; `setOrder()` persists |
| `canCreateSection`  | bool   | `createSection()` is supported (the "New notebook…" row) |
| `microsoftScopes`   | list   | Graph scopes the provider asks for when it creates its own Microsoft account |
| `sections`          | list   | `[{ key, name, collapsedByDefault, rows, count? }]` — `count` overrides the heading's note count |

A row is `{ kind, path, title, preview, icon, level, expanded, fixed, version }` with
`kind` one of `note`, `new` (path = create target), `action` (path = action
id), `tree` (path = tree id, `expanded`), `placeholder`.

`version` (optional) is an opaque change marker for a note — a file mtime,
a `lastModifiedDateTime`, an etag. The host compares it with the `version`
returned by `load()`: when a listing shows a newer version for the note that
is open (and it has no unsaved edits), the host reloads it.

## Functions

- `refresh()` — (re)load; emit `changed` when `sections` are ready.
- `load(path, cb)` → `cb({ title, body, editable, error })`
- `save(path, title, body, cb)` → `cb({ error, warning })`
- `create(target, cb)` → `cb({ path, error })`
- `remove(path, cb)` → `cb({ error })`
- `createSection(name, cb)` → `cb({ key, error })`
- `action(id)`, `toggleTree(id)`
- `setOrder(sectionKey, paths)`
- `crumb(path)` → string for the editor's description line
- `createTargetFor(path)` → target for Ctrl+N while `path` is open, or ""
- `restoreState(obj)`, `saveState()` → obj (kept in the host's state file)
- `watch(on)` (optional) — the app became visible / hidden; start or stop
  whatever event source is cheap (the local provider runs one `inotifywait`).
- `poll(currentPath)` (optional) — called every 20 s while the app is
  visible with the path of the open note; do the cheapest check for external
  changes (one small request), or nothing. A provider whose backend has no
  trustworthy change marker (OneNote) may re-read the open note and emit
  `noteChanged(path)`; the host reloads it if it has no unsaved edits.

## Signals

- `updated()` — sections/rows changed; the host rebuilds the list.
- `statusRequested(string text)` — a transient message in the header.
- `noticeRequested(string title, string text, string code, var actions)` /
  `noticeCleared()` — full-pane message (actions: `[{ label, icon, action }]`).
- `viewRequested(string title, var component, var props)` / `viewCleared()` —
  show a provider-supplied QML `Component` in the note pane, with `props`
  assigned to it once loaded. This is how a provider does its own **setup**
  and **settings**: it builds the form (the shell's `qs.Ui` controls are
  available: `TextField`, `Button`, `Toggle`, …), validates, stores its
  values and secrets itself (e.g. an owner-only file under
  `~/.local/state/omarchy/`), then emits `viewCleared()` and `updated()`.
  A provider that is not configured should show a `Set up…` action row in its
  section and open the view from `action(id)`; a `Settings…` row can reopen it.
- `persistRequested()` — ask the host to persist `saveState()`.

## Setup and settings

Setup is the provider's business end to end — the host never sees
credentials or settings. Typical shape:

```qml
readonly property bool configured: settings.url !== ""
function rebuild() {
  var rows = configured ? noteRows() : [{ kind: "action", path: "setup", title: "Set up…", icon: "󰒓" }]
  ...
}
function action(id) { if (id === "setup" || id === "settings") viewRequested("Nextcloud Notes", setupView, { current: settings }) }
Component { id: setupView; Column { property var current; TextField { … } Button { onClicked: { save(); root.viewCleared(); root.refresh() } } } }
```

## Example

`examples/hello/Provider.qml` is a complete minimal provider: one section,
notes kept in its own state, and a setup screen of its own. Symlink or copy
it to `~/.config/omarchy/note-note/providers/hello/` to see it load. Put
`focus: true` on the field that should receive the keyboard when a view
opens; the host focuses the view once it is in the scene.

## Limits

Everything a provider reads is the provider's responsibility to bound — file
sizes, HTTP response bodies, list lengths, cached downloads — before it
reaches the host. The host never reads provider data from disk or network
itself; it only retains what `sections` and `load()` hand it, so an unbounded
provider means unbounded shell memory. Each built-in declares its limits at
the top of its files (`maxNoteBytes` in `providers/local/Provider.qml`,
`MAX_*` in `sticky.py` / `onenote.py`); a note that is too large should be
listed but returned as `editable: false` with an explanatory body rather
than loaded. The host guards only its own state file.

## Services

`services.microsoft.create(providerId, scopes)` returns an account of the
provider's own (see `services/microsoft/Account.qml`): its own token file
(`~/.local/state/omarchy/note-note-ms-<providerId>.json`) and only the
scopes it asked for, so signing out of one provider never touches another.
It exposes `configured`, `signedIn`, `account`, `hasScope(s)`, `login()`,
`relogin()`, `logout()`, `refresh()`, `env` (environment for processes that
run `msgraph.py`-based scripts), `scriptDir`, and the signal `updated()`.
The host renders the device-code screen for any account it created. What
providers share is only the code and the app registration.
