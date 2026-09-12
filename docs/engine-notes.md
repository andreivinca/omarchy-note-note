# Engine notes

Everything here cost hours to find. Check this file before debugging
something that "should obviously work".

---

## QML / Quickshell

**Reserved signal and property names.** A `signal changed()` collides with
Qt's property-change signals (`Duplicate signal name`), and
`signal stateChanged()` collides with `Item.state`. Ours are `updated()` and
`persistRequested()`. Likewise a `property var opened` in the host collided
with the shell contract's `opened` bool, and a tab delegate's `active` would
collide with names Qt owns — the sidebar's are `activeSection` and `current`.

**The JS engine has no regex lookbehind.** `"a|b".split(/(?<!\\)\|/)` silently
returns the whole string as one element instead of throwing. Protect escaped
characters by substitution instead.

**`ListView` with section headers does not keep `originY` at 0.** A scrollbar
thumb computed from `contentY` alone sits too low; use
`contentY - originY`. The sidebar has no section headers any more — the tab
rail replaced them — so its `originY` is 0, but the subtraction stays: it is
right either way, and taking it out would quietly re-arm this the day a section
delegate comes back.

**A rotated `Text` is laid out before it is turned.** Its `width` is the run of
the text and its `height` the thickness, whatever the angle. Size it that way
round, and rotate with `rotation` (which turns about `transformOrigin`, centre
by default) rather than `transform: Rotation`, which makes you compute both
origins by hand.

**To square one side of a rounded rectangle, clip it.** Put it in an
`Item { clip: true }` and make it wider than the item by its radius, so the far
corners fall outside. The obvious alternative — a rounded rect plus a square cap
of the same colour — only works with opaque fills: two translucent rectangles
that overlap composite twice and paint a visibly darker strip down the seam.
(The tab rail was built this way and no longer needs it — its tabs are square —
but the lesson holds and the compositing half of it still bites.)

**Replacing a list model resets the scroll.** Both `ListModel.clear()` +
refill and swapping a JS array reset the view to the top. Save
`contentY - originY`, swap, then `forceLayout()` and restore. Restoring before
the new delegates are laid out lands at the bottom.

**Prefer a plain JS array as a model.** The sidebar builds one array and
assigns it; a `ListModel` fixes its roles at the first insert, so every row
must carry every role.

**Loading a component at runtime:** `Qt.createComponent(url)` +
`createObject(parent, props)`; check `comp.status === Component.Error` and log
`comp.errorString()` — otherwise a broken external provider fails silently.

**Focus inside a `Loader`ed component:** `forceActiveFocus()` in the
component's own `Component.onCompleted` runs too early. Focus it from the
loader's `onLoaded` via `Qt.callLater`, or give the field `focus: true` inside
a `FocusScope`.

**`Process` stdin** must be enabled *before* the process starts, and disabled
to deliver EOF: `stdinEnabled = true` → `running = true` → `write(payload)` →
`stdinEnabled = false`. Any other order hangs the script or loses the payload.

**`FileView` has no bounded read.** It is fine for atomic writes
(`atomicWrites: true`), but reading a file the user controls must go through
`lib/readfile.py` — no symlink following, regular files only, capped, with a
deadline (see [security.md](security.md)).

**Lint** with `qmllint -I /usr/share/omarchy/shell <file>` — the shell's
`qs.Ui` / `qs.Commons` modules live there.

---

## `TextEdit` with `textFormat: RichText`

The editor's document is HTML, converted at both ends by
`services/markdown/qthtml/` (see [decisions.md](decisions.md) for why). What
follows is Qt's actual behaviour, measured on 6.11 — the converter is written
against these, and `qthtml/selftest.py` fails the moment one changes.

**Enter at a linked list item's end inherits its anchor.** The empty new
block carries the previous item's URL in its block character format. Clear
the anchor, link colour and underline from that empty block during the same
normalization transaction as the split. Clearing only a text fragment cannot
fix an empty block (`cpp/textlinks.cpp`, `normalizeAnchors`).

