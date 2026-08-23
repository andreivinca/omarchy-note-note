# Decisions

Why things are the way they are — including options that were tried and
rejected, so they are not tried again by accident.

---

### Providers as folders inside this repo, not separate Omarchy plugins

*Considered:* shipping Sticky Notes and OneNote as their own marketplace
plugins. *Rejected:* Omarchy has no plugin-to-plugin API — plugins cannot
import each other's QML, there is no service registry, and a provider-only
plugin would have to fake one of the official `kinds` to pass validation. It
would ride on an undocumented convention and list "plugins" that do nothing
alone.

*Chosen:* one plugin, providers as self-contained folders, plus a loader for
**external** providers from `~/.config/omarchy/note-note/providers/<id>/`,
which is Note Note's own directory and depends on nothing Omarchy might
change. If inter-plugin support ever lands, only discovery changes — the
contract already exists.

### Each provider signs in separately, sharing only code

Sticky Notes and OneNote use the same Microsoft app registration and the same
`msgraph.py`, but each has **its own token file and its own scopes**
(`note-note-ms-<provider>.json`). Signing out of one leaves the other signed
in. The cost is signing in twice; the benefit is that "everything separate"
actually means separate. A token from before this split is adopted once into
each provider's file so nobody had to re-authenticate.

### One app registration, owned by the author

Microsoft Graph has no anonymous access — someone must own an app
registration. Making every user create one (the first implementation) was
rejected as unusable; the registration is now the plugin's, exactly as rclone
and Thunderbird do it. The client id is public by design for a public client
and lives in `services/microsoft/msgraph.py`; users only sign in. A user who
prefers their own registration can override it in
`~/.config/omarchy/note-note.json`.

Notion is the opposite by necessity: its API has no public-client flow, so
each user creates an internal integration and pastes the secret into the
provider's own setup screen.

### Setup belongs to the provider, not the host

*Considered:* a declarative `setupFields` schema the host renders.
*Rejected:* every backend's setup is different (device code, pasted secret,
server URL + app password), and a schema would grow into a form framework.

*Chosen:* the provider hands the host a QML `Component`
(`viewRequested(title, component, props)`), which is rendered in the note
pane. The provider validates, stores its own values and secrets, then emits
`viewCleared()`. The host never sees a credential.

### Markdown parsing uses a vendored mistune

Hand-written line parsers produced the escape, soft-wrap and nesting bugs.
mistune 3.3.4 (BSD-3, ~58 files) is vendored under `services/markdown/`, so
the promise of "standard library only, nothing installed" holds. Only the
*parser* was replaced: the renderers (AST → OneNote HTML / Notion blocks) and
the backend → Markdown writers stay ours, because they encode backend quirks
no library knows about.

### Highlight is `==text==`, not a coloured background

Qt's Markdown writer drops character background colours, so a highlight shown
as colour would vanish on the next save. Markers survive editing and the
providers translate them into the backend's real highlight. Showing colour
*and* keeping it would require walking the document's character formats from
QML (only `cursorSelection` is exposed) — expensive and fragile. Revisit only
if the coloured look matters more than losing highlights.

### Block styles are applied through the Markdown, not the document

QML exposes no block formatting on `TextEdit`. Toolbar block actions insert a
private marker at the end of the affected paragraphs, take `editor.text`
(Markdown), rewrite the marked lines' prefixes, and apply the result. Since
2.5.0 this is done as an in-place edit rather than a reload, so `Ctrl+Z` still
walks back through toolbar actions.

### No image insertion

Displaying images is supported (OneNote pages fetch them through Graph);
inserting one is not. It needs an upload endpoint per backend, a file picker,
and a local-file story for Markdown notes — a feature in its own right, and
one that only the native apps do well today.

### Indent on plain text is non-breaking spaces

Markdown has no paragraph indent. Lists nest properly; plain paragraphs get
four U+00A0 per level, which Qt keeps and the OneNote provider maps to a real
`margin-left: 36px` per level. Notion and local notes keep the spaces
verbatim.

### 20-second poll, inotify for local files

*Considered:* backend webhooks. *Rejected:* Graph and Notion both require a
public HTTPS endpoint. *Chosen:* an `inotifywait` process for local files
(event-driven, free) and a 20 s tick that asks each online provider for its
cheapest check, with the expensive listings behind a cache age. Nothing runs
while the window is hidden.

### Sticky Notes: plain text, no title, no reordering

The backend stores the subject as a copy of the first body line and offers no
ordering — exposing a title field or drag handles would be inventing
behaviour the backend cannot keep.

### Read-only rather than lossy writes

A OneNote page with images or more than the block/section caps, a Notion page
with unsupported blocks, a local file over 2 MiB: all open **read-only with a
visible reason**. Saving would silently destroy content we cannot represent,
which breaks the first rule of the project.
