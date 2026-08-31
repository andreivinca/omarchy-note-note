# Decisions

Why things are the way they are — including options that were tried and
rejected, so they are not tried again by accident.

---

### One notebook at a time, on a binder rail

*Considered:* keeping the collapsible headings and only colouring them.
*Rejected:* folding is a thing you undo, and with three sources and a folder of
notebooks the list was still a single column of everything — the headings told
you where you were only if you could see one. Colouring them changed nothing
about that.

*Considered:* while searching, listing the hits from every section at once.
*Rejected:* it would be worse than what it replaced. The old headings said which
notebook a hit came from; with them gone a mixed list is unattributable. Hits
stay inside their tab, every tab carries its own hit count, and a search that
the open tab cannot answer moves you to the first tab that can.

*Chosen:* one tab open at a time, kept between runs, `Ctrl+Tab` to walk them.
Which tab opens on a fresh state is not a provider's to claim — it is the first
local notebook, because the user's own files come first, and a rule the host
owns cannot be fought over by two providers. `collapsedByDefault` is left in the
contract, ignored, so nobody's provider breaks.

### A tab's colour is the provider's to name and the rail's to render

A provider hands over its brand raw — `#7719AA` for OneNote — and the rail
pastelises it (hue kept, lightness and saturation taken from the palette) and
washes it over the background. So a provider states its identity without knowing
anything about the theme, and a brand purple cannot arrive as a block of purple.
A provider that names no colour, which is what the local one does because it has
a tab per notebook folder, gets a pastel hashed from the section's name: hashed
rather than indexed, so a notebook keeps its colour when another is added above
it. The host walks a duplicate along the palette afterwards, since it is the only
thing that sees every tab at once.

The panel is painted from the same number as the tab, not a fainter version of
it — a divider and the page it divides are one sheet, and one number is the only
way the two are provably identical.

*Considered:* making that number strong enough to turn the sidebar into a
coloured surface, the way the paper dividers this imitates are. *Rejected:* it
works, and it was built, but it drags the whole sidebar with it — a light page
needs its rows inked dark instead of lit, which means a second palette living
alongside the theme's, and the panel stops being able to follow a theme it no
longer takes its text colour from. The wash is a shade instead: low enough that
the theme's own foreground sits on it untouched, so nothing in the sidebar has
to know whether the theme is dark or light.

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

An image the editor leaves *inside* a list item, quote, heading or table cell
is lifted out to a paragraph of its own before the page is rendered
(`hoist_images`): OneNote keeps images as siblings of the paragraphs, and the
surgical save can only leave alone what is a top-level run. The list is split
around the image; the halves stay lists.

*Not done:* images in Notion, which needs its own upload endpoint. The editor
asks the provider (`canImages`) and says so when the answer is no, rather
than swallowing the paste.

### Resizing an image is a corner handle, and the width is the note's

Hovering an image shows one marker on its bottom-right corner; dragging it
resizes the image (aspect kept, an outline while dragging, one undo step),
and the width lands in the note as `![alt](src){width=320}` — pandoc's
attribute form, which other Markdown tools at worst show as a stray brace.
mistune leaves the marker as literal text after the image token and
`services/markdown/parse.py` folds it into the token's attrs, so every
renderer sees a width and no reader ever meets the marker as note text.

A width in the document already had a meaning: the editor caps the *display*
of a large image at 640px (`dialect.MAX_IMAGE_DISPLAY`) without touching the
note. Both ride the same `width` attribute — Qt has only the one — so the
two are told apart by the number: the writer caps only an image that names
no width, and the reader drops a width equal to the cap on an image the cap
would have applied to. The one ambiguity, dragging a large image to exactly
640, reads as the cap: the note stays clean and displays identically either
way. A fresh paste wider than the cap is fitted to it on the spot, joined to
the paste's own undo step — which also ended screenshots arriving at natural
size and clipping at the pane until the next load.

The handle needs the native inspector (cpp/): QML can neither read an
image's drawn geometry nor set a `QTextImageFormat` width without rewriting
HTML around the caret. `images()` reports position, drawn size, natural size
and baseline; `setImageWidth()` is a format-only write. Without the built
library images simply have no handle — the same graceful absence as the
decorations. OneNote already kept a per-image width in its cache index so an
outside width survived our saves; the width now travels through the Markdown
too, shown and editable, and the note's width wins over the index's.

