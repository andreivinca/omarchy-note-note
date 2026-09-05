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
  providers/*/Provider.qml services/*/*.qml`, and `python3 -m py_compile` the
  scripts. For Python there is also `uvx ruff check .`, configured in
  `pyproject.toml` — it needs nothing installed and it is narrowed to the
  rules that catch defects (a stale import, an unused local) rather than to
  opinions about a deliberate house style. It should be silent; it found
  three pieces of dead code the first time it was run.
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
$C debugState ""                 # currentPath, loading, dirty/saving, status, words, readOnly, providers
                                 # rows/revision/rowWrites/offset: what the list is doing
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

## Testing the request queue and the pacer

Both run without the shell, a display or an account, and both are fast.

```bash
python3 lib/ratelimit_selftest.py            # the cross-process pacer
python3 services/requests/selftest.py        # the queue (offscreen qml6)
```

`ratelimit_selftest.py` runs the window and cooldown maths on a **fake clock**
— `slot()` takes its `now` and `sleep` from the caller, so a sixty-second park
costs nothing and every case is exact — and then starts **eight real
processes** on one key to check the two things a fake clock cannot: the rolling
window count was never exceeded, and no more than `MAX_CONCURRENT` holders
existed at once. It also pins the stale-holder reaper (a dead pid, and a slot
older than 90 s), because a process killed mid-request would otherwise hold its
slot for ever.

`services/requests/selftest.py` runs `selftest.qml` under offscreen `qml6`.
Its scheduler half calls `scheduler.js` with the clock as an argument (per-key
FIFO, priority, the round-robin, replace/dedupe, the throttle park and its
backoff, transient retries, pause, `cancelOwner`); its queue half drives a real
`RequestQueue` with real timers, which is the only way to check the property
that matters: **every enqueue is answered exactly once**, including when the
job is superseded, cancelled, answers twice, throws from `start`, or throws
from `settled`.

**Add a case for every queueing bug.** A lost callback is a note that silently
did not save, and it will not show up in any other test.

## Testing the provider scripts

Four suites, and none of them needs the shell, a display, an account or the
network — every request is answered by a stub:

```bash
python3 providers/local/selftest.py       # the listing's order, and statx(2)
python3 providers/notion/selftest.py      # a page is never emptied to save it
python3 providers/onenote/selftest.py     # which writes may be run again
python3 services/microsoft/selftest.py    # 5xx and 401 classification
```

Each pins a bug that shipped, and was found by a review of the Python:

- **`providers/local/selftest.py`** — notes list oldest-first by **birth
  time**, read through `statx(2)`, because `os.stat()` carries no
  `st_birthtime` on Linux: the old key defaulted to 0 for every note and fell
  through to a tie-break that compared *size as text*, so a note reordered
  itself as it was typed into. It checks the `struct statx` layout as well,
  since an offset wrong by eight bytes still hands back a plausible timestamp.
- **`providers/notion/selftest.py`** — a save PATCHes the new blocks in
  **before** deleting the old ones. Written the other way round it deleted
  first, so a refused insert — a 400 on a block Notion will not take, or the
  app being killed — left the page permanently empty. The test forces the
  insert to fail and asserts nothing was deleted.
- **`providers/onenote/selftest.py`** — `graph_raw` is a second copy of the
  decisions `msgraph.http` makes, so it is tested separately: the same 401
  pass, and the gate that says whether a failure may be run again. A
  `kind: "transient"` re-runs the **whole job** three times, which is right
  for a page fetch or a body replace and wrong for anything that creates — a
  502 is the gateway losing the answer to a page Graph may already have made,
  and a re-run would leave the user with two or three. The creates, the
  sign-in flow and any save carrying image uploads therefore shut the gate,
  and the test reads the flag off the calls rather than inferring it.
- **`services/microsoft/selftest.py`** — 429 and 503 park the lane; 500, 502
  and 504 come back as `kind: "transient"` and re-run that one job; and a 401
  on a token the disk still calls valid forces one refresh and retries once.
  A grant that will not refresh is deleted, so the UI offers a sign-in instead
  of repeating a raw Graph error for ever — but a *server* error during that
  forced refresh must not, or a passing blip would sign the user out.

**Add a case for every provider-script bug.** Three of the four finish in
about a tenth of a second; `providers/local/selftest.py` takes around four,
and is meant to — a birth time cannot be forged, so it really does wait a
second between creating its notes. They are the only tests that cover what a
script does when the far end misbehaves.

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
  create a fresh page rather than debugging a poisoned one. (Creating is now
  refused outright during a recorded cooldown, which is what stops that.)
- A throttle can be **simulated without one**, which is how the queue's
  behaviour is checked against a real account without earning a real 429:

  ```bash
  python3 -c "import sys; sys.path.insert(0,'lib'); import ratelimit; \
              ratelimit.report_throttle('graph-onenote', 120)"
  python3 providers/onenote/onenote.py page "<id>"   # throttled JSON, well under a second
  python3 -c "import sys; sys.path.insert(0,'lib'); import ratelimit; \
              ratelimit.clear_throttle('graph-onenote')"
  ```

### The manual checklist for pacing

With the shell running, and the OneNote tab open:

1. `onenote.py list` twice in a row — the second is paced, and
   `$RATE/graph-onenote.json` has a stamp per request.
2. Write a `cooldownUntil` as above, then `onenote.py page <id>`: structured
   throttled JSON, no network touched, under a second.
3. In the app, type through the debounce: **one** save sequence per settle,
   and `$C debugState ""` shows `saving` returning to false.
4. Delete the open page while a save is queued — the delete supersedes the
   save, no resurrection, and both callbacks are answered.
5. Close the overlay during a synthetic cooldown and reopen it: the write is
   still draining, the countdown resumed where it was (it is wall-clock), and
   a save that failed while hidden is reported once on reopen.
6. Disable and re-enable OneNote in Settings mid-queue: no warnings in the
   log, and the cooldown is still there afterwards.
7. Sticky Notes lists instantly while OneNote is cold-listing — separate keys,
   separate lanes.
8. `$C debugState ""` reports `queues` with each lane's depth and cooldown.
- Writes are **eventually consistent**: a GET right after a PATCH can return
  the old content. Wait ~15 s before verifying, and never poll in a tight
  loop — that is what triggers the throttle.

### The manual checklist for what a tab opens with

`debugState` reports `defaultOwed`: true while the tab on screen has not been
given its opening note yet, false once it has been or the user has picked.

1. A tab you have never been in opens empty and stays `defaultOwed` — nothing
   is picked for you. Select a note there, switch away, switch back: that note.
   A note the app put on screen by itself does not count as picking: search
   for something, let the landing select the first hit, clear the search and
   restart — the tab still opens on the note *you* chose last, and the state
   file was not written per keystroke.
2. Restart the shell. The app opens on the tab you left, and on that tab's
   note — not on the first tab's. That distinction is the bug worth watching:
   while OneNote is still listing, `activeKey()` stands in with the first
   section that exists, and answering the stand-in opens the wrong tab's note.
   The other half: with a fresh state file, or with only one tab, there is no
   intent to wait for, so the tab on screen is the tab and opens on its note
   — and clicking the tab already on screen commits it as the open tab.
3. Flip `notebookTabs` for OneNote and open its tab. A tab per notebook opens
   each notebook's own page; the one tree tab opens the page of the notebook
   last read in, and unfolds that notebook to show it. Neither shape loses the
   answer when the setting is flipped back — that is the whole reason OneNote
   implements `defaultNote` rather than living on the host's memory.
4. Delete the note a tab opens with, then open that tab: it opens empty rather
   than reporting a note it cannot load.
5. A state file from before this (`version` 3, no `lastNotes`) opens every tab
   empty until each has been used once — there is no first-open guess any more.

### The manual checklist for the list not flickering

`revision` counts `rebuildRows` calls; `rowWrites` counts the times the list
was actually handed a new model, which is the expensive one — every write of
it destroys and rebuilds every delegate. They must not track each other.

1. Open the app on a note inside an expanded tree, `$C dismiss ""`, then
   `$C open "{}"`. `revision` climbs by about six, `rowWrites` by **zero**.
   Six there is the flicker back.
2. Switch tabs, expand a tree, let a note appear or vanish on disk: one new
   model each, and the rows change with it.
3. Leave it alone for a poll or two: no new models at all.

### The manual checklist for the save state

The note counts as unsaved from the keystroke until a provider says otherwise,
and the converter runs inside that span — so the states worth watching are
`dirty` and `saving` together, and the writes that do or do not follow. On a
scratch local note, with the window open:

```bash
C="omarchy-shell shell call io.github.andreivinca.note-note"
inotifywait -m -e close_write,moved_to --format '%e %f' ~/Notes   # writes are a rename
```

1. `$C onEdited ""` marks it: `dirty=true saving=false`. After the provider's
   own pause (`noteEdited` → its `Timer` → `saveRequested`; the host's 1500 ms
   default only for a provider that implements neither),
   `dirty=false saving=true` for one unbroken span — never both false while a
   save is under way — then both false, and **one** `MOVED_TO` for the note.
2. Move `services/markdown/qthtml/__main__.py` aside and repeat. `saving` goes
   true, the converter fails, and the note is **not written at all**: `dirty`
   comes back true and the bar says it could not be read for saving. Put the
   script back and the next flush carries the note. This is the case that used
   to write an empty note over a full one, so it is the one worth rerunning.
3. With the script still aside, open a note: it is held read-only saying it
   could not be displayed, rather than opening blank and editable — an
   editable blank is what autosave would write back.
4. Time the pause to check whose it is: `$C onEdited ""`, then poll
   `debugState` until `saving` turns true. It is the interval on that
   provider's own `Timer` — 500 ms for a local note, 1500 for the three that
   pay a request per write. Comment the `Timer` and its `noteEdited` out and
   the same note takes the host's default instead, which is the only number
   left in the host.
5. Delete the open note while a save is converting: nothing is written back to
   it (`cancelPendingSave` moves the epoch the conversion checks). A save
   already handed to the provider still finishes; that one is past recall.
6. On a OneNote note, edit and sign out of the account before the save is
   sent (the lane parked on a 429 is the easy way to see it): the bar says the
   save was cancelled, and `debugState` shows nothing still `saving`. The same
   when the provider is turned off in Settings with a save queued; with edits
   still unflushed the bar says they were dropped.
7. Move `python3` off the shell's PATH and `$C onEdited ""`: `saving` goes true
   and comes back false, the bar says the note could not be read for saving,
   and `dirty` is true again — the converter never started, and that is still
   an answer.

## Checklist for a UI change

1. `qmllint` clean, `py_compile` clean, `ruff` silent, `qthtml/selftest.py`
   green — and, if anything touched requests, `ratelimit_selftest.py` and
   `services/requests/selftest.py` too; if it touched a provider script, the
   three suites under "Testing the provider scripts".
2. Restart the shell; log clean.
3. Screenshot the window (`grim -o <output>` then crop with `magick`) and
   actually look at it.
4. Exercise the change through `shell call`, and check the *saved file* or the
   *backend*, not just the screen.
5. If it touches the editor: run the round-trip test again — the editor is
   the part that silently rewrites text.