**Automatic URL styling belongs in the highlighter.** `TextLinks` applies only
the link colour and underline through `QSyntaxHighlighter`, leaving the
document's character formats, cursor advances, Markdown and undo history
unchanged. Bare URLs track the typed address; explicit Markdown links keep
their label and target. Loading completes the initial highlighting pass while
editor change notifications are guarded, so it cannot mark a note as edited.

The same detector hit-tests document coordinates for the view-bar preview and
direct clicks, including wrapped URLs and table cells. A passive `TapHandler`
uses the drag threshold so selecting text does not open a link; modified
clicks stay with the text editor. The native detector handles all links when
built, and Qt's own activation handles explicit links in the fallback.

**A monospace note font does not make prose into code.** The inline-code
dialect explicitly uses the generic `monospace` family. Match that exact family,
not fixed pitch or any name containing "mono": the app's normal note face is
iA Writer Mono S. Plain-text notes ignore character-format semantics altogether,
since switching Qt's rich document to plain text can retain old anchor formats.

**Qt keeps appearance, not semantics.** The writer serialises how a block
*looks*, so the reader has to infer what it *is*:

| written as | comes back as | read as |
|---|---|---|
| `<h1>` | a paragraph with `font-size:xx-large; font-weight:700` (the tag survives only below the first block) | heading level, from the size |
| `<blockquote>` | a paragraph with `margin-left:40px; margin-right:40px` (the writer adds a muted-colour span for the eye, and the editor draws the quote bar itself, outside the document — Qt has no block borders) | quote (both margins) |
| `<pre>` | a paragraph whose runs are `font-family:'monospace'`, on a block-level `background-color` (a near-invisible marker — the visible slab is drawn by the editor, over the document), without a quote's margins; its left margin is padding, not indent | fenced code (neighbouring ones merge; all-monospace *without* the block background is inline code, and *with* quote margins it is a quote of inline code; a code line's margins are never read back) |
| indentation | `margin-left: 36px` per level, right margin 0 | indent level |
| a checkbox | `<li class="unchecked">` / `class="checked"` | `- [ ]` / `- [x]` |
| a highlight | `background-color:` on the span — **kept**, unlike in Markdown | `==text==` |

**A checkbox's marker is Qt's, its look is ours.** Qt Quick draws a task
item's marker as a raw ☐/☒ text glyph, hardcoded in the renderer
(`qquicktextnodeengine.cpp`, with a "provide a way to have a custom checkbox"
comment deferring it to Qt 7): the glyph's right edge one space-advance ahead
of the text, the glyph its own advance wide and `fontMetrics.height()` tall
from the line's top, in the block's font and colour. A click on it is Qt's
own toggle (`qquicktextcontrol.cpp` flips the block format on release, and
the change comes back through `textChanged`). So the editor keeps the marker
— it carries the state, the serialisation and the click — and draws the box
the eye sees over the glyph's cell (NoteEditor.qml, block decorations;
`marker` in the inspector's `blocks()`, `class="checked"` in the HTML scan).

**Nested lists have no vertical margins** (measured on 6.11). Qt gives the
first and last items of an outer list 12px top and bottom margins, but every
item in a nested list (`QTextListFormat::indent() > 1`) gets zero. Applying
outer margins to every `QTextList` makes a one-item sublist jump by 12px on
both sides when typing anywhere triggers `normalizeListMargins()`. The
normalizer preserves Qt's imported spacing and repairs margins copied by
Enter, joining the triggering edit for undo.

**Link hover must wait for document edits to finish.** Syntax highlighting
runs during table undo, before the document's frame layout is stable.
Emitting link notifications immediately can re-enter `hitTest()` through a
stationary pointer's QML binding and crash in `QTextFrame::firstPosition()`.
The highlighter coalesces notifications on a zero-delay timer, after the
current edit, without delaying the text formatting itself.

