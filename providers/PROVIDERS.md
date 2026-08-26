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
| `name`              | string | the provider's display name: the header titles it (with `logo`) while one of its tabs is open, and status messages start with it |
| `markdown`          | bool   | bodies are Markdown (rendered); false = plain text |
| `hasTitle`          | bool   | notes have a separate editable title |
| `canCreate`         | bool   | `create()` is supported |
| `canDelete`         | bool   | `remove()` is supported |
| `canReorder`        | bool   | rows may be dragged within a section; `setOrder()` persists |
| `canCreateSection`  | bool   | `createSection()` is supported. The "New notebook…" row is shown only while a tab of yours is open, and makes the notebook in *your* provider |
| `canImages`         | bool   | a pasted picture can be stored: the editor writes it into the note as `![](file:///…)` and `save()` must upload it. False (the default) makes ctrl+v say so rather than swallow the paste |
| `tools`             | list   | optional: formatting-toolbar tool ids the backend can store — `bold italic underline strikeout highlight code h1 h2 h3 p ul ol todo indent outdent quote codeblock table rule link`; omitted = all (when `markdown`), `[]` = no toolbar |
| `microsoftScopes`   | list   | Graph scopes the provider asks for when it creates its own Microsoft account |
| `logo`              | url    | optional: a mark shown at the head of every one of this provider's tabs, and beside the header title while one of them is open |
| `sections`          | list   | `[{ key, name, rows, color?, count?, notes? }]` — one binder tab each; `count` overrides the tab's note count. `notes` (`[{ path, title, preview }]`) is every note the section holds, for search: give it when `rows` can hide notes (a folded tree); left out, the note rows are taken to be all of them |

`name` is the tab's label, turned a quarter turn and elided if it is long, so
keep it short. `color` is your brand's, given raw as `#rrggbb`: the rail softens
it into a pastel and lays it on as a shade — on the tab, and on the panel beside
it from the same number — so you state your identity and never think about the
theme, and a loud brand cannot arrive loud. Leave `color` out and the tab takes
a pastel of its own from `name` — which is what a provider with many notebooks
wants, since each one then looks different.

`logo` is an image the provider ships beside its own `Provider.qml` —
`Qt.resolvedUrl("logo.svg")`. SVG and raster both load; it is drawn at icon size
and shown exactly as given, so a provider that has a mark has already decided
what it looks like (which means it should read on a dark theme and a light one).
Leave it out and the tab simply has no mark, which is what the local notebooks
do — a folder is not a brand.

`collapsedByDefault` is ignored since 2.8: the sidebar shows one section at a
time and which one is open is the user's, kept between runs. Passing it is
harmless.

A row is `{ kind, path, title, preview, icon, level, expanded, fixed, version }` with
`kind` one of `note`, `new` (path = create target), `action` (path = action
id), `tree` (path = tree id, `expanded`).

Action and tree ids are plain strings and several providers use the same ones
(`login`, `logout`, `refresh`): the host resolves a click against the open
tab first, so a shared name never reaches another provider's row.

`version` (optional) is an opaque change marker for a note — a file mtime,
a `lastModifiedDateTime`, an etag. The host compares it with the `version`
returned by `load()`: when a listing shows a newer version for the note that
is open (and it has no unsaved edits), the host reloads it.

## Functions

- `refresh()` — (re)load; emit `changed` when `sections` are ready.
- `load(path, cb)` → `cb({ title, body, editable, error })`
- `save(path, title, body, cb)` → `cb({ error, warning })`
  A `body` from a provider with `canImages` may contain `![alt](file:///…)`
  pointing either at a file the provider itself cached on `load()` (the same
  picture, already on the backend) or at a freshly pasted file staged in
  `~/.cache/omarchy/note-note-paste/` (a picture to upload). Telling the two
  apart is the provider's job — see `providers/onenote/onenote.py`, which
  keeps an index of what it cached and hands unchanged pictures back to the
  backend by reference rather than uploading them again.
- `create(target, cb)` → `cb({ path, error })`
- `remove(path, cb)` → `cb({ error })`
- `createSection(name, cb)` → `cb({ key, target, error })`. `key` is the new
  section's key; the host opens it as the active tab. `target` is optional — the
  create target for a first note in it (the same string your `new` row carries),
  and the host makes that note when you give one. Have the section listed before
  you call back, or the tab it opens will be empty.
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
than loaded. Read a file once with a hard ceiling and use those bytes — a
size check followed by a separate open is not a bound, because the file can
change in between. For local files use `lib/readfile.py` (one descriptor,
no symlink following, regular files only, capped, with a deadline), as the
local provider and the host's own state file do.

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