### Local notebooks keep images in `.assets`, notes keep relative links

*Considered:* leaving pasted images as `file://` links into the clipboard's
staging directory. *Rejected:* the staging directory prunes itself — notes
would quietly lose their pictures. *Chosen:* on save, any image link into
the staging directory is copied to `.assets/` beside the note and the link
becomes `![](.assets/name.png)` (`providers/local/images.py`: body over
stdin, staged files read symlink-free and bounded, written with `O_EXCL` —
the same bytes reuse a name, different bytes take the next — so the
autosave that runs every few hundred milliseconds is idempotent). A `file://`
link pointing anywhere else is the author's own and is left exactly as
written, and the note is written even when a copy fails, with a warning and
the staged link still standing. The editor resolves the relative links
through `TextEdit.baseUrl`, set from the `base` that `load()` now returns,
so nothing rewrites the body on the way in — and it keeps showing the staged
file until the note is next opened, the same bargain the OneNote provider
makes with its uploads.

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

### Pacing lives in two layers, because a request and a job are not the same thing

*Considered:* one pacer, in the scripts. *Rejected:* a script is a process
that does not outlive its own run, so it can order requests but not jobs, and
the wait it would have to sleep out during a real throttle — tens of minutes —
is a process the host cannot answer for and the user cannot cancel.
*Considered:* one queue, in the host. *Rejected:* the host cannot see
individual requests at all; one job is one script run, which can be forty of
them. *Chosen:* both. `lib/ratelimit.py` paces requests across every process
(flock'd sliding-window counters) and sleeps short waits only; anything longer
becomes `{"kind":"throttled","retryAfter":N}` and `services/requests/` parks
that provider's lane. Neither layer waits out what the other already waited.

### A rate key per provider, not one budget for the host

*Considered:* one shared `graph.microsoft.com` budget, since OneNote and
Sticky Notes talk to the same host with the same app registration.
*Rejected:* it couples them — a OneNote throttle would stop sticky notes
saving, and the limits are nothing alike (OneNote 120/min and 400/hr; a
mailbox far more). *Chosen:* a key each, with its own window, its own cooldown
and its own lane. The cost is that a user who later splits the app
registrations gets no benefit from it; the benefit is that one throttled
backend never becomes three broken ones.

### Admission by rolling count, not by a gap between requests

*Considered:* the obvious pacer — sleep so that requests are never closer
together than budget allows (which is what Notion's `MIN_GAP` was).
*Rejected:* it taxes the common case to protect the rare one. A cold OneNote
listing is ~40 requests that fit inside one minute's budget with room to
spare, and a fixed gap would make it four times slower every single time.
*Chosen:* count the last 60 s and the last 3600 s and admit freely while both
are under budget. Speed is unchanged in normal use and the budget only bites
during a genuinely heavy hour.

### A save already accepted finishes, even after the window closes

The app is otherwise silent while hidden, and that rule is worth keeping: no
timers, no watchers, no reads. But a save is not a read. The user typed the
text and the app took it; discarding it because the overlay was dismissed a
moment later loses work the app had already promised to keep. *Chosen:*
queued **writes** keep draining while hidden, reads and polls stop as they
always did, and a write that fails terminally meanwhile is reported once on
the next open(). Still not an offline queue: it is in memory, this session
only, and quitting the shell ends it.

### Sticky Notes: plain text, no title, no reordering

The backend stores the subject as a copy of the first body line and offers no
ordering — exposing a title field or drag handles would be inventing
behaviour the backend cannot keep.

### The quote bar is an overlay; block formats are read natively when built

Qt rich text has no block borders, so the classic bar beside a quote cannot
live in the document: the editor draws it over the `TextEdit`, anchored with
`positionToRectangle` (NoteEditor, quote bars). Decoration only — it never
touches the document, the caret map or the note.

Finding the quote blocks is the part with options. QML alone can see the
document only as serialised HTML, so the first implementation scanned that
with a regex — workable, but a third private copy of "what counts as a
block, in what order" (the reader and the caret map are the other two), and
its first disagreement was found the day a second opinion existed. So block
formats are now read natively: a ~80-line C++ class (`cpp/textblocks.h`)
that takes the TextEdit's `textDocument` and answers with each block's
position and margins — read-only, so the worst it can do is misplace a bar.

*Considered:* requiring the native module. *Rejected:* every user would need
a compile step `omarchy plugin add` cannot run, and native code loads into
the one shared shell process, where a crash takes everything down — a hard
sell for a decoration. *Considered:* a different rich text editor. *Rejected:*
inside Quickshell there is none — QML offers this engine or a
QtWebEngine-sized dependency, and either way the tested dialect would be
abandoned for it.

*Chosen:* the module is optional. It is built locally against the system Qt
(`sh cpp/build.sh` — on Arch the headers ship with `qt6-declarative`) and
loaded through a directory import behind a `Loader` (ui/NativeBlocks.qml);
when the library is absent the Loader errors and the editor keeps using the
HTML scan (ui/QuoteBars.js). `cpp/selftest.py` runs every round-trip case
through a real document and asserts the two find the same bars, so the
fallback cannot drift from the native truth unnoticed.

### Leaving a block is the second Enter

Enter inside a code block, quote or list continues it — that is Qt's own
behaviour and the right one. The way *out* is Enter again on the empty line
that continuation just made: the empty line comes off the block and a blank
paragraph lands after it, filler selected so typing starts clean. Code and
quotes leave only from their run's last line (an empty line higher up is
content); an empty list item leaves from anywhere, splitting the list the
way every editor does. In a table, the second Enter in the last cell turns
the extra in-cell line into a new row, caret in its first cell.

The edit is not a hand-rolled document surgery: the editor detects the
situation synchronously (the native inspector's block formats, or the HTML
scan as fallback; the table case is two characters next to the caret) and
then takes the same markdown trip as every block tool. One rule made this
expressible: an empty block still carrying the code marker reads back as an
empty line *inside* the fence (`reader.paragraph`), not as a blank between
blocks — which also stopped a typed blank line from splitting a code block
on save.

### Read-only rather than lossy writes

A OneNote page with images or more than the block/section caps, a Notion page
with unsupported blocks, a local file over 2 MiB: all open **read-only with a
visible reason**. Saving would silently destroy content we cannot represent,
which breaks the first rule of the project.

### The four block-style buttons fold into one text-style menu

*Considered:* subscript and superscript as two more rows in the menu.
*Rejected:* the dialect's Markdown has no syntax for them. The parser enables
`task_lists`, `strikethrough`, `table`, `mark` and the underline plugin
(services/markdown/parse.py) — mistune's `~sub~`/`^sup^` extensions are not
CommonMark, OneNote and Notion could not round-trip them, and a style the
save would silently drop breaks the first rule of the project the quiet way.

*Chosen:* one dropdown (`md-format_size`, with a chevron so it reads as a
menu among buttons that act) in place of the h1/h2/h3/p buttons; each row
previews its own size, on the same scale the dialect writes headings at
(`HEADING_FONT_SIZE`). The tool ids stay `h1 h2 h3 p`: providers gate them
one by one and the menu shows only the rows the provider can store — so
`tools` lists in PROVIDERS.md, `$C editorTool h1`, and every provider are
untouched. The menu stands down entirely when no row survives the gate.

It also stands down while the caret is inside a list — restyling a list item
strips its marker and splits the list, a heading mid-list is not a thing the
note can say — the same way the table alteration tools exist only inside a
table. The probe reads the character *before* the caret: the one at the caret
already belongs to the next block at a block edge, which called the last line
of a paragraph a list whenever a list followed it (verified against Qt
offscreen, position by position).

### A tool's edit is one transaction

*Considered:* reordering each tool's strokes so undo at least stops in
sensible-looking states.
*Rejected:* the strokes exist for document reasons (insert-before-remove keeps
a list item's block format; the block tools rebuild the whole note), and no
ordering makes two undo entries feel like one action.

*Chosen:* Qt's own transaction. The native inspector exposes the document's
edit block (`beginEditBlock`/`endEditBlock`, the same mechanism its joined
format writes already used), and `NoteEditor.atomic()` fences every
multi-stroke tool with it — highlight, inline code, link, plain paste, image
paste, and the whole-document rebuild behind every block tool. One ctrl+z
undoes one tool, one ctrl+shift+z replays it, verified offscreen stroke by
stroke. The brackets write nothing; a depth guard ignores a stray end, and
the QML side pairs them in try/finally. QML cannot open an edit block itself,
so when the optional module is not built, undo falls back to walking the
strokes — the fallback's one degradation.

### The paste reads the clipboard itself, because Qt cannot paste its own lists

Qt's copy writes `<!--StartFragment-->` inside a list's first item, and Qt's
paste — the same parser fed the same HTML — fails on exactly that comment to
rebuild the list: a pasted checkbox list arrived flat, every box gone,
bullets alike (engine-notes.md). Stripped of the markers the identical HTML
round-trips whole, so the editor's paste asks `clipboard.py` for the
clipboard's HTML flavour, strips the markers the way the save path always
has, and inserts through the same parser inside one `atomic()` step. A
clipboard with no HTML on offer falls back to Qt's own paste, and the plain
paste (ctrl+shift+v) is untouched.

### A separator line is never an item

The block tools rewrite selected Markdown lines, and selected paragraphs
arrive with blank separator lines between them; restyled, each separator
became an empty item — the extra checkbox after every row. Under a list
style a separator is now never restyled: it is dropped when both of its
neighbours come out as items (the selection reads back as one list), and
kept blank otherwise — before a table or a fence, or beside a line toggling
off. The toggle's other direction gets the mirror rule: two adjacent items
freed of their markers are two paragraphs, and a separator is put between
them where the tight list had none, or Markdown would lazily read them as
one line. Separators own no document block, so the caret never counted them
and neither edit moves it.

### Paragraphs are written tight; a blank line is the air

A block typed into a fresh note carries no vertical margins, but the writer's
bare `<p>` took Qt's default 12px — so the first block tool's rebuild (or a
reload) re-spaced the whole note, Enter-made lines a third further apart than
the author left them. The writer now states `margin-top:0; margin-bottom:0`
on every paragraph, indent and blank line it writes, the same rule the
line-height already followed: state the form, or Qt's default drifts the
typed and the re-rendered note apart. One line is one Enter; the air between
thoughts is the author's own blank line, which the dialect keeps. Lists keep
Qt's canonical 12px outer margins and headings their default air — both exist
only writer-made, so they have no typed form to drift from. Vertical margins
never reach the note (the reader recognises quotes and indents by the
horizontal ones), so this changes rendering, not storage; measured offscreen,
a rebuilt note now sits on the same 130%-line rhythm as a typed one.

---

### A tab per notebook is a setting, not the local provider's privilege

The rail's shape used to be two hardcoded facts: local folders spread into a
tab each, every other source kept one tab. Now it is one per-provider
setting, `providers.<id>.notebookTabs` — local true by default, OneNote
false, either flippable in Settings. Sticky Notes and Notion do not offer
it: a flat list has no notebooks to spread, and a setting that changes
nothing would be a lie in a self-documenting config file.

*Considered:* fanning out in the host — providers keep their one `sections`
shape and the host splits the trees into tabs. *Rejected:* the host cannot
know which tree rows are notebooks; only the provider knows its own
hierarchy (OneNote's trees are notebooks *and* sections, one level inside
the other). So the provider builds its `sections` for the shape asked of
it, and the host stays a thing that renders sections.

The setting travels as a property the host assigns at creation, by a
general rule: every key of a provider's config entry that names a declared
property is handed over, `enabled` excepted — which is also how `notesDir`
arrives now, so nothing about "local" is left in the host's tab pipeline.
The rail's old `local` flag became "ships no logo", which is the rule
PROVIDERS.md had promised all along.

Details that follow from the shapes: the local single tab keeps its note
rows fixed, because a drag across fold-out trees would be a move between
notebooks — a different feature, not a reorder. Local remembers what the
user *folded* where OneNote remembers what they *expanded*, so flipping
local's setting opens with every folder showing while an account of
hundreds of pages opens closed. The sign-out row rides on every OneNote
notebook tab, since any of them is equally the account's. And older config
files need no migration: mergeConfigDefaults fills the new key in on read,
which is that function's whole reason to exist.