**Block backgrounds survive on the paragraph** (measured on 6.11): a
`background-color` in a `<p>`'s style comes back in the same place, is not
copied onto spans that already exist, and vertical margins round-trip.
Code blocks have a 20px margin above their first line and below their last,
leaving 12px of space outside the slab's 8px padding. Interior margins are
zero; `normalizeCodeMargins()` restores this after line splits and joins.
Tables carry 12px top and bottom margins on their frame, matching the clear
space outside a code slab. These margins survive row edits and HTML export;
they are display spacing and do not add blank paragraphs to the Markdown.
The one trap: on a paragraph holding *loose* text — no span —
Qt wraps the text in a new span carrying the same `background-color`, which
the reader would read as a highlight. So a block background may only sit on
a paragraph whose text is entirely inside spans — a code line's always is.

**Typing into an emptied block takes the block's own character format**
(measured on 6.11): with no character left to inherit from, Qt formats the
typed text with the block's character format, which the HTML import took
from the paragraph's own style — the `<p>`'s `background-color`, and no
font unless the `<p>` states one. A code line whose text was deleted and
typed again therefore came back in the body font (the mono family sat on
the span alone), and the reader read the line as a highlighted paragraph.
The writer states `font-family:'monospace'` on the code paragraph itself
(`writer.code`); Qt exports it back in the `<p>`'s style, which the reader
ignores — it reads the spans.

**`readOnly` moves the caret to the end** (measured on 6.11):
`QQuickTextEdit::setReadOnly` moves the cursor to the document's end
whichever way the flag turns, and the editor's scroll follower then brings
the view to it. The session loads every note read-only and releases it
once shown, so a note longer than its pane opened scrolled to the bottom.
The editor applies the flag itself and puts the caret and the scroll back
around it (`NoteEditor.applyReadOnly`).

**Read the document as a range, not as `text`.** `getFormattedText(0, length)`
is what the converter is written against: Qt brackets a range with fragment
markers, and the reader strips them. `TextEdit.text` does answer with the live
document (measured on 6.11: it follows typing, `insert()`, `remove()` and undo)
but without those markers, so the two are not interchangeable.

**A document with no characters has no range** — `getFormattedText(0, 0)` is
the empty string, and a note can hold no characters and still be *something*:
delete the text of a checkbox item and Qt keeps the item, box and all. Read
that way the note comes back blank, so a toolbar action sees a plain empty line
and re-adds the style that is already there — the button looks dead. This is
the one place `text` is the right answer (`NoteEditor.documentHtml`).

**No Markdown is a real answer, not a failed conversion.** A note holding one
blank line — a typed space, or the U+00A0 an empty item carries — converts to
the empty string, because a trailing blank line belongs to no block and is
dropped (`reader._join`). Telling that apart from a converter that died by
looking at the text is what left the toolbar dead on exactly those notes; the
converter says which it was (`Markdown.toMarkdown`, `map.ok`).

**Qt's own output, fed back in, loses the first block's format.** The writer
brackets its output with `<!--StartFragment-->` / `<!--EndFragment-->`; on the
way in, those make Qt treat the HTML as a *pasted fragment*, which merges the
first block into the cursor's block and silently drops its format — a heading
becomes a paragraph, a list stops being a list. Strip the markers from anything
handed back to Qt (`dialect.strip_fragment_markers`).

**A rule cannot open a document** — `<hr />` alone is dropped; it needs any
block above it, even an empty one. **A table cannot open one either**: Qt
inserts an empty block above it on its own, so the writer emits that block
itself, or our idea of the document and Qt's drift apart by one.

