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
| `canImages`         | bool   | a pasted picture can be stored: the editor writes it into the note as `![](file:///…)` and `save()` must carry it to the backend. False (the default) makes ctrl+v say so rather than swallow the paste. An image may carry a display width the author set with the editor's corner handle, written as `![alt](src){width=N}` — a provider stores it with the image if the backend can, and must at least round-trip the marker |
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
- `load(path, cb)` → `cb({ title, body, editable, error, base })`
  `base` (optional) is the note's own directory, for a provider whose notes
  name their images by a relative path (the local provider's `.assets/`):
  the editor resolves the links against it and the converter measures the
  files through it. Leave it out when every image is an absolute file:// URL.
- `save(path, title, body, cb)` → `cb({ error, warning })`
  Call `cb` exactly once, always — including when the save was superseded by a
  newer one (answer `{}`: the newer save contains this one's intent) and when
  it was cancelled. The host counts saves in flight per note, and a save that
  is never answered is one that looks unfinished for ever.
  A `body` from a provider with `canImages` may contain `![alt](file:///…)`
  pointing either at a file the provider itself cached on `load()` (the same
  picture, already on the backend) or at a freshly pasted file staged in
  `~/.cache/omarchy/note-note-paste/` (a picture to upload). Telling the two
  apart is the provider's job — see `providers/onenote/onenote.py`, which
  keeps an index of what it cached and hands unchanged pictures back to the
  backend by reference rather than uploading them again, and
  `providers/local/images.py`, which copies staged pastes into `.assets/`
  beside the note and makes the links relative.
- `create(target, cb)` → `cb({ path, error })`
- `remove(path, cb)` → `cb({ error })`
- `createSection(name, cb)` → `cb({ key, target, error })`. `key` is the new
  section's key; the host opens it as the active tab. `target` is optional — the
  create target for a first note in it (the same string your `new` row carries),
  and the host makes that note when you give one. Have the section listed before
  you call back, or the tab it opens will be empty.
- `action(id)`, `toggleTree(id)`
- `revealPath(path)` (optional) — unfold whatever tree state hides this
  note's row, and rebuild, so the row exists on screen. The host calls it
  when a search ends on a note, then scrolls to the row; a provider whose
  rows never fold simply leaves it out.
- `search(query, cb)` (optional) — content search: call back with
  `{ paths: [...] }`, the paths of notes whose *body* contains `query`,
  case-insensitively. The host matches titles and previews itself on every
  keystroke; once the typing pauses it asks this for what only the backend
  can see, and folds the answer into the same result set (rows, tab hit
  counts). Whether bodies are searched at all is the host's decision, made
  by asking or not asking — a provider is never called just to say no.
  Call `cb` exactly once per call, an empty list included: the host shows
  a "searching…" state until every asked provider has answered. Best-effort
  by design: answer with what the backend can — an empty list when it
  cannot — and the host says nothing either way, since title matching has
  already answered something. Paths not in the current `sections` are
  ignored, and a reply to text no longer in the field is discarded, so a
  slow answer is always safe. Leave it out and the provider's notes are
  searched by title and preview alone (Notion does: its public API searches
  titles only, and fetching every page's blocks per keystroke is not a
  search).
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

### `services.requests` — the request queue

Everything a provider asks of a network backend goes through a **lane**: a
queue that orders the requests, coalesces the ones that make each other
pointless, runs a few at a time, and parks the whole lane when the backend
says it has had enough. One lane per *rate key*; the host owns them, so a lane
outlives the provider that asked for it (a provider is destroyed and rebuilt
when its settings change, and a backend's cooldown must survive that).

```qml
property var rq: null
Component.onCompleted: { if (services && services.requests) root.rq = services.requests.queueFor("my-api", root) }
Component.onDestruction: { if (services && services.requests) services.requests.cancelOwner(root) }
```

- `services.requests.queueFor(key, provider)` → the lane for `key`, made on
  first ask. `provider` is optional and only used to name it in a status
  message ("OneNote is rate-limited — retrying in 40s").
- `services.requests.cancelOwner(owner)` → drop everything queued for that
  owner across every lane. Call it on destruction and on sign-out.

A lane exposes `depth`, `cooling`, `cooldownRemaining`, `paused` (the host
sets it while the window is hidden) and the signal `updated()`, plus:

```qml
var handle = rq.enqueue(opts, start, settled)   // handle.cancel()
rq.cancelOwner(owner)
```

| `opts` | meaning |
|---|---|
| `key` | what may not overlap itself. Jobs sharing a key run strictly in order, oldest first, whatever their priority — a page's save and its delete share one, so a delete can never overtake the save it supersedes |
| `mode` | what a newcomer does to a **queued** job of the same key. `append` (default) nothing; `replace` supersedes it, because the newer job contains its intent (a newer save of one page); `dedupe` joins it, so three asks for one listing are one request |
| `priority` | `0` interactive, `1` background. 0 dispatches first, and a background job never takes the lane's last slot, so a keystroke never waits behind a poll |
| `owner` | your provider, for `cancelOwner` and for the round-robin that stops one provider starving another |
| `flush` | this is a **write**. Writes keep draining while the window is hidden; reads do not |
| `label` | a word for warnings |

`start(ctx)` begins the work and calls `ctx.done(result)` **exactly once** — a
second call is ignored, so a script that answers twice cannot double-deliver.
`ctx` also carries `key`, `label` and `attempts`.

`settled(result, info)` is the answer, with
`info = { superseded, cancelled, attempts }`. **Every enqueue is answered
exactly once** — delivered, superseded, or cancelled. `result` is `null` when
the job never ran (superseded or cancelled); handle that case, because a
provider that never hears back is a note that silently did not save.

**The result decides what happens next.** `ctx.done()` is given whatever the
script printed, and the lane reads one field of it:

| `kind` | what the lane does |
|---|---|
| `"throttled"` | park **the whole lane** until `retryAfter` seconds have passed (10s → 20s → 40s → 60s when the field is absent), then re-run this job at the head of the queue. Retried for as long as the app is open |
| `"transient"` | re-run **this job only**, after 2.5s, 5s, 10s; the third answer is delivered whatever it says |
| anything else | delivered as it stands — including a plain `{ "error": … }`, which is what every script answered before this existed |

### Rate keys

Each provider paces against its own key, and shares none: a OneNote throttle
parks OneNote while Sticky Notes keeps listing. Pick your own key; these are
the built-ins'.

| key | used by | windows |
|---|---|---|
| `graph-onenote` | `onenote.py`, images included | (60s, 100) and (3600s, 350) — Microsoft allows 120/min and 400/hr per app+user |
| `graph-mail` | `sticky.py` | (60s, 240) — politeness; mailbox limits are far higher |
| `notion` | `notion.py` | (1s, 3) — Notion's published average |
| *(none)* | `login.microsoftonline.com` | unpaced: signing in must never wait behind a Graph cooldown |

### `lib/ratelimit.py` — the other half

The lane orders *jobs*; one job is one script run, which can be forty HTTP
requests the lane cannot see. `lib/ratelimit.py` paces those, across every
process at once (`flock`'d sliding-window counters under
`~/.cache/omarchy/note-note-rate/`), and an external provider may import it:

```python
import ratelimit
with ratelimit.slot("my-api", [(60, 100)]):
    ...one request...
```

It admits by rolling **count**, not by a fixed gap, so a burst under budget
runs at full speed; it caps concurrent requests per key at 4 across all
processes; and it sleeps only **short** waits (up to `PACE_TIMEOUT`, 20s).
Anything longer is not slept out in a script the user cannot cancel — it
raises `Throttled`, which your `main()` reports as the JSON above and the lane
waits out instead. Two layers, one wait, never both.

```python
except ratelimit.Throttled as t:
    fail("rate limited", kind="throttled", retry_after=t.retry_after)
```

### `services.microsoft`

`services.microsoft.create(providerId, scopes)` returns an account of the
provider's own (see `services/microsoft/Account.qml`): its own token file
(`~/.local/state/omarchy/note-note-ms-<providerId>.json`) and only the
scopes it asked for, so signing out of one provider never touches another.
It exposes `configured`, `signedIn`, `account`, `hasScope(s)`, `login()`,
`relogin()`, `logout()`, `refresh()`, `env` (environment for processes that
run `msgraph.py`-based scripts), `scriptDir`, and the signal `updated()`.
The host renders the device-code screen for any account it created. What
providers share is only the code and the app registration.
