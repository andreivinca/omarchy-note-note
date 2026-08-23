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

### The editor's document is rich text, not Markdown

*Was:* a `TextEdit` in `MarkdownText`, with the note's Markdown as the
document format — the editor parsed it on the way in and re-serialised it on
the way out. *Rejected*, after years of working around it: Qt's Markdown
writer folds paragraphs at 80 columns, escapes anything that looks like
Markdown, drops empty paragraphs and empty checkboxes, and corrupts a table
that follows a quote. Every one of those is the same fault — Markdown was the
wire format between the document and us, and Markdown cannot express what the
editor must keep: a highlight, an empty line, an indent, a checkbox with no
text. No amount of patching reaches that.

*Chosen:* the document holds HTML (`textFormat: RichText`) and
`services/markdown/qthtml/` converts at both ends — Markdown in when a note
opens, Markdown out when it saves. Notes on disk and the provider contract are
unchanged. Qt's HTML keeps a background colour, an empty paragraph, a
checkbox's state and an indent, so the workarounds are gone with their cause;
what it does not keep is *semantics* (a heading comes back as a font size, a
quote as margins), which is exactly what a converter we own can put back.

The property that matters is that the loop closes: markdown → html →
document → html → markdown must reach a fixpoint. That is a test, not a hope:
`python3 services/markdown/qthtml/selftest.py`, which runs every case through
a real Qt document offscreen.

### Markdown parsing uses a vendored mistune

Hand-written line parsers produced the escape, soft-wrap and nesting bugs.
mistune 3.3.4 (BSD-3, ~58 files) is vendored under `services/markdown/`, so
the promise of "standard library only, nothing installed" holds. Only the
*parser* was replaced: the renderers (AST → OneNote HTML / Notion blocks) and
the backend → Markdown writers stay ours, because they encode backend quirks
no library knows about.

### Highlight is a colour in the document and `==text==` on disk

Markdown has no highlight, so the note keeps the markers the providers already
translate into each backend's own. The *document* keeps a real
`background-color`, which rich text does hold through a save — that is half of
why the editor moved to it. QML cannot set a character background, so the
toolbar wraps the selection's own HTML in a span (`highlightSelection`), which
keeps whatever formatting was already inside it. The highlight carries its own
dark ink: the editor's foreground follows the theme, and on a dark theme that
would be light text on a light marker.

### Block styles still travel through the Markdown

QML exposes no block formatting on `TextEdit`, in either format, so a heading
or a list is still applied by rewriting a line of Markdown rather than by
setting something on the document. What changed with rich text is the trip:
the document is converted to Markdown (with a map saying which line each
document block is on, so the caret finds its line), the lines the tool owns
are rewritten, and the result is converted back and put in with
`remove()` + `insert()` — ordinary edits, so `Ctrl+Z` still walks back through
toolbar actions. The private end-of-paragraph marker is gone: the map replaced
it.

### Images: pasted, and kept where they are

A OneNote page with images used to open read-only, because a save rewrote the
whole page body and could only have dropped them. Now ctrl+v pastes a picture
from the clipboard and a page with images is editable.

What makes it safe is that a save never mentions an unchanged image. Handing
an image back by its own resource URL was tried and *rejected*: OneNote copies
the resource each time (re-encoding it), and a copy of a resource it has not
materialised yet is empty forever — an image lost to an ordinary-looking save.
Instead the note is written as text runs in `div`s of our own with the images
as their siblings, and a save is a set of targeted commands: text runs
replaced where they stand, a pasted image uploaded as a part and inserted, a
deleted one replaced with an empty div. Anything the surgical path cannot
express (an image reordered, a page shaped by the OneNote apps) is rebuilt
once with every image uploaded from our own cached bytes — never referenced —
and is surgical from then on.

The costs, accepted deliberately: one extra read per save of a page with
images (a replace can only target a generated id, and OneNote renews those on
every write; a second read after an upload, so the next autosave knows the
paste is already up); the cache keeps images exactly as Graph served them (no
local rescaling — the editor caps its *display* width instead); and a page
whose images cannot all be fetched or carried refuses to save, read-only with
the reason, because a half-held page can only be saved by destroying what is
not held. Pages without images save exactly as before, in one request.

*Not done:* images in local Markdown notebooks and in Notion. The editor asks
the provider (`canImages`) and says so when the answer is no, rather than
swallowing the paste. Local notes need a story for where the file lives next to
the note; Notion needs its own upload endpoint.

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