**A block with no characters directly above a table takes no height.** Qt
hides it — it is the block Qt itself puts over a document-opening table — so
Enter at the end of a list right before a table, or a delete that bares that
block, leaves the table drawn over the caret's row until the block's content
changes. No relayout brings the row back: `markContentsDirty`, a format edit
and a page-size round trip were all tried (measured on 6.11; a split
mid-list, a bare block above a *paragraph* and an empty block *below* a
table all lay out fine). The inspector puts the dialect's U+00A0 blank into
such a block, joined to the edit that bared it
(`fillEmptyBlocksBeforeTables`), the editor keeps the caret in front of the
filler, and the reader strips a filler trailing typed text — so it never
reaches the note.

**A list item with no content is dropped, and takes the list's checkbox
markers with it** — an empty checkbox carries one U+00A0. This is one of the
two filler characters left in the pipeline.

**An empty block is one U+00A0, never `<p><br /></p>`.** `<p></p>` is dropped
outright, and a `<br />` inside the block opens a *second* line in it — so a
blank line written that way is drawn **twice as tall as a line of text** (92px
against 75px for three blocks at 15px, measured). A non-breaking space is one
line, and one character, so the caret map is the same either way
(`writer.BLANK`). It is also the tidier one to type into: typing on a
`<br />` blank leaves the break behind as a trailing hard line break *and* an
extra blank line, which is the same bug all over again.

**Formatting is flattened into sibling runs.** `**bold with ==mark== inside**`
comes back as three spans that each repeat `font-weight:700`; wrapping each
span in its own markers multiplies them on every save. Read the text into a
flat list of runs and place the markers around the longest stretch that shares
one (`reader._emit`).

**Bold inside a heading needs a heavier weight.** A heading is drawn at
`font-weight:700`, so an author's `**bold**` inside one is indistinguishable
from the heading itself — turning a paragraph into a heading and back used to
eat the markers. The writer writes bold *inside a heading* at `font-weight:900`
(Qt keeps the two apart), and the reader counts only 900 as bold there.

**A link's underline is Qt's, not the author's.** Qt paints links and writes
the painting back as `text-decoration: underline; color:#0000ff` inside the
anchor. Inside an `<a>`, ignore it.

**Plain-text positions.** Blocks are separated by U+2029, a line break inside
a block is U+2028, a table starts each cell with U+FDD0 and ends with U+FDD1.
So the block a caret sits in is the number of U+2029 plus U+FDD0 before it —
which is how the toolbar turns a caret into a Markdown line, via the map
`qthtml.convert()` returns.

Read the full plain text before counting separators up to the caret: a
`getText(0, caret)` range touching a table can include cells past the caret.
A table row's Markdown line maps to its first cell's block, and all exported
paragraphs inside its cells count toward the following row's block number.
Qt can omit an empty paragraph at the start of a cell from its HTML, though,
so block counts cannot reliably locate a table after Enter. The second Enter
finds the table by document order, appends after its final Markdown row
(after the separator for a header-only table), and restores the caret by
cell order. Table-shaped text inside fenced code does not count as a table.

**An image that opens a list item is painted ~200px too high.** The document
is right (`<li><img …/>text</li>`), the painting is not: Qt Quick's text node
draws the image over the items above it. The same item renders correctly once
anything precedes the image — a `<br/>`, or one U+00A0. So the loader writes a
non-breaking space in front of such an image (`dialect.IMAGE_LEAD`), the
converter strips it again, and the editor does the same live: on Enter with
the caret right before an image inside a list item, and after a paste that
lands there (`NoteEditor.beforeReturn`, `guardImageAt`; its `imageLead`
mirrors the dialect constant). A link around the image changes nothing —
`<li><a…><img …/></a>` is mispainted identically (measured offscreen, same
rows) — so the writer's guard looks through an anchor too.

