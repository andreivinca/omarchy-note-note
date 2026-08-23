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
- **Python changed** → nothing; the next call picks it up.
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
$C treeToggle "<id>" / toggleSection "onenote/onenote"
$C scrollList 300 / listOffset ""
```

Remember: exactly one argument, so pass `""` when there is none.

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

## Testing the converters

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
Simulate several save cycles through the *real* editor by piping the Markdown
through the offscreen `TextEdit` above, because Qt rewrites what it saves.

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
  the whole shell.

## Checklist for a UI change

1. `qmllint` clean, `py_compile` clean.
2. Restart the shell; log clean.
3. Screenshot the window (`grim -o <output>` then crop with `magick`) and
   actually look at it.
4. Exercise the change through `shell call`, and check the *saved file* or the
   *backend*, not just the screen.
5. If it touches the editor: run the round-trip test again — the editor is
   the part that silently rewrites text.
