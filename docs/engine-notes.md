# Engine notes

Everything here cost hours to find. Check this file before debugging
something that "should obviously work".

---

## QML / Quickshell

**Reserved signal and property names.** A `signal changed()` collides with
Qt's property-change signals (`Duplicate signal name`), and
`signal stateChanged()` collides with `Item.state`. Ours are `updated()` and
`persistRequested()`. Likewise a `property var opened` in the host collided
with the shell contract's `opened` bool — sidebar state is `openedSections`.

**The JS engine has no regex lookbehind.** `"a|b".split(/(?<!\\)\|/)` silently
returns the whole string as one element instead of throwing. Protect escaped
characters by substitution instead.

**`ListView` with section headers does not keep `originY` at 0.** A scrollbar
thumb computed from `contentY` alone sits too low; use
`contentY - originY`.

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
(`atomicWrites: true`), but reading a file the user controls must go through a
bounded `head -c` (see [security.md](security.md)).

**Lint** with `qmllint -I /usr/share/omarchy/shell <file>` — the shell's
`qs.Ui` / `qs.Commons` modules live there.

---

## `TextEdit` with `textFormat: RichText`

The editor's document is HTML, converted at both ends by
`services/markdown/qthtml/` (see [decisions.md](decisions.md) for why). What
follows is Qt's actual behaviour, measured on 6.11 — the converter is written
against these, and `qthtml/selftest.py` fails the moment one changes.

**Qt keeps appearance, not semantics.** The writer serialises how a block
*looks*, so the reader has to infer what it *is*:

| written as | comes back as | read as |
|---|---|---|
| `<h1>` | a paragraph with `font-size:xx-large; font-weight:700` (the tag survives only below the first block) | heading level, from the size |
| `<blockquote>` | a paragraph with `margin-left:40px; margin-right:40px` | quote (both margins) |
| `<pre>` | a paragraph whose runs are `font-family:'monospace'` | fenced code (neighbouring ones merge) |
| indentation | `margin-left: 36px` per level, right margin 0 | indent level |
| a checkbox | `<li class="unchecked">` / `class="checked"` | `- [ ]` / `- [x]` |
| a highlight | `background-color:` on the span — **kept**, unlike in Markdown | `==text==` |

**`text` is not the document.** In rich text, `TextEdit.text` answers with the
string last *assigned* to it, not with what the document now holds: reading it
after an edit returns the note as it was opened. Always
`getFormattedText(0, length)`. (In `MarkdownText` it did regenerate, which is
why the old code got away with `area.text`.)

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

**A list item with no content is dropped, and takes the list's checkbox
markers with it** — an empty checkbox carries one U+00A0. This is the only
filler character left in the pipeline.

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

**An image that opens a list item is painted ~200px too high.** The document
is right (`<li><img …/>text</li>`), the painting is not: Qt Quick's text node
draws the image over the items above it. The same item renders correctly once
anything precedes the image — a `<br/>`, or one U+00A0. So the loader writes a
non-breaking space in front of such an image (`dialect.IMAGE_LEAD`), the
converter strips it again, and the editor does the same live: on Enter with
the caret right before an image inside a list item, and after a paste that
lands there (`NoteEditor.beforeReturn`, `guardImageAt`).

**`insert()` parses HTML** in this mode, and `remove()` + `insert()` are
ordinary edits, so ctrl+z still walks back through toolbar actions. Assigning
`text` would wipe the undo stack.

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
  `<p><br/></p>` is the same thing written by the phone app.
- OData query values must be URL-encoded: a raw space in
  `$orderby=lastModifiedDateTime desc` makes `urllib` raise `InvalidURL`.
- Throttling (HTTP 429, often **without** a `Retry-After`) arrives quickly if
  you re-list repeatedly while testing. Back off, cache, and reduce
  parallelism.
- Page images need the bearer token and are only ever fetched from the
  resource endpoint — see [security.md](security.md) rule 4.

**Editing a page that has images.** All of this was measured; the
documentation disagrees with the service in three places.

- There is **no `delete` action** ("The PATCH action $Delete not supported"),
  and **`replace` on a `p` is not supported either** ("The PATCH target P for
  action replace is not supported") — whatever the docs' table says. The only
  things that can be rewritten are the page `body`, a **div inside a div**, and
  an `img`.
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
  unchanged image at all: text runs are replaced where they stand, a deleted
  image is replaced with `<div></div>` (which OneNote then drops), a pasted
  one is uploaded as a part — and an image that did not change appears in no
  command (`plan_commands` in onenote.py).
- A `replace` may carry **several sibling elements** in one content string
  (`<div>…</div><img …/><div>…</div>`), which is what lets one command rewrite
  the whole gap between two images.
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
the answer.

---

## Notion

- Access is an **internal integration secret** the user creates and pastes;
  pages must additionally be shared with the integration ("Connections").
- The API **cannot create a top-level page** — a new page needs a parent page
  id.
- Rate limit ≈ 3 requests/second (we pace at 0.34 s) and children are appended
  in batches of 100 blocks.
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