**Qt cannot paste its own lists.** The copy serialises the selection with a
`<!--StartFragment-->` comment *inside* the first `<li>`, and on that comment
Qt's HTML parser fails to rebuild the `QTextList`: every pasted list arrived
flat — bullets and checkboxes alike, the boxes not painted because the marker
survives only as a block format on a non-list block (measured offscreen,
position by position). The identical HTML with the comments stripped
round-trips whole, so the editor's paste takes the clipboard's HTML itself
(`clipboard.py html`, wl-paste's text/html), strips the markers — the same
strip the save path always did (`dialect.strip_fragment_markers`) — and
inserts it through the same parser (`NoteEditor.pasteRich`). Qt's own
qrichtext meta rides in the HTML head, so the parse mode matches Qt's paste
exactly.

**A pasted fragment brings its own formats, block formats included**
(measured on 6.11): text pasted through `insert()` or Qt's own paste keeps
the clipboard's character formats — a sans-serif span, or a span with no
family at all — and each block after the first takes the fragment's block
format, not the block it lands in. Inside a code block either one ends the
block (the reader wants all-monospace runs on the block background), so a
paste there is the plain paste, put in through `QTextCursor::insertText`
(cpp/textblocks.h, `insertPlainText`): each newline starts a block in the
caret's own block format and the text takes the caret's character format,
which is exactly what typing does (`NoteEditor.pastePlain`, decisions.md).

**`insert()` parses HTML** in this mode, and `remove()` + `insert()` are
ordinary edits, so ctrl+z still walks back through toolbar actions. Assigning
`text` would wipe the undo stack. On their own the two edits are two undo
steps, and ctrl+z surfaced a tool's intermediate states (both copies of a
highlighted word; an empty note under a block tool) — so every multi-stroke
tool runs inside `NoteEditor.atomic()`, a `QTextCursor` edit block exposed by
the native inspector (`beginEditBlock`/`endEditBlock`, cpp/textblocks.h):
one transaction, one undo step, and the normalize passes that join the edit
join the same step. QML alone cannot open an edit block, so without the
built module undo degrades to walking the strokes again.

**Delete on an empty paragraph must remove the whole block**, including its
U+00A0 rendering filler. Qt's ordinary Delete at the end of that filler only
removes the separator; the following list item then joins a non-list block
and loses its marker. `TextBlocks.deleteParagraphBoundary()` gives the empty
block the following block's format and block character format before removing
it, so an empty heading cannot pass its size or weight to the list. Table and
frame boundaries retain Qt's own deletion behavior.

Paragraph-boundary deletion uses an edit block so the normalizers' repairs
join the deletion. `joinPreviousEditBlock()` cannot combine a format change
with Qt's ungrouped single-character Delete. Undo and Redo also emit text
changes; `NoteEditor.replayHistory()` suppresses normalization during replay,
otherwise the repairs become fresh edits that alter history and discard
Redo. Keyboard shortcuts and the editor's public undo/redo functions use
the same guard. Real-key tests compare the full HTML before Delete and after
Undo, and repeat Undo/Redo to check that both directions remain stable.

**Verify offscreen** rather than guessing — it takes seconds:

```bash
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 qml6 /tmp/t.qml
# inside: console.error(JSON.stringify(edit.getFormattedText(0, edit.length)))
```

Note that a literal U+2029 inside a QML string ends the line and breaks the
parse; write `"\u2029"`.

---

## Markdown

The single parser is `services/markdown/parse.py` (vendored mistune 3.3.4,
BSD-3) with two extras: `task_lists`, `strikethrough`, `table`, `mark`
(`==highlight==`) and a **custom underline rule** for Qt's `_x_`.

Providers own only the **renderers** (AST → OneNote HTML, AST → Notion
blocks) and the **writers** (backend → Markdown); the editor's own pair lives
in `services/markdown/qthtml/`. Hand-rolling a Markdown *parser* is what
produced the escape/soft-wrap/nesting bugs; do not do it again.

