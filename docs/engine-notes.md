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

## `TextEdit` with `textFormat: MarkdownText`

This is a **rich-text document with a Markdown reader and writer bolted on**,
not a text buffer. Most surprises follow from that.

| Behaviour | Consequence for us |
|---|---|
| `_x_` is parsed as **underline**, `*x*` as italic (Qt's own dialect) | our parser has a custom underline rule; underline round-trips as `_x_` |
| The writer emits only what Markdown expresses | a character **background colour is dropped on save** → highlight is carried as `==text==` markers |
| The writer **escapes anything that looks like Markdown** when you type it (`\-`, `\#`, `1\.`, `\*`) | the converters must unescape before sending to a backend, or the backslashes reach OneNote |
| The writer **soft-wraps paragraphs at ~80 columns** | a line-based parser turns wraps into separate paragraphs; join soft-wrapped lines, treat only `"  \n"` as a line break |
| The writer **drops empty paragraphs** | an empty line typed in the editor cannot survive; an existing one is carried as a paragraph holding U+00A0 |
| A **monospace font family serialises as a code span** | never set the editor font to a mono family — that is why OneNote pages once came back as `` `everything` `` |
| `- [ ] ` with **no content** collapses to a plain bullet | an empty checkbox is created with a U+00A0 body |
| A **table or code block directly after a quote** serialises corrupted | insert a U+00A0 paragraph between them |
| **Block formatting is not exposed to QML** (only `cursorSelection.font`) | block styles are applied by marking paragraphs with a private marker, re-serialising, rewriting the marked Markdown lines, and reloading |
| `getText()` is **table-granular**: a range touching a table returns the whole table | caret arithmetic near tables must scan the full text |
| Plain text uses **U+2029** between paragraphs, **U+FDD0** between table cells, **U+FDD1** at a table's end | that is how "is the caret in a table cell?" is answered exactly |
| No link colour API (`linkColor` does not exist; `palette.link` does not reach the Markdown renderer) | links are Qt's default blue |

**Verify Qt behaviour offscreen** rather than guessing — it takes seconds:

```bash
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 qml6 /tmp/t.qml
# inside: console.error(JSON.stringify(edit.text)) — note that console.log is swallowed
```

---

## Markdown

The single parser is `services/markdown/parse.py` (vendored mistune 3.3.4,
BSD-3) with two extras: `task_lists`, `strikethrough`, `table`, `mark`
(`==highlight==`) and a **custom underline rule** for Qt's `_x_`.

Providers own only the **renderers** (AST → OneNote HTML, AST → Notion
blocks) and the **writers** (backend → Markdown). Hand-rolling a Markdown
*parser* is what produced the escape/soft-wrap/nesting bugs; do not do it
again.

When writing Markdown *from* a backend, escape plain text that would
otherwise be read as Markdown: inline `* _ \` ~ [ ] < > |`, and line starts
`#`, `>`, `-`, `1.`, `---`, `|`. A line of dashes under a line of text is a
setext heading — that is why a plain `Test` above `------` once rendered huge
and bold.

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
