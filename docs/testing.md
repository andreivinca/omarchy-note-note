# Testing and development

There is no test runner: the plugin lives inside a running desktop shell.
What follows is how changes are actually verified.

## Development loop

```bash
ln -s ~/Projects/note-note ~/.config/omarchy/plugins/io.github.andreivinca.note-note
omarchy plugin enable io.github.andreivinca.note-note
```

- **QML changed** → `omarchy-restart-shell` (a `rescanPlugins` will *not*
  reload a `keepLoaded` plugin). Expect ~4 s.
- **Python changed** → nothing; the next call picks it up. That includes the
  editor's converters, which run as a process per conversion.
- Always lint first: `qmllint -I /usr/share/omarchy/shell Notes.qml ui/*.qml
  providers/*/Provider.qml`, and `python3 -m py_compile` the scripts.
- Always check the log after a restart:
  ```bash
  journalctl --user --since "20 sec ago" --no-pager -o cat | grep -iE "Notes\.qml|Provider|NoteEditor"
  ```
  QML errors appear there and nowhere else.

## Driving the app without a keyboard

Every function on the root item is callable over IPC — this is how nearly
everything in this project was verified:

```bash
C="omarchy-shell shell call io.github.andreivinca.note-note"
$C debugState ""                 # currentPath, loading, status, words, readOnly, providers
$C selectPath "local:/home/you/Notes/x.md"
$C editorTool h1                 # any toolbar tool id
$C editorCursor 42               # move the caret; prints position + in-table
$C runAction setup               # a sidebar action row
$C treeToggle "<id>" / activateSection "onenote/onenote"
$C tabsInfo ""                   # every tab: key, name, colour, count, search hits
$C scrollList 300 / listOffset ""
```

Remember: exactly one argument, so pass `""` when there is none.

**Drive it with the window open.** While it is hidden the local provider has
not listed anything, so its rows are empty and the host deselects the open
note the moment anything rebuilds them — the editor then looks broken, and is
not. `omarchy-shell shell toggle io.github.andreivinca.note-note` first.

For real keystrokes `wtype` works (`wtype "text"`, `wtype -k Return`,
`wtype -M ctrl b -m ctrl`) — but it types into whatever has focus, so never
run it while the user may be using the machine.

## Testing Qt behaviour in isolation

Faster and safer than testing inside the shell:

```qml
// /tmp/t.qml
import QtQuick
Window { visible: true
  TextEdit { id: a; textFormat: TextEdit.MarkdownText; font.family: "sans-serif"; text: "…" }
  Timer { interval: 50; running: true; onTriggered: {
    console.error("out:", JSON.stringify(a.text)); Qt.exit(0) } }
}
```

```bash
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 timeout 10 qml6 /tmp/t.qml
```

`console.log` is swallowed by this runner; use `console.error`. `qml6` is the
Qt 6 runner — plain `qml` is Qt 5 and will silently load nothing.

## Testing the editor's document format

The editor holds HTML and the note is Markdown, so the test that matters is
that the loop closes. It runs offscreen, without the shell:

```bash
python3 services/markdown/qthtml/selftest.py [-v]
```

Each case goes markdown → html → **a real Qt document** → html → markdown and
must come back identical, on both paths the app uses: the save path, and the
path a toolbar action takes when Qt is handed its own HTML again. It also
checks that the document reaches a fixpoint, and that the line → block map
counts blocks the way Qt counts them — the toolbar finds the caret's line
through that map, so a drift there moves edits to the wrong line.

**Add a case to `CASES` for every formatting bug**, in the shape a note has on
disk. It is three lines of work and it is why the awkward cases (a rule alone
in a note, an empty checkbox, a table after a quote, `2 * 3`,
`user_name_field`) stay fixed.

## Testing the provider converters

Pure Python, no shell involved — the best place to add regression cases:

```bash
python3 - <<'EOF'
import sys; sys.path.insert(0, "providers/onenote"); import onenote_md as m
md = m.html_to_markdown('<body><p>Test</p><p>--------------</p></body>')["body"]
html = m.markdown_to_onenote_html(md)
print(repr(md)); print(html)
print("stable:", m.html_to_markdown("<body>"+html+"</body>")["body"] == md)
EOF
```

**Round-trip stability is the property that matters**: backend → Markdown →
backend → Markdown must reach a fixed point. Most formatting bugs (duplicated
blank lines, growing indentation, vanishing checkboxes) are a failure of this.
The editor's own leg of that loop is covered by `qthtml/selftest.py`; a
provider's leg is not, so test it the same way — convert both directions twice
and compare.

## Testing the OneNote save planner

`plan_commands` decides what a save touches, and must never touch an
unchanged image. It is pure — plan against a fake structure, no network:

```bash
python3 - <<'EOF'
import sys; sys.path.insert(0, "providers/onenote"); import onenote
page = [{"kind": "text", "id": "div:{a}"},
        {"kind": "image", "id": "img:{b}", "src": "https://…/resources/AAA/$value"}]
note = [{"kind": "text", "html": "<p>edited</p>"},
        {"kind": "image", "html": "…", "ref": "https://…/resources/AAA/$value"}]
for c in onenote.plan_commands(note, page):
    print(c["action"], c["target"], c["content"][:60])
EOF
```

The invariants worth checking after any change: a text-only edit produces only
div replaces; a kept image's id appears in **no** command; a reordered image
or a foreign page shape returns `None` (the caller then rebuilds with every
image uploaded, never referenced).

## Testing against real accounts

The scripts run standalone with the same environment the provider uses:

```bash
export NOTE_NOTE_MS_TOKEN=$HOME/.local/state/omarchy/note-note-ms-onenote.json
python3 providers/onenote/onenote.py list --cached
python3 providers/onenote/onenote.py page "<id>"
echo '{"title":"t","originalTitle":"t","body":"x"}' | python3 providers/onenote/onenote.py update "<id>" -
```

Rules when a real account is involved:

- **Create a throwaway page/note, test on it, delete it.** Never edit the
  user's real notes to prove a fix.
- Never print, screenshot or commit note contents — they are private. This was
  violated once (a README preview leaked note titles) and required a
  force-push.
- Re-listing repeatedly gets the account **throttled** (HTTP 429) for tens of
  minutes; use `--cached`, and prefer the standalone script over restarting
  the whole shell. While throttled, everything degrades at once: page loads
  fail (and a page with images then correctly refuses to save), and a page
  *created* during the throttle can come back 201 with an id whose content
  404s **forever** — a service-side casualty, not a bug here. Wait it out and
  create a fresh page rather than debugging a poisoned one.
- Writes are **eventually consistent**: a GET right after a PATCH can return
  the old content. Wait ~15 s before verifying, and never poll in a tight
  loop — that is what triggers the throttle.

## Checklist for a UI change

1. `qmllint` clean, `py_compile` clean, `qthtml/selftest.py` green.
2. Restart the shell; log clean.
3. Screenshot the window (`grim -o <output>` then crop with `magick`) and
   actually look at it.
4. Exercise the change through `shell call`, and check the *saved file* or the
   *backend*, not just the screen.
5. If it touches the editor: run the round-trip test again — the editor is
   the part that silently rewrites text.