When writing Markdown *from* a backend, escape plain text that would
otherwise be read as Markdown: inline `* _ \` ~ [ ] < > |`, and line starts
`#`, `>`, `-`, `1.`, `---`, `|`. A line of dashes under a line of text is a
setext heading — that is why a plain `Test` above `------` once rendered huge
and bold.

**Escape only what would change meaning.** A note that says `2 * 3` must not
grow a backslash on every save — that was Qt's own habit, and copying it just
moves the complaint. `_` does not emphasise inside a word (`user_name_field`
is not emphasis), `*` and `~` matter only next to a non-space character, and
`- ` at a line start is a bullet while `**bold**` is not. `qthtml/mdtext.py`
holds the rules, and `reader` checks its own output by re-parsing it: if a
single character would have changed meaning, the note is rendered again with
strict escaping.

---

## Microsoft Graph

**Sticky Notes are mailbox items.** They live in the well-known `notes` mail
folder; the API is the mail API (`Mail.ReadWrite` — there is no narrower
scope). The **subject is a copy of the first body line**, so there is no
separate title. Creating one only counts as a sticky note if the MAPI message
class is set: extended property `String 0x001A` = `IPM.StickyNote`.

**OneNote quirks**

- `lastModifiedDateTime` is **not reliably updated** when a page is edited
  (an edit from a phone left a 2021 timestamp), so the open page is re-read on
  a poll and compared by text.
- The account-wide `/me/onenote/pages` refuses accounts with many sections
  (*"The number of maximum sections is exceeded"*); list per section, in
  parallel, with a cache.
- A **title `PATCH` on some older pages always returns 500 "Transient error
  occured while processing request. {0}"** — Microsoft's own placeholder bug.
  Send body and title as separate requests, only send the title when it
  actually changed, and treat a title failure as a warning, not a save
  failure.
- Paragraphs default to 5.5 pt of space above and below; write
  `style="margin-top:0pt;margin-bottom:0pt"` or every line looks
  double-spaced. Indentation is `margin-left`, 36 px per level.
- A bare `<br/>` between paragraphs is a **visual empty line**; a
  `<p><br/></p>` is the same thing written by the phone app. Consecutive ones
  are separate empty lines, and one may follow *any* block — a page routinely
  reads `…<img/><br/><p>text</p>`, which is a picture with an empty line under
  it. Do not collapse them, and do not decide there is already a blank line
  from the last line of the Markdown being empty: every block ends with an
  empty separator line, so that test throws the blank line away.
- OData query values must be URL-encoded: a raw space in
  `$orderby=lastModifiedDateTime desc` makes `urllib` raise `InvalidURL`.
- **No content search exists.** `/me/onenote/pages?search=…` and `?$search=…`
  both come back `400 "Your request contains unsupported OData query
  parameters"` — measured against a live personal (`@outlook.com`) account,
  the one case an older doc page implied might still work. The endpoint's own
  documented query options are `filter/orderby/select/expand/top/skip/count/
  pagelevel`; `search` is in none of them. `filter=contains(tolower(title),…)`
  works but only reaches `title`, and the account-wide `/pages` call anyway
  refuses accounts with many sections (see above) — so it cannot stand in.
  The provider has no `search()`; the sidebar matches OneNote titles only,
  the same as Notion.
- **Throttling, measured.** Delegated OneNote allows **120 requests/minute**,
  **400/hour** and **5 concurrent** per app+user. Going over earns HTTP 429,
  usually **without** a `Retry-After` — and a throttled account stays
  throttled for tens of minutes, not seconds. So a missing header is read as a
  real cooldown (`ratelimit.DEFAULT_COOLDOWN`, 60 s) rather than a short
  backoff: three quick retries only spend budget to be told the same thing.
  The cooldown is recorded on disk, so the next process fails fast without
  touching the network, and it **survives signing out and back in** — Microsoft
  throttles the app *and* the user, and a new token does not lift it.
