import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ui"

// Note Note — notes for the Omarchy shell, laid out like Toolroll: a header
// with search and key hints, a sidebar of notes, and the note itself on the
// right, always editable. Summoned as an overlay, or detached into an
// ordinary window.
//
// Notebooks are folders under ~/Notes (override with $NOTE_NOTE_DIR); notes
// are Markdown files inside them, with an optional title kept in a tiny
// front-matter block:
//
//   ---
//   title: Shopping
//   ---
//   body…
//
// An empty title shows the first words of the body in the list instead.
// Each notebook keeps its note order in its own .order file; the notebook
// order lives in ~/Notes/.notebooks. Notes sitting directly in ~/Notes show
// up as a "Notes" notebook.
//
// A virtual "Microsoft Sticky Notes" notebook sits last. Sticky Notes sync
// into the Outlook mailbox, which lib/msgraph.py reads and writes through
// Microsoft Graph; nothing is mirrored to disk beyond a small cache.
Item {
  id: root

  // Injected by the shell's panel loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  // false: summoned layer-shell overlay. true: an ordinary window Hyprland
  // manages like any other, for keeping open beside your work.
  property bool detached: false
  property bool deleteConfirmOpen: false
  property string filterText: ""
  property string statusText: ""

  readonly property string notesDir: Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes")
  readonly property string notebooksPath: root.notesDir + "/.notebooks"

  // ── Microsoft Sticky Notes ──────────────────────────────────────────
  readonly property string msKey: "ms:"
  readonly property string msName: "Microsoft Sticky Notes"
  readonly property string msScript: Qt.resolvedUrl("lib/msgraph.py").toString().replace(/^file:\/\//, "")
  readonly property string msConfigPath: Quickshell.env("HOME") + "/.config/omarchy/note-note.json"
  readonly property string msPayloadPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-note-note-ms-payload.json"
  property bool msConfigured: false
  property bool msSignedIn: false
  property string msAccount: ""
  property bool msLoggingIn: false
  property bool msRefreshing: false
  // [{ id, title, body, modified }] as last fetched (or cached).
  property var msNotes: []
  function isMs(path) { return path.indexOf(root.msKey) === 0 }

  // OneNote: every section is a notebook keyed "on:<sectionId>"; pages are
  // "onp:<pageId>". Page bodies are fetched on demand and kept for the session.
  readonly property string onKey: "on:"
  readonly property string onPageKey: "onp:"
  property bool msOneNote: false
  property var onSections: []
  property var onPages: []
  property var onBodies: ({})
  // Expanded OneNote notebooks/sections (ids), remembered in the state file.
  property var onExpanded: []
  readonly property string onSecKey: "ons:"
  function onToggle(id) {
    var i = root.onExpanded.indexOf(id), next = root.onExpanded.slice()
    if (i >= 0) next.splice(i, 1); else next.push(id)
    root.onExpanded = next
    rebuildModel()
    saveState()
  }
  function onSection(id) {
    for (var i = 0; i < root.onSections.length; i++) if (root.onSections[i].id === id) return root.onSections[i]
    return null
  }
  function isOnSection(key) { return key.indexOf(root.onKey) === 0 }
  function isOnPage(path) { return path.indexOf(root.onPageKey) === 0 }
  function onPageId(path) { return path.substring(root.onPageKey.length) }
  function onSectionId(key) { return key.substring(root.onKey.length) }
  function onSectionName(id) {
    var sct = onSection(id)
    return sct ? "OneNote › " + (sct.notebook ? sct.notebook + " › " : "") + sct.name : "OneNote"
  }
  function onPage(path) {
    var id = onPageId(path)
    for (var i = 0; i < root.onPages.length; i++) if (root.onPages[i].id === id) return root.onPages[i]
    return null
  }
  // Fetched remotely (not from disk): Sticky Notes and OneNote alike.
  function isRemote(path) { return isMs(path) || isOnPage(path) }
  // Reachable over IPC (omarchy-shell shell call <id> scrollList 400).
  function scrollList(y) { list.setScrollOffset(Number(y)); return list.scrollOffset() }
  function listOffset() { return list.scrollOffset() }
  function listDebug() { return list.debugInfo() }
  // What the editor's description line calls the place a note lives.
  function crumbOf(path) {
    if (!path) return ""
    if (isOnPage(path)) { var pg = onPage(path); return pg ? onSectionName(pg.sectionId) : "OneNote" }
    return notebookName(notebookOf(path))
  }
  function msId(path) { return path.substring(root.msKey.length) }
  function msNote(path) {
    var id = msId(path)
    for (var i = 0; i < root.msNotes.length; i++) if (root.msNotes[i].id === id) return root.msNotes[i]
    return null
  }
  // Local notebooks are open unless folded; the remote ones (Sticky Notes,
  // OneNote) are folded unless the user opened them.
  property var collapsed: []
  property var openedRemote: []
  function isRemoteKey(key) { return key === root.msKey || key === root.onKey }
  function isFolded(key) {
    return isRemoteKey(key) ? root.openedRemote.indexOf(key) < 0 : root.collapsed.indexOf(key) >= 0
  }
  // Every folded key, for the sidebar's chevrons.
  function foldedKeys() {
    return root.notebooks.map(function(b) { return b.key }).filter(isFolded)
  }
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/note-note.json"

  // Current note. `currentPath` drives the FileView; `loadingNote` guards
  // against editor change signals firing a save while we swap files.
  property string currentPath: ""
  property bool loadingNote: false
  property bool dirty: false

  // Shares the [menu] surface tokens, so a theme that styles the launcher
  // styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText

  // ── shell contract ──────────────────────────────────────────────────
  function open(payloadJson) {
    root.opened = true
    root.deleteConfirmOpen = false
    editor.clearNotice()
    listProc.running = true
    msStatusProc.running = true
    Qt.callLater(function() { editor.focusEditor() })
  }

  function close() {
    root.flushSave()
    root.opened = false
  }

  function dismiss() {
    root.flushSave()
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.andreivinca.note-note")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function setDetached(value) {
    var next = value === true || value === "true"
    if (next === root.detached) return
    root.detached = next
    saveState()
    root.statusText = next
      ? "Detached — an ordinary window now, so move, resize and tile it as usual"
      : "Back to the summoned overlay"
    statusTimer.restart()
  }

  function goBack() {
    if (searchField.activeFocus) {
      if (root.filterText.length > 0) { searchField.text = ""; setFilter("") }
      else if (!root.detached) root.dismiss()
      return
    }
    if (root.detached) searchField.forceActiveFocus()
    else root.dismiss()
  }

  Timer { id: statusTimer; interval: 3500; onTriggered: root.statusText = "" }

  // ── note file format ────────────────────────────────────────────────
  function parseNote(raw) {
    var m = /^---\n(?:title:[ \t]?(.*))?\n?---\n?/.exec(raw)
    if (!m) return { title: "", body: raw }
    return { title: (m[1] || "").trim(), body: raw.substring(m[0].length) }
  }

  function serializeNote(title, body) {
    return "---\ntitle: " + title.replace(/[\r\n]+/g, " ").trim() + "\n---\n" + body
  }

  function previewOf(body) {
    var lines = body.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].replace(/^[#>\-\*\s]+/, "").replace(/[*_`]/g, "").trim()
      if (l) return l
    }
    return ""
  }

  function displayTitle(title, preview) {
    if (title) return title
    if (!preview) return "Untitled"
    var words = preview.split(/\s+/).slice(0, 5).join(" ")
    return words.length < preview.length ? words + "…" : words
  }

  function baseName(path) { return path.substring(path.lastIndexOf("/") + 1) }

  // ── notes: `notebooks` + `notes` are the truth, `rows` is the view ────────
  // notebooks: [{ key, name, dir }] in display order. key "" is ~/Notes itself.
  // notes:     [{ path, notebook, title, preview }] grouped by notebook, in order.
  property var notebooks: []
  property var notes: []
  // Bumped whenever notebooks/notes change, so bindings that go through the
  // helper functions below (counts, names) re-evaluate.
  property int revision: 0
  // The list's model: a plain array replaced wholesale (as Toolroll does) —
  // a ListModel cleared and refilled would drop the scroll position.
  property var rows: []
  function setRow(i, patch) {
    var rr = root.rows.slice(), r = Object.assign({}, rr[i]), k
    for (k in patch) r[k] = patch[k]
    rr[i] = r
    root.rows = rr
  }

  function notebookDir(key) { return key ? root.notesDir + "/" + key : root.notesDir }
  function notebookName(key) {
    if (key === root.msKey) return root.msName
    if (key === root.onKey) return "OneNote"
    if (isOnSection(key)) return onSectionName(onSectionId(key))
    for (var i = 0; i < root.notebooks.length; i++) if (root.notebooks[i].key === key) return root.notebooks[i].name
    return key || "Notes"
  }
  function notebookCount(key) {
    var n = 0
    for (var i = 0; i < root.notes.length; i++) if (root.notes[i].notebook === key) n++
    return n
  }
  function notebookOf(path) {
    var i = noteIndexOf(path)
    return i >= 0 ? root.notes[i].notebook : ""
  }

  function matches(n) {
    if (!root.filterText) return true
    var q = root.filterText.toLowerCase()
    return n.title.toLowerCase().indexOf(q) >= 0 || n.preview.toLowerCase().indexOf(q) >= 0
  }

  // The section string carries everything the heading shows — key, name and
  // count — so a change produces a fresh heading instead of relying on a
  // binding inside the section delegate to notice. The root notebook's key
  // is written as "/" (never a valid folder name): ListView draws no heading
  // for an empty section string.
  function groupOf(key) {
    return (key === "" ? "/" : key) + "\u001f" + notebookName(key) + "\u001f" + notebookCount(key)
  }

  // Every row carries every role: a ListModel fixes its roles on first insert.
  function row(r) {
    return { kind: r.kind || "note", notebook: r.notebook || "", group: groupOf(r.notebook || ""),
             path: r.path || "", title: r.title || "", preview: r.preview || "",
             icon: r.icon || "", fixed: r.fixed === true, level: r.level || 0, expanded: r.expanded === true }
  }
  function rowFor(n) { return row({ kind: "note", notebook: n.notebook, path: n.path, title: n.title, preview: n.preview, fixed: n.notebook === root.msKey || isOnSection(n.notebook) }) }

  property string currentNotebookName: ""

  function rebuildModel() {
    root.revision++
    root.currentNotebookName = crumbOf(root.currentPath)
    var out = []
    for (var b = 0; b < root.notebooks.length; b++) {
      var key = root.notebooks[b].key
      var folded = !root.filterText && isFolded(key)
      if (key === root.onKey && !folded && !root.filterText && root.msSignedIn && root.msOneNote) {
        appendOneNoteTree(out)
        continue
      }
      var any = false
      for (var i = 0; i < root.notes.length; i++) {
        var n = root.notes[i]
        if (n.notebook !== key || !matches(n)) continue
        any = true
        if (!folded) out.push(rowFor(n))
      }
      if (root.filterText) continue                       // searching: no chrome rows
      if (folded) { out.push(row({ kind: "placeholder", notebook: key })); continue }
      if (key === root.msKey || key === root.onKey) {
        if (!root.msConfigured) out.push(row({ kind: "action", notebook: key, path: "ms-setup", title: "Not available in this build", icon: "󰒓" }))
        else if (!root.msSignedIn) out.push(row({ kind: "action", notebook: key, path: "ms-login", title: root.msLoggingIn ? "Signing in…" : "Sign in to Microsoft…", icon: "󰊻" }))
        else if (key === root.onKey) out.push(row({ kind: "action", notebook: key, path: "on-relogin", title: root.msLoggingIn ? "Signing in…" : "Sign in again to enable OneNote…", icon: "󰊻" }))
        else {
          out.push(row({ kind: "new", notebook: key }))
          out.push(row({ kind: "action", notebook: key, path: "ms-logout", title: "Sign out" + (root.msAccount ? " (" + root.msAccount + ")" : ""), icon: "󰍃" }))
        }
      } else out.push(row({ kind: "new", notebook: key }))
    }
    // Swapping the array resets the view to the top; put it back once the
    // new delegates are laid out.
    var keep = list.scrollOffset()
    root.rows = out
    if (keep > 0) Qt.callLater(function() { list.setScrollOffset(keep) })
  }

  // OneNote: notebooks → sections → pages, expandable in place.
  function appendOneNoteTree(out) {
    var books = [], seen = {}
    for (var i = 0; i < root.onSections.length; i++) {
      var sct = root.onSections[i]
      if (!seen[sct.notebookId]) { seen[sct.notebookId] = true; books.push({ id: sct.notebookId, name: sct.notebook || "Notebook" }) }
    }
    books.sort(function(a, b) { return a.name.localeCompare(b.name) })
    for (var b = 0; b < books.length; b++) {
      var bookOpen = root.onExpanded.indexOf(books[b].id) >= 0
      out.push(row({ kind: "tree", notebook: root.onKey, path: books[b].id, title: books[b].name, level: 0, expanded: bookOpen }))
      if (!bookOpen) continue
      for (var s2 = 0; s2 < root.onSections.length; s2++) {
        var sec = root.onSections[s2]
        if (sec.notebookId !== books[b].id) continue
        var secOpen = root.onExpanded.indexOf(sec.id) >= 0
        out.push(row({ kind: "tree", notebook: root.onKey, path: sec.id, title: sec.name, level: 1, expanded: secOpen }))
        if (!secOpen) continue
        for (var p = 0; p < root.onPages.length; p++) {
          var pg = root.onPages[p]
          if (pg.sectionId !== sec.id) continue
          out.push(row({ kind: "note", notebook: root.onKey, path: root.onPageKey + pg.id, title: pg.title, level: 2, fixed: true }))
        }
        out.push(row({ kind: "new", notebook: root.onKey, path: root.onSecKey + sec.id, level: 2 }))
      }
    }
    if (books.length === 0) out.push(row({ kind: "action", notebook: root.onKey, path: "on-refresh", title: "No notebooks found — refresh", icon: "󰑐" }))
  }

  function setFilter(text) {
    root.filterText = text
    rebuildModel()
    if (root.rows.length > 0 && modelIndexOf(root.currentPath) < 0)
      selectPath(root.rows[0].path)
  }

  function toggleSection(key) {
    if (isRemoteKey(key)) {
      var j = root.openedRemote.indexOf(key), nextOpen = root.openedRemote.slice()
      if (j >= 0) nextOpen.splice(j, 1); else nextOpen.push(key)
      root.openedRemote = nextOpen
    } else {
      var i = root.collapsed.indexOf(key), next = root.collapsed.slice()
      if (i >= 0) next.splice(i, 1); else next.push(key)
      root.collapsed = next
    }
    rebuildModel()
    saveState()
  }

  function noteIndexOf(path) {
    for (var i = 0; i < root.notes.length; i++) if (root.notes[i].path === path) return i
    return -1
  }

  function modelIndexOf(path) {
    if (!path) return -1
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].path === path) return i
    return -1
  }

  // Saved order first, then anything unlisted in the given (birth-time)
  // order — so new things still land at the end.
  function applyOrder(entries, keyOf, savedNames) {
    var rank = {}
    for (var i = 0; i < savedNames.length; i++) if (savedNames[i]) rank[savedNames[i]] = i
    return entries.map(function(e, i) { return { e: e, i: i } })
      .sort(function(a, b) {
        var ra = rank[keyOf(a.e)], rb = rank[keyOf(b.e)]
        var ha = ra !== undefined, hb = rb !== undefined
        if (ha && hb) return ra - rb
        if (ha) return -1
        if (hb) return 1
        return a.i - b.i
      })
      .map(function(x) { return x.e })
  }

  // One FileView serves every order file: point it at a path, then write.
  function writeFile(path, text) {
    orderFile.path = path
    orderFile.setText(text)
  }

  function saveOrder(key) {
    if (key === root.msKey || isOnSection(key) || key === root.onKey) return
    var names = root.notes.filter(function(n) { return n.notebook === key })
      .map(function(n) { return baseName(n.path) })
    writeFile(notebookDir(key) + "/.order", names.join("\n") + "\n")
  }

  function saveNotebookOrder() {
    writeFile(root.notebooksPath,
      root.notebooks.filter(function(b) { return b.key && b.key !== root.msKey && b.key !== root.onKey && !isOnSection(b.key) }).map(function(b) { return b.key }).join("\n") + "\n")
  }

  function moveNote(fromPath, toPath) {
    if (root.filterText) return
    var from = noteIndexOf(fromPath), to = noteIndexOf(toPath)
    if (from < 0 || to < 0 || from === to) return
    if (root.notes[from].notebook !== root.notes[to].notebook) return
    var arr = root.notes.slice()
    var item = arr.splice(from, 1)[0]
    arr.splice(to, 0, item)
    root.notes = arr
    var mf = modelIndexOf(fromPath), mt = modelIndexOf(toPath)
    if (mf >= 0 && mt >= 0) { var rr = root.rows.slice(); var it = rr.splice(mf, 1)[0]; rr.splice(mt, 0, it); root.rows = rr }
  }

  // Parses the listing script's output:
  //   D<TAB>key                       a notebook folder ("" = ~/Notes itself)
  //   O<TAB>key<TAB>name              one line of that notebook's .order
  //   B<TAB>key                       one line of .notebooks
  //   N<TAB>key<TAB>path<TAB>title<TAB>preview
  function loadList(raw) {
    var lines = raw.split("\n")
    var dirs = [], orders = {}, bookOrder = [], entries = []
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p[0] === "D") dirs.push(p[1] || "")
      else if (p[0] === "O") { (orders[p[1] || ""] = orders[p[1] || ""] || []).push(p[2]) }
      else if (p[0] === "B") bookOrder.push(p[1])
      else if (p[0] === "N") entries.push({ notebook: p[1] || "", path: p[2], title: p[3] || "", preview: p[4] || "" })
    }
    // ~/Notes itself is a notebook only while it has notes of its own.
    var books = dirs.filter(function(k) {
      return k !== "" || entries.some(function(e) { return e.notebook === "" })
    }).map(function(k) { return { key: k, name: k || "Notes", dir: notebookDir(k) } })
    books = applyOrder(books, function(b) { return b.key }, bookOrder)
    // Root first when present. (Not Array.sort: QJS's sort is not stable.)
    root.notebooks = books.filter(function(b) { return b.key === "" })
      .concat(books.filter(function(b) { return b.key !== "" }))
      .concat([{ key: root.msKey, name: root.msName, dir: "" }])
      .concat(onNotebooks())

    var ordered = []
    for (var b = 0; b < books.length; b++) {
      var key = books[b].key
      var mine = entries.filter(function(e) { return e.notebook === key })
      ordered = ordered.concat(applyOrder(mine, function(e) { return baseName(e.path) }, orders[key] || []))
    }
    root.notes = ordered.concat(msEntries()).concat(onEntries())
    rebuildModel()

    var idx = modelIndexOf(root.currentPath)
    if (idx < 0) {
      var last = ""
      for (var j = root.rows.length - 1; j >= 0; j--)
        if (root.rows[j].kind === "note") { last = root.rows[j].path; break }
      root.selectPath(last)
    } else Qt.callLater(function() { list.positionViewAtIndex(idx, ListView.Contain) })
  }

  function selectPath(path) {
    if (path === root.currentPath) return
    if (path && isMs(path) && !msNote(path)) return
    if (path && isOnPage(path) && !onPage(path)) return
    root.flushSave()
    editor.clearNotice()
    root.loadingNote = true
    root.currentPath = path
    root.currentNotebookName = crumbOf(path)
    if (!path) {
      editor.setNote("", "")
      root.loadingNote = false
      return
    }
    if (isMs(path)) {
      var n = msNote(path)
      editor.setNote(n ? n.title : "", n ? n.body : "")
      root.loadingNote = false
      root.dirty = false
      return
    }
    if (isOnPage(path)) {
      var pg = onPage(path), cached = root.onBodies[onPageId(path)]
      if (cached) {
        editor.setNote(cached.title, cached.body)
        editor.readOnly = !cached.editable
        root.loadingNote = false
        root.dirty = false
      } else {
        editor.setNote(pg ? pg.title : "", "")
        editor.readOnly = true
        root.onLoadingPath = path
        onPageProc.command = ["python3", root.msScript, "onenote-page", onPageId(path)]
        onPageProc.running = true
      }
      return
    }
    editor.readOnly = false
    noteFile.reload()
  }

  function moveSelection(delta) {
    var idx = [], cur = -1
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].kind !== "note") continue
      if (root.rows[i].path === root.currentPath) cur = idx.length
      idx.push(i)
    }
    if (idx.length === 0) return
    var next = (cur + delta + idx.length) % idx.length
    if (cur < 0) next = delta < 0 ? idx.length - 1 : 0
    selectPath(root.rows[idx[next]].path)
    list.positionViewAtIndex(idx[next], ListView.Contain)
  }

  // New notes go at the end of their notebook. The filename is an opaque
  // id; the title lives in the file and starts out empty.
  function newNote(key) {
    root.flushSave()
    if (root.filterText) { searchField.text = ""; setFilter("") }
    if (key === undefined) key = root.currentPath ? notebookOf(root.currentPath)
      : (root.notebooks.length > 0 ? root.notebooks[root.notebooks.length - 1].key : null)
    if (key === null) { list.startNewNotebook(); return }
    if (key === root.onKey && root.currentPath && isOnPage(root.currentPath)) {
      var cur = onPage(root.currentPath)
      key = cur ? root.onSecKey + cur.sectionId : key
    }
    if (key.indexOf(root.onSecKey) === 0) {
      if (!root.msOneNote || onCreateProc.running) return
      var secId = key.substring(root.onSecKey.length)
      root.statusText = "Creating a OneNote page…"
      msPayloadFile.setText(JSON.stringify({ title: "", body: "" }))
      onCreateProc.command = ["python3", root.msScript, "onenote-create", secId, root.msPayloadPath]
      onCreateProc.running = true
      return
    }
    if (key === root.onKey) return
    if (key === root.msKey) {
      if (!root.msSignedIn || msCreateProc.running) return
      root.statusText = "Creating a sticky note…"
      msCreateProc.running = true
      return
    }
    var path = notebookDir(key) + "/note-" + Date.now() + ".md"
    root.loadingNote = true
    root.currentPath = path
    editor.setNote("", "")
    root.loadingNote = false
    root.dirty = false
    noteFile.setText(serializeNote("", ""))
    // Insert after the notebook's last note so it stays grouped.
    var arr = root.notes.slice(), at = arr.length
    for (var i = arr.length - 1; i >= 0; i--) if (arr[i].notebook === key) { at = i + 1; break }
    if (at === arr.length && !arr.some(function(n) { return n.notebook === key })) {
      // Empty notebook: place it where its notebook sits in display order.
      var after = root.notebooks.map(function(b) { return b.key }).indexOf(key)
      at = 0
      for (var j = 0; j < arr.length; j++)
        if (root.notebooks.map(function(b) { return b.key }).indexOf(arr[j].notebook) <= after) at = j + 1
    }
    var entry = { path: path, notebook: key, title: "", preview: "" }
    arr.splice(at, 0, entry)
    root.notes = arr
    if (isFolded(key)) { toggleSection(key) }
    rebuildModel()
    saveOrder(key)
    var mi = modelIndexOf(path)
    Qt.callLater(function() { if (mi >= 0) list.positionViewAtIndex(mi, ListView.Contain) })
    editor.focusTitle()
  }

  function newNotebook(name) {
    var key = name.replace(/[\/\\]/g, "-").trim()
    if (!key || key[0] === ".") return
    mkdirProc.command = ["mkdir", "-p", "--", notebookDir(key)]
    mkdirProc.running = true
    root.pendingNotebook = key
  }
  property string pendingNotebook: ""
  property bool msReloginPending: false
  property string onLoadingPath: ""

  // ── delete ──────────────────────────────────────────────────────────
  property string deletePath: ""

  function requestDelete(path) {
    var target = path || root.currentPath
    if (!target) return
    root.deletePath = target
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    editor.focusEditor()
  }

  function confirmDelete() {
    root.deleteConfirmOpen = false
    var path = root.deletePath
    root.deletePath = ""
    var ni = noteIndexOf(path), mi = modelIndexOf(path)
    if (!path || ni < 0) return
    var wasCurrent = path === root.currentPath
    if (wasCurrent) { saveTimer.stop(); root.dirty = false }
    else root.flushSave()
    var key = root.notes[ni].notebook
    root.notes = root.notes.filter(function(n) { return n.path !== path })
    if (mi >= 0) { var rr = root.rows.slice(); rr.splice(mi, 1); root.rows = rr }
    saveOrder(key)
    if (isMs(path)) {
      root.msNotes = root.msNotes.filter(function(n) { return n.id !== msId(path) })
      msDeleteProc.command = ["python3", root.msScript, "delete", msId(path)]
      msDeleteProc.running = true
    } else if (isOnPage(path)) {
      root.onPages = root.onPages.filter(function(p) { return p.id !== onPageId(path) })
      msDeleteProc.command = ["python3", root.msScript, "onenote-delete", onPageId(path)]
      msDeleteProc.running = true
    } else {
      rmProc.command = ["rm", "-f", "--", path]
      rmProc.running = true
    }
    if (!wasCurrent) return
    var next = ""
    for (var k = Math.max(mi, 0); k >= 0 && k < root.rows.length; k--)
      if (root.rows[k].kind === "note") { next = root.rows[k].path; break }
    if (!next) for (var j = 0; j < root.rows.length; j++)
      if (root.rows[j].kind === "note") { next = root.rows[j].path; break }
    root.currentPath = ""
    selectPath(next)
    editor.focusEditor()
  }

  // ── keys ────────────────────────────────────────────────────────────
  function handleShortcut(event) {
    if (root.deleteConfirmOpen) return deleteConfirm.handleKey(event)
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { root.goBack(); return true }
    if (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_L)) {
      searchField.forceActiveFocus(); searchField.selectAll(); return true
    }
    if (ctrl && event.key === Qt.Key_N) {
      if (event.modifiers & Qt.ShiftModifier) list.startNewNotebook(); else root.newNote()
      return true
    }
    if (ctrl && event.key === Qt.Key_D) { root.requestDelete(root.currentPath); return true }
    if (ctrl && (event.key === Qt.Key_Down || event.key === Qt.Key_J)) { root.moveSelection(1); return true }
    if (ctrl && event.key === Qt.Key_Up) { root.moveSelection(-1); return true }
    if (ctrl && editor.bodyFocused && !editor.plain && !editor.readOnly) {
      if (event.key === Qt.Key_B) { editor.toggleFormat("bold"); return true }
      if (event.key === Qt.Key_I) { editor.toggleFormat("italic"); return true }
      if (event.key === Qt.Key_U) { editor.toggleFormat("underline"); return true }
    }
    return false
  }

  // ── persistence ─────────────────────────────────────────────────────
  function onEdited() {
    if (root.loadingNote || !root.currentPath) return
    root.dirty = true
    saveTimer.restart()
  }

  function flushSave() {
    if (!root.dirty || !root.currentPath) return
    saveTimer.stop()
    var title = editor.title, body = editor.text
    if (isOnPage(root.currentPath)) {
      if (editor.readOnly) { root.dirty = false; return }
      body = editor.text   // Markdown, converted to OneNote HTML by the bridge
      var id = onPageId(root.currentPath)
      var bodies = root.onBodies; bodies[id] = { title: title, body: body, editable: true }; root.onBodies = bodies
      var pgs = root.onPages.slice()
      for (var q = 0; q < pgs.length; q++) if (pgs[q].id === id) pgs[q] = { id: id, sectionId: pgs[q].sectionId, title: title, modified: pgs[q].modified }
      root.onPages = pgs
      msPayloadFile.setText(JSON.stringify({ title: title, body: body }))
      msSaveProc.command = ["python3", root.msScript, "onenote-update", id, root.msPayloadPath]
      msSaveProc.running = true
      var ni2 = noteIndexOf(root.currentPath), mi2 = modelIndexOf(root.currentPath)
      if (ni2 >= 0) { var arr2 = root.notes.slice(); arr2[ni2] = { path: root.currentPath, notebook: arr2[ni2].notebook, title: title.trim(), preview: "" }; root.notes = arr2 }
      if (mi2 >= 0) setRow(mi2, { title: title.trim() })
      root.revision++
      root.dirty = false
      return
    }
    if (isMs(root.currentPath)) {
      body = editor.plainText()
      var n = msNote(root.currentPath)
      if (n) { n.title = title; n.body = body }
      msPayloadFile.setText(JSON.stringify({ title: title, body: body }))
      msSaveProc.command = ["python3", root.msScript, "update", msId(root.currentPath), root.msPayloadPath]
      msSaveProc.running = true
    } else noteFile.setText(serializeNote(title, body))
    var ni = noteIndexOf(root.currentPath)
    if (ni >= 0) {
      var arr = root.notes.slice()
      arr[ni] = { path: root.currentPath, title: title.trim(), preview: previewOf(body) }
      root.notes = arr
    }
    var mi = modelIndexOf(root.currentPath)
    if (mi >= 0) {
      setRow(mi, { title: title.trim(), preview: previewOf(body) })
    }
    root.revision++
    root.dirty = false
  }

  Timer { id: saveTimer; interval: 500; onTriggered: root.flushSave() }

  function saveState() {
    stateFile.setText(JSON.stringify({ version: 1, detached: root.detached, collapsed: root.collapsed, openedRemote: root.openedRemote, onExpanded: root.onExpanded }, null, 2) + "\n")
  }

  function loadState(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      if (parsed.detached === true) root.detached = true
      if (Array.isArray(parsed.collapsed)) root.collapsed = parsed.collapsed.filter(function(k) { return k !== "ms:" && k !== "on:" })
      if (Array.isArray(parsed.openedRemote)) root.openedRemote = parsed.openedRemote
      if (Array.isArray(parsed.onExpanded)) root.onExpanded = parsed.onExpanded
    } catch (e) { /* a corrupt state file costs nothing */ }
  }

  FileView {
    id: noteFile
    path: root.currentPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root.loadingNote) {
        var n = root.parseNote(text())
        editor.setNote(n.title, n.body)
        root.loadingNote = false
        root.dirty = false
      }
    }
    onLoadFailed: {
      if (root.loadingNote) {
        editor.setNote("", "")
        root.loadingNote = false
        root.dirty = false
      }
    }
  }

  FileView {
    id: orderFile
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
  }

  // Lists notebooks (folders) and their notes, oldest-first by birth time.
  // See loadList() for the line format.
  Process {
    id: listProc
    command: ["sh", "-c", '
      mkdir -p "$1" && cd "$1" || exit 0
      emit() {
        dir="$1"; key="$2"
        printf "D\\t%s\\n" "$key"
        [ -f "$dir/.order" ] && while IFS= read -r n; do [ -n "$n" ] && printf "O\\t%s\\t%s\\n" "$key" "$n"; done < "$dir/.order"
        for f in "$dir"/*.md; do
          [ -e "$f" ] || continue
          printf "%s\\t%s\\n" "$(stat -c %W -- "$f")" "$f"
        done | sort -n | cut -f2- | while IFS= read -r f; do
          awk -v key="$key" -v p="$f" \'
            NR==1 && $0=="---" { fm=1; next }
            fm && $0=="---"    { fm=0; next }
            fm && /^title:/    { t=substr($0,7); next }
            !fm && !pv && NF   { pv=$0; sub(/^[#>*\\- \\t]+/, "", pv); gsub(/[*_`]/, "", pv) }
            END { gsub(/\\t/," ",t); gsub(/\\t/," ",pv); sub(/^ +/,"",t); printf "N\\t%s\\t%s\\t%s\\t%s\\n", key, p, t, pv }
          \' "$f"
        done
      }
      [ -f .notebooks ] && while IFS= read -r n; do [ -n "$n" ] && printf "B\\t%s\\n" "$n"; done < .notebooks
      emit "$PWD" ""
      for d in */; do
        [ -d "$d" ] || continue
        d=${d%/}
        case "$d" in .*) continue;; esac
        emit "$PWD/$d" "$d"
      done
    ', "sh", root.notesDir]
    stdout: StdioCollector { onStreamFinished: root.loadList(this.text) }
  }

  Process { id: rmProc }

  Process {
    id: mkdirProc
    onExited: {
      var key = root.pendingNotebook
      root.pendingNotebook = ""
      if (!key) return
      if (!root.notebooks.some(function(b) { return b.key === key })) {
        root.notebooks = root.notebooks.concat([{ key: key, name: key, dir: root.notebookDir(key) }])
        root.saveNotebookOrder()
      }
      root.rebuildModel()
      root.newNote(key)
    }
  }


  // ── Microsoft Sticky Notes: entries, actions, processes ─────────────
  function msEntries() {
    return root.msNotes.map(function(n) {
      return { path: root.msKey + n.id, notebook: root.msKey, title: n.title, preview: previewOf(n.body) }
    })
  }

  // Replace the virtual notebook's entries in `notes` and redraw.
  function onNotebooks() { return [{ key: root.onKey, name: "OneNote", dir: "" }] }

  function onEntries() {
    return root.onPages.map(function(pg) {
      return { path: root.onPageKey + pg.id, notebook: root.onKey, title: pg.title, preview: "" }
    })
  }

  function msApply() {
    root.notebooks = root.notebooks.filter(function(b) { return b.key !== root.onKey && !isOnSection(b.key) }).concat(onNotebooks())
    root.notes = root.notes.filter(function(n) { return n.notebook !== root.msKey && !isOnSection(n.notebook) })
      .concat(msEntries()).concat(onEntries())
    rebuildModel()
    if (root.currentPath && isMs(root.currentPath) && !msNote(root.currentPath)) selectPath("")
    if (root.currentPath && isOnPage(root.currentPath) && !onPage(root.currentPath)) selectPath("")
  }

  function msAction(id) {
    if (id === "ms-setup") {
      // Only reachable while the plugin ships without its own client ID —
      // a message for whoever is building it, not for users.
      editor.showNotice("Microsoft Sticky Notes is not configured in this build",
        "This copy of Note Note has no Microsoft app registration built in, so nobody can sign in yet.\n\n"
        + "Plugin author: register the app once (Microsoft Entra → App registrations: personal + work "
        + "accounts, no redirect URI, public client flows enabled, delegated Mail.ReadWrite, User.Read, "
        + "offline_access) and put its Application (client) ID in CLIENT_ID at the top of lib/msgraph.py.\n\n"
        + "Anyone can also point their own registration at it via " + root.msConfigPath + ".", "",
        [{ label: "Check again", icon: "󰑐", action: function() { msStatusProc.running = true } }])
      return
    }
    if (id === "ms-login") {
      if (root.msLoggingIn) return
      root.msLoggingIn = true
      rebuildModel()
      editor.showNotice("Sign in to Microsoft", "Requesting a sign-in code…", "", [])
      msLoginProc.running = true
      return
    }
    if (id === "ms-logout") {
      msLogoutProc.running = true
      return
    }
    if (id === "on-refresh") { onListProc.cached = false; onListProc.running = true; return }
    if (id === "on-relogin") {
      // The stored token predates the OneNote scope: a fresh consent is needed.
      root.msReloginPending = true
      msLogoutProc.running = true
      return
    }
  }

  function msLoginLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.userCode) {
      var uri = msg.verificationUri, code = msg.userCode
      editor.showNotice("Sign in to Microsoft",
        "Open " + uri + " in a browser, enter this code, and sign in with the account that has your Sticky Notes. "
        + "This screen updates by itself once you are done.", code,
        [{ label: "Copy code", icon: "󰆏", action: function() { Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", code]) } },
         { label: "Open sign-in page", icon: "󰖟", action: function() { Quickshell.execDetached(["xdg-open", uri]) } }])
    } else if (msg.ok) {
      root.msSignedIn = true
      root.msAccount = msg.account || ""
      editor.showNotice("Signed in", "Fetching your notes…", "", [])
      msStatusProc.running = true
    } else if (msg.error) {
      editor.showNotice("Sign-in failed", msg.error, "",
        [{ label: "Try again", icon: "󰑐", action: function() { msAction("ms-login") } }])
    }
  }

  Process {
    id: msStatusProc
    command: ["python3", root.msScript, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var st = JSON.parse(this.text)
          root.msConfigured = st.configured === true
          root.msSignedIn = st.signedIn === true
          root.msAccount = st.account || ""
          root.msOneNote = st.onenote === true
        } catch (e) { root.msConfigured = false; root.msSignedIn = false; root.msOneNote = false }
        if (root.msSignedIn) { msListProc.cached = true; msListProc.running = true }
        else { root.msNotes = [] }
        if (root.msSignedIn && root.msOneNote) { onListProc.cached = true; onListProc.running = true }
        else { root.onSections = []; root.onPages = [] }
        msApply()
      }
    }
  }

  Process {
    id: msListProc
    property bool cached: true
    command: ["python3", root.msScript, "list"].concat(cached ? ["--cached"] : [])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          if (res.error) {
            if (!msListProc.cached) {
              root.statusText = "Sticky Notes: " + res.error
              statusTimer.restart()
              if (/not signed in|expired/.test(res.error)) { root.msSignedIn = false; root.msNotes = [] }
            }
          } else if (Array.isArray(res.notes)) root.msNotes = res.notes
        } catch (e) {}
        msApply()
        if (editor.showingNotice && editor.noticeTitle === "Signed in") {
          editor.clearNotice()
          if (root.msNotes.length > 0) selectPath(root.msKey + root.msNotes[0].id)
        }
      }
    }
    // A cached list is shown at once; the live one follows.
    onExited: if (cached && root.msSignedIn) Qt.callLater(function() { msListProc.cached = false; msListProc.running = true })
  }

  Process {
    id: msLoginProc
    command: ["python3", root.msScript, "login"]
    stdout: SplitParser { onRead: function(line) { root.msLoginLine(line) } }
    onExited: { root.msLoggingIn = false; rebuildModel() }
  }

  Process {
    id: msLogoutProc
    command: ["python3", root.msScript, "logout"]
    onExited: {
      root.msSignedIn = false; root.msAccount = ""; root.msNotes = []
      root.msOneNote = false; root.onSections = []; root.onPages = []; root.onBodies = ({})
      if (root.currentPath && root.isRemote(root.currentPath)) root.selectPath("")
      msApply()
      if (root.msReloginPending) { root.msReloginPending = false; root.msAction("ms-login") }
    }
  }

  Process {
    id: msSaveProc
    stdout: StdioCollector {
      onStreamFinished: {
        try { var r = JSON.parse(this.text); if (r.error) { root.statusText = "Sticky Notes: " + r.error; statusTimer.restart() } } catch (e) {}
      }
    }
  }

  Process {
    id: onListProc
    property bool cached: true
    command: ["python3", root.msScript, "onenote-list"].concat(cached ? ["--cached"] : [])
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          if (res.error) {
            if (!onListProc.cached) { root.statusText = "OneNote: " + res.error; statusTimer.restart() }
          } else {
            if (Array.isArray(res.sections)) root.onSections = res.sections
            if (Array.isArray(res.pages)) root.onPages = res.pages
          }
        } catch (e) {}
        msApply()
      }
    }
    onExited: if (cached && root.msSignedIn && root.msOneNote) Qt.callLater(function() { onListProc.cached = false; onListProc.running = true })
  }

  Process {
    id: onPageProc
    stdout: StdioCollector {
      onStreamFinished: {
        var path = root.onLoadingPath
        root.onLoadingPath = ""
        var r
        try { r = JSON.parse(this.text) } catch (e) { r = { error: "unexpected reply" } }
        if (r.error) {
          if (root.currentPath === path) { root.loadingNote = false; root.statusText = "OneNote: " + r.error; statusTimer.restart() }
          return
        }
        var id = root.onPageId(path)
        // A page whose <title> is empty still has a list title (OneNote
        // derives it from the first line); show that one.
        var pg = root.onPage(path)
        var title = r.title || (pg ? pg.title : "")
        var bodies = root.onBodies; bodies[id] = { title: title, body: r.body || "", editable: r.editable === true }; root.onBodies = bodies
        if (root.currentPath === path) {
          editor.setNote(title, r.body || "")
          editor.readOnly = r.editable !== true
          root.loadingNote = false
          root.dirty = false
        }
      }
    }
  }

  Process {
    id: onCreateProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.statusText = ""
        var r
        try { r = JSON.parse(this.text) } catch (e) { r = { error: "unexpected reply" } }
        if (r.error) { root.statusText = "OneNote: " + r.error; statusTimer.restart(); return }
        root.onPages = [r.page].concat(root.onPages)
        var bodies = root.onBodies; bodies[r.page.id] = { title: "", body: "", editable: true }; root.onBodies = bodies
        var sct = root.onSection(r.page.sectionId)
        var exp = root.onExpanded.slice()
        if (sct && exp.indexOf(sct.notebookId) < 0) exp.push(sct.notebookId)
        if (exp.indexOf(r.page.sectionId) < 0) exp.push(r.page.sectionId)
        root.onExpanded = exp
        root.msApply()
        var path = root.onPageKey + r.page.id
        root.selectPath(path)
        var mi = root.modelIndexOf(path)
        Qt.callLater(function() { if (mi >= 0) list.positionViewAtIndex(mi, ListView.Contain) })
        editor.focusTitle()
      }
    }
  }

  Process {
    id: msCreateProc
    command: ["python3", root.msScript, "create"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.statusText = ""
        var r
        try { r = JSON.parse(this.text) } catch (e) { r = { error: "unexpected reply" } }
        if (r.error) { root.statusText = "Sticky Notes: " + r.error; statusTimer.restart(); return }
        root.msNotes = [r.note].concat(root.msNotes)
        root.msApply()
        var path = root.msKey + r.note.id
        root.selectPath(path)
        var mi = root.modelIndexOf(path)
        Qt.callLater(function() { if (mi >= 0) list.positionViewAtIndex(mi, ListView.Contain) })
        editor.focusEditor()
      }
    }
  }

  Process {
    id: msDeleteProc
    stdout: StdioCollector {
      onStreamFinished: {
        try { var r = JSON.parse(this.text); if (r.error) { root.statusText = "Sticky Notes: " + r.error; statusTimer.restart() } } catch (e) {}
      }
    }
  }

  FileView {
    id: msPayloadFile
    path: root.msPayloadPath
    atomicWrites: true
    printErrors: false
  }

  // ── content: lives in the overlay card or the detached window ───────
  Item {
    id: content
    parent: root.detached ? floatingHost : cardHost
    anchors.fill: parent

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { if (root.handleShortcut(event)) event.accepted = true }

    Column {
      anchors.fill: parent
      spacing: Style.spacing.md

      // ---- header
      Item {
        width: parent.width
        height: Math.max(searchField.height, titleText.implicitHeight)

        Text {
          id: titleText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(150)
          text: "Note Note"
          color: root.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
        }

        TextField {
          id: searchField
          anchors.left: titleText.right
          anchors.leftMargin: Style.spacing.md
          width: Style.space(280)
          placeholderText: "Search notes…"
          foreground: root.foreground
          accent: root.accent
          font.family: Style.font.menuFamily
          verticalPadding: Style.spacing.xxs
          onTextEdited: root.setFilter(text)
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
              editor.focusEditor(); event.accepted = true
            } else if (root.handleShortcut(event)) event.accepted = true
          }
        }

        Button {
          id: shapeButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.detached ? "Overlay" : "Detach"
          iconText: root.detached ? "󰨟" : "󰏌"
          tooltipText: root.detached
            ? "Back to the overlay: summoned over your work, gone on Escape"
            : "Detach into an ordinary window you can keep open beside your work"
          bordered: true
          selected: root.detached
          foreground: root.foreground
          accent: root.accent
          iconSize: Style.font.iconSmall
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.xxs
          onClicked: root.setDetached(!root.detached)
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: searchField.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: shapeButton.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          text: root.statusText.length > 0 ? root.statusText
            : "ctrl+k search · ctrl+↑↓ note · ctrl+n new · ctrl+shift+n notebook · esc back"
          color: root.statusText.length > 0 ? root.accent : Qt.darker(root.foreground, 1.55)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignRight
        }
      }

      PanelSeparator { width: parent.width; foreground: root.foreground }

      // ---- body
      Row {
        width: parent.width
        height: parent.height - y
        spacing: Style.spacing.lg

        NoteList {
          id: list
          width: Style.space(215)
          height: parent.height
          model: root.rows
          currentPath: root.currentPath
          filtering: root.filterText.length > 0
          collapsed: root.revision < 0 ? [] : root.foldedKeys()
          foreground: root.foreground
          accent: root.accent
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          titleFor: root.displayTitle
          onActivated: function(path) { root.selectPath(path); editor.focusEditor() }
          onNewRequested: function(key) { root.newNote(key) }
          onTreeToggled: function(id) { root.onToggle(id) }
          onNewNotebookRequested: function(name) { root.newNotebook(name) }
          onActionRequested: function(id) { root.msAction(id) }
          onDeleteRequested: function(path) { root.requestDelete(path) }
          onSectionToggled: function(key) { root.toggleSection(key) }
          onMoveRequested: function(from, to) { root.moveNote(from, to) }
          onReorderFinished: function(key) { root.saveOrder(key) }
        }

        Rectangle {
          width: 1
          height: parent.height
          color: Util.alpha(root.foreground, 0.15)
        }

        NoteEditor {
          id: editor
          width: parent.width - list.width - Style.spacing.lg * 2 - 1
          height: parent.height
          hasNote: root.currentPath !== ""
          plain: root.isMs(root.currentPath)
          hasTitle: !root.isMs(root.currentPath)
          fileName: !root.currentPath ? "" : (root.isMs(root.currentPath) ? "synced online"
            : (root.isOnPage(root.currentPath) ? (root.onLoadingPath === root.currentPath ? "loading…" : (editor.readOnly ? "has images — edit in OneNote" : "synced online"))
            : root.baseName(root.currentPath)))
          notebookName: root.currentNotebookName
          placeholder: root.onLoadingPath && root.onLoadingPath === root.currentPath ? "Loading from OneNote…"
            : root.notes.length === 0 && !root.filterText
            ? (root.notebooks.length === 0 ? "No notebooks yet — add one at the bottom of the list." : "No notes yet — press ctrl+n to create one.")
            : ""
          foreground: root.foreground
          accent: root.accent
          shortcutHandler: root.handleShortcut
          onEdited: root.onEdited()
        }
      }
    }

    ConfirmDialog {
      id: deleteConfirm
      anchors.fill: parent
      opened: root.deleteConfirmOpen
      z: 10
      message: "Delete this note?"
      confirmText: "Delete"
      background: root.background
      foreground: root.foreground
      scrim: root.scrim
      selectedBackground: root.selectedBackground
      selectedText: root.selectedText
      fontFamily: Style.font.menuFamily
      cornerRadius: Style.cornerRadius
      onCanceled: root.cancelDelete()
      onConfirmed: root.confirmDelete()
    }
  }

  // ── overlay ─────────────────────────────────────────────────────────
  PanelWindow {
    id: panel
    visible: root.opened && !root.detached
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-note-note"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      // Roomy on a big display, but never wider than the screen.
      width: Math.min(Math.max(Style.space(900), Math.round(panel.width * 0.72)),
                      panel.width - Style.gapsOut * 2)
      height: Math.min(Math.max(Style.space(600), Math.round(panel.height * 0.82)),
                       panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: cardHost
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
      }
    }
  }

  // ── detached window ─────────────────────────────────────────────────
  FloatingWindow {
    id: floating
    visible: root.opened && root.detached
    title: "Note Note"
    color: root.background
    implicitWidth: Style.space(1120)
    implicitHeight: Style.space(760)
    minimumSize: Qt.size(Style.space(760), Style.space(480))

    // Closing from the titlebar should read as dismissing the plugin.
    onVisibleChanged: { if (!visible && root.opened && root.detached) root.dismiss() }

    FocusScope {
      anchors.fill: parent
      focus: true

      Item {
        id: floatingHost
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
      }
    }
  }
}