- The account-wide `GET /me/onenote/pages` fails with HTTP 400, error 20266
  ("the number of maximum sections is exceeded") — observed at 39 sections. So
  pages are listed per section and there is no bulk endpoint to fall back on;
  what makes that affordable is diffing each section's own
  `lastModifiedDateTime` (returned by the one request that lists all sections)
  and fetching pages only where it moved. A quiet account skips page requests;
  section-order discovery additionally reads OneDrive metadata. The caveat
  is Graph's eventual consistency: a
  change made elsewhere seconds ago can be a refresh cycle late.
- Sections have no Graph `order` property (v1.0 or beta). Personal notebooks
  store their custom order in remote `.onetoc2` metadata, accessible with
  `Files.Read`. The provider reads that format and joins its entries to live
  section IDs; it never introduces manual/local positions. See
  [OneNote section order](onenote-section-order.md) for the live evidence,
  parser/cache design and unsupported or ambiguous cases.
- Page images need the bearer token and are only ever fetched from the
  resource endpoint — see [security.md](security.md) rule 4.

**Editing a page that has images.** All of this was measured; the
documentation disagrees with the service in three places.

- There is **no `delete` action** ("The PATCH action $Delete not supported").
  Replace a removed element with an empty div, which OneNote drops.
- **Paragraph replacement by generated ID works.** Verified with HTTP 204
  while correcting two checklist items; the earlier measurement that returned
  "The PATCH target P for action replace is not supported" is no longer a
  reason to replace the whole text section. Use the current generated ID,
  as in Microsoft's [to-do update example](https://learn.microsoft.com/en-us/graph/onenote-update-page#update-a-to-do-item).
  If the API rejects an item update, preserve the draft and report the error;
  never retry that rejection as a whole-page replacement.
- **A correct text merge is not enough for phone sync.** Replacing a whole
  text section removes unchanged item identities. A phone can later sync an
  edit to an old item and OneNote can append it as another item. The observed
  duplicate was already present in the next Graph read, before our text merge.
  `onenote_patch.py` uses the shared `notemerge.align` library to plan changes
  to individual paragraphs, headings, list items and table-cell paragraphs,
  leaving unchanged elements untouched. Checkbox state edits
  retain the original item's inline HTML and change the checkbox carrier's
  `data-tag`, including spans inside bulleted or numbered lists. A simulated
  application of the commands must match the merged document and preserve
  unchanged element IDs and attributes before writing. Bare blank lines do
  not disable granular updates. An unsupported edit or failed simulation
  preserves the draft and reports an error; there is no page rebuild fallback.
- A div can only be replaced by its **generated id**, never by its `data-id`
  (that one works for `insert`/`append`). Generated ids change on every write,
  so they must be read back with `?includeIDs=true` before each patch.
- `data-id` attributes we write **do** survive an update, which is what makes
  a text run findable again.
- Handing back an image by its own resource URL is **accepted but unsafe**:
  OneNote *copies* the resource (re-encoding it — a PNG came back JPEG), and a
  copy taken of a resource the service has not materialised yet is **empty
  forever** — its `$value` and `data-fullres-src` both serve 0 bytes, still
  empty 35 minutes later. Measured, twice. So a save must never mention an
  unchanged image at all: individual text elements are replaced where they stand, a deleted
  image is replaced with `<div></div>` (which OneNote then drops), a pasted
  one is uploaded as a part — and an image that did not change appears in no
  command (`onenote_patch.py`). Changed images are uploaded from their local
  bytes. Each upload carries a unique `data-id`, so the returned resource is
  associated with its local file independently of command or document order.
- A `replace` may carry **several sibling elements** in one content string
  (`<div>…</div><img …/><div>…</div>`), which is what lets one command rewrite
  the whole gap between two images.
- An uncertain `insert` or `append` must not automatically retry, even without
  image parts: the first request may have inserted the item already.
- A freshly written resource serves **200 with an empty body** until it
  materialises; never cache such a response (it used to poison the page — the
  cache then served the empty file forever).
- Uploading is multipart with a `Commands` part; Graph rejects a request over
  4 MB, and parts count against it.
- **Reads are eventually consistent.** A page fetched right after a write can
  still show the old content — 8 seconds was not always enough while testing.
  Do not verify a save by reading it straight back.

**No usable change notifications.** Graph webhooks (and Notion's) need a
public HTTPS endpoint; a desktop plugin cannot have one. Polling cheaply is
the answer — and *cheaply* is load-bearing: the OneNote poll used to re-list
every expanded section every minute, up to 11 requests a minute, which is 660
an hour against a budget of 400. Polling alone could exhaust the account. It
now checks the open page and the section that page is in, and leaves the rest
to the periodic listing above.

---

## Pacing requests — two layers, one wait

Every HTTP request happens inside a short-lived `python3` process; the QML
host is the only long-lived one. One QML job is one script run, which can be
forty requests the host cannot see. So the pacing is split, and the split is
the whole design:

| | owns | waits |
|---|---|---|
| `services/requests/` (QML) | ordering: per-key FIFO, coalescing, priority, concurrency | the **long** ones — a throttle cooldown, a transient backoff |
| `lib/ratelimit.py` | pacing individual requests across every process (`flock`'d sliding-window counters) | the **short** ones only, up to `PACE_TIMEOUT` (20 s) |

Anything longer than `PACE_TIMEOUT` is never slept out inside a script — a
process blocked for ten minutes is one the host cannot answer for and the user
cannot cancel. It comes back as `{"kind":"throttled","retryAfter":N}`, and the
QML lane parks until it is over. Neither layer waits out what the other
already waited.

Admission is by rolling **count**, not by a fixed gap between requests: while
the window counts are under budget everything goes straight through, so a cold
listing is exactly as fast as it was and only a genuinely heavy hour is paced.

**`flock` on an exotic filesystem** (an NFS home) can degrade to no locking at
all. That means over-admission, never a deadlock — two processes may both
think there is room — and the QML lane bounds the damage, since it is what
actually stops after a 429.

**A slot holder that dies** — killed mid-request, crashed — would hold its
concurrency slot for ever. Holders are stamped with a pid and a time and
reaped on the next acquire, by `os.kill(pid, 0)` and by an age (90 s, longer
than any request here). `lib/ratelimit_selftest.py` pins both, and runs eight
real processes at one key to check the counters actually hold.

---

## Notion

- Access is an **internal integration secret** the user creates and pastes;
  pages must additionally be shared with the integration ("Connections").
- The API **cannot create a top-level page** — a new page needs a parent page
  id.
- Rate limit ≈ 3 requests/second, paced by `lib/ratelimit.py` against the
  `notion` key. This used to be a 0.34 s sleep between requests inside one
  process, which said nothing about the other processes the host had running
  at that moment; the pacer counts them all. Children are appended in batches
  of 100 blocks.
- `/v1/search` matches **page titles only** — the reference page is literally
  titled "Search by title". There is no full-text search in the public API,
  so the provider deliberately has no `search()`: content search would mean
  fetching every page's blocks per query.
- Highlights are `*_background` colours in the `annotations` object.

---

## Omarchy shell

- `omarchy-shell shell rescanPlugins` does **not** reload the QML of a
  `keepLoaded` plugin: use `omarchy-restart-shell` after a QML change.
- `omarchy-shell shell call <plugin-id> <function> <arg>` takes **exactly
  one** argument — pass `""` when the function needs none. This is the main
  test harness (see [testing.md](testing.md)).
- Plugin ids are reverse-DNS and **permanent** in the marketplace.
- Plugins cannot register a keybind themselves; the user binds
  `omarchy-shell shell toggle <id>` in `~/.config/hypr/bindings.lua`.
- `inotify-tools` is part of Omarchy's base install, so a watcher is free to
  use.
