import Quickshell
import Quickshell.Io
import QtQuick

// Local notebooks: folders under ~/Notes (or $NOTE_NOTE_DIR) holding Markdown
// files with a tiny title front-matter. Notes directly in the root show up as
// a "Notes" notebook. Each folder keeps its order in .order; the notebook
// order lives in .notebooks.
Item {
  id: root

  readonly property string id: "local"
  // The header titles whichever provider's tab is open; the local notebooks
  // are the app's own, so they go by the app's name.
  readonly property string name: "Note Note"
  readonly property bool markdown: true
  readonly property bool hasTitle: true
  readonly property bool canCreate: true
  readonly property bool canDelete: true
  readonly property bool canReorder: true
  readonly property bool canCreateSection: true
  readonly property var microsoftScopes: []

  property var host: null
  property var services: null

  readonly property string notesDir: Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes")
  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  // Both readers refuse symlinks and special files and race a deadline
  // (docs/security.md, rule 9): a path under ~/Notes is user-writable and
  // cannot be trusted to be a plain file.
  readonly property string listScript: dir + "/list.py"
  readonly property string readScript: dir + "/../../lib/readfile.py"
  // This provider's limits: a note bigger than this is listed but not loaded
  // (it is almost certainly not a note), and the listing itself is capped.
  readonly property int maxNoteBytes: 2 * 1024 * 1024
  readonly property int maxListBytes: 4 * 1024 * 1024

  signal updated()
  signal statusRequested(string text)
  signal noticeRequested(string title, string text, string code, var actions)
  signal noticeCleared()
  signal viewRequested(string title, var component, var props)
  signal viewCleared()
  signal persistRequested()

  // notebooks: [{ key, name, dir }]; notes: [{ path, key, file, title, preview }]
  property var notebooks: []
  property var notes: []
  property var sections: []

  function dirOf(key) { return key ? root.notesDir + "/" + key : root.notesDir }
  function baseName(p) { return p.substring(p.lastIndexOf("/") + 1) }
  function fileOf(path) { return path.substring(root.id.length + 1) }
  function pathOf(file) { return root.id + ":" + file }
  function noteAt(path) {
    for (var i = 0; i < root.notes.length; i++) if (root.notes[i].path === path) return root.notes[i]
    return null
  }
  function nameOf(key) {
    for (var i = 0; i < root.notebooks.length; i++) if (root.notebooks[i].key === key) return root.notebooks[i].name
    return key || "Notes"
  }

  // ── file format ─────────────────────────────────────────────────────
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

  // ── sections ────────────────────────────────────────────────────────
  function rebuild() {
    var out = []
    for (var b = 0; b < root.notebooks.length; b++) {
      var nb = root.notebooks[b], rows = []
      for (var i = 0; i < root.notes.length; i++) {
        var n = root.notes[i]
        if (n.key !== nb.key) continue
        rows.push({ kind: "note", path: n.path, title: n.title, preview: n.preview, version: n.version || "" })
      }
      rows.push({ kind: "new", path: "section:" + nb.key })
      // No colour: a notebook takes its own from its name, so Work and
      // Personal never look alike.
      out.push({ key: nb.key, name: nb.name, rows: rows })
    }
    root.sections = out
    root.updated()
  }

  function crumb(path) { var n = noteAt(path); return n ? nameOf(n.key) : root.name }
  function createTargetFor(path) { var n = noteAt(path); return n ? "section:" + n.key : (root.notebooks.length ? "section:" + root.notebooks[root.notebooks.length - 1].key : "") }
  function restoreState(obj) {}
  function saveState() { return {} }
  function action(id) {}
  function toggleTree(id) {}

  function refresh() { listProc.running = true }

  // Saved order first, then anything unlisted in the given (birth-time) order.
  function applyOrder(entries, keyOf, savedNames) {
    var rank = {}
    for (var i = 0; i < savedNames.length; i++) if (savedNames[i]) rank[savedNames[i]] = i
    return entries.map(function(e, i) { return { e: e, i: i } })
      .sort(function(a, b) {
        var ra = rank[keyOf(a.e)], rb = rank[keyOf(b.e)], ha = ra !== undefined, hb = rb !== undefined
        if (ha && hb) return ra - rb
        if (ha) return -1
        if (hb) return 1
        return a.i - b.i
      }).map(function(x) { return x.e })
  }

  // Parses the listing script's output (see listProc).
  function loadList(raw) {
    var lines = raw.split("\n"), dirs = [], orders = {}, bookOrder = [], entries = []
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p[0] === "D") dirs.push(p[1] || "")
      else if (p[0] === "O") (orders[p[1] || ""] = orders[p[1] || ""] || []).push(p[2])
      else if (p[0] === "B") bookOrder.push(p[1])
      else if (p[0] === "N") entries.push({ key: p[1] || "", file: p[2], path: pathOf(p[2]), title: p[3] || "", preview: p[4] || "", size: Number(p[5] || 0), version: p[6] || "" })
    }
    var books = dirs.filter(function(k) { return k !== "" || entries.some(function(e) { return e.key === "" }) })
      .map(function(k) { return { key: k, name: k || "Notes", dir: dirOf(k) } })
    books = applyOrder(books, function(b) { return b.key }, bookOrder)
    root.notebooks = books.filter(function(b) { return b.key === "" }).concat(books.filter(function(b) { return b.key !== "" }))
    var ordered = []
    for (var b = 0; b < root.notebooks.length; b++) {
      var key = root.notebooks[b].key
      ordered = ordered.concat(applyOrder(entries.filter(function(e) { return e.key === key }),
                                          function(e) { return baseName(e.file) }, orders[key] || []))
    }
    root.notes = ordered
    rebuild()
  }

  // ── notes ───────────────────────────────────────────────────────────
  // A note is read exactly once, through one descriptor (lib/readfile.py):
  // no symlink following, regular files only, at most maxNoteBytes+1 bytes,
  // against a deadline — and those bytes are what is shown. No size check
  // followed by a reopen, so a file that grows between listing and opening
  // cannot exceed the cap, and a FIFO cannot hold the queue.
  property var loadQueue: []
  function load(path, cb) {
    root.loadQueue.push({ path: path, cb: cb })
    if (!readProc.running) nextRead()
  }
  function nextRead() {
    if (root.loadQueue.length === 0) return
    var job = root.loadQueue[0]
    readProc.command = ["python3", root.readScript, fileOf(job.path), String(root.maxNoteBytes + 1)]
    readProc.running = true
  }
  Process {
    id: readProc
    stdout: StdioCollector {
      onStreamFinished: {
        var job = root.loadQueue.shift()
        if (!job) return
        var e = root.noteAt(job.path), ver = e ? e.version || "" : ""
        if (this.text.length > root.maxNoteBytes) {
          job.cb({ title: e ? e.title : "", body: "This file is larger than " + Math.round(root.maxNoteBytes / 1048576) + " MB — too large to open as a note. Edit it in an editor instead.", editable: false, version: ver })
        } else {
          var n = root.parseNote(this.text)
          job.cb({ title: n.title, body: n.body, editable: true, version: ver })
        }
      }
    }
    onExited: Qt.callLater(root.nextRead)
  }

  // Our own writes fire inotify too; ignore events that follow one closely.
  property double lastOwnWrite: 0
  function save(path, title, body, cb) {
    root.lastOwnWrite = Date.now()
    writeFile.path = fileOf(path)
    writeFile.setText(serializeNote(title, body))
    var arr = root.notes.slice()
    for (var i = 0; i < arr.length; i++) if (arr[i].path === path)
      arr[i] = { key: arr[i].key, file: arr[i].file, path: path, title: title.trim(), preview: previewOf(body), size: body.length, version: "" }
    root.notes = arr
    rebuild()
    if (cb) cb({})
  }

  function create(target, cb) {
    var key = target.indexOf("section:") === 0 ? target.substring(8) : ""
    var file = dirOf(key) + "/note-" + Date.now() + ".md"
    root.lastOwnWrite = Date.now()
    writeFile.path = file
    writeFile.setText(serializeNote("", ""))
    var entry = { key: key, file: file, path: pathOf(file), title: "", preview: "", size: 0 }
    var arr = root.notes.slice(), at = arr.length
    for (var i = arr.length - 1; i >= 0; i--) if (arr[i].key === key) { at = i + 1; break }
    if (at === arr.length && !arr.some(function(n) { return n.key === key })) {
      var keys = root.notebooks.map(function(b) { return b.key }), after = keys.indexOf(key)
      at = 0
      for (var j = 0; j < arr.length; j++) if (keys.indexOf(arr[j].key) <= after) at = j + 1
    }
    arr.splice(at, 0, entry)
    root.notes = arr
    rebuild()
    persistOrder(key)
    if (cb) cb({ path: entry.path })
  }

  function remove(path, cb) {
    var n = noteAt(path)
    if (!n) { if (cb) cb({ error: "unknown note" }); return }
    root.notes = root.notes.filter(function(x) { return x.path !== path })
    rebuild()
    persistOrder(n.key)
    rmProc.command = ["rm", "-f", "--", n.file]
    rmProc.running = true
    if (cb) cb({})
  }

  property string pendingSection: ""
  property var pendingSectionCb: null
  function createSection(name, cb) {
    var key = name.replace(/[\/\\]/g, "-").trim()
    if (!key || key[0] === ".") { if (cb) cb({ error: "invalid name" }); return }
    root.pendingSection = key
    root.pendingSectionCb = cb
    mkdirProc.command = ["mkdir", "-p", "--", dirOf(key)]
    mkdirProc.running = true
  }

  function setOrder(sectionKey, paths) {
    var mine = [], others = []
    for (var i = 0; i < root.notes.length; i++) (root.notes[i].key === sectionKey ? mine : others).push(root.notes[i])
    var byPath = {}
    for (var j = 0; j < mine.length; j++) byPath[mine[j].path] = mine[j]
    var reordered = paths.map(function(p) { return byPath[p] }).filter(Boolean)
    // keep the notebook grouping: splice the reordered block where the first note was
    var first = -1
    for (var k = 0; k < root.notes.length; k++) if (root.notes[k].key === sectionKey) { first = k; break }
    var arr = others.slice()
    var idx = 0
    for (var m = 0; m < first && m < root.notes.length; m++) if (root.notes[m].key !== sectionKey) idx++
    Array.prototype.splice.apply(arr, [idx, 0].concat(reordered))
    root.notes = arr
    rebuild()
    persistOrder(sectionKey)
  }

  // ── watching: inotify while the app is open (event-driven, no polling) ──
  function watch(on) {
    if (on && !watchProc.running) watchProc.running = true
    else if (!on && watchProc.running) watchProc.running = false
  }
  function poll() {}   // inotify covers it
  Timer { id: relistDebounce; interval: 400; onTriggered: listProc.running = true }
  Process {
    id: watchProc
    command: ["inotifywait", "-m", "-r", "-q", "-e", "create,delete,move,close_write", "--format", "%e %w%f", "--", root.notesDir]
    stdout: SplitParser {
      onRead: function(line) {
        if (Date.now() - root.lastOwnWrite < 1500) return       // our own saves
        if (/\/\.(order|notebooks)(\s|$)/.test(line)) return   // our bookkeeping files
        relistDebounce.restart()
      }
    }
  }

  function persistOrder(key) {
    root.lastOwnWrite = Date.now()
    var names = root.notes.filter(function(n) { return n.key === key }).map(function(n) { return baseName(n.file) })
    orderFile.path = dirOf(key) + "/.order"
    orderFile.setText(names.join("\n") + "\n")
  }
  function persistNotebookOrder() {
    root.lastOwnWrite = Date.now()
    orderFile.path = root.notesDir + "/.notebooks"
    orderFile.setText(root.notebooks.filter(function(b) { return b.key }).map(function(b) { return b.key }).join("\n") + "\n")
  }

  FileView { id: writeFile; atomicWrites: true; printErrors: false }
  FileView { id: orderFile; atomicWrites: true; printErrors: false }
  Process { id: rmProc }
  Process {
    id: mkdirProc
    onExited: {
      var key = root.pendingSection, cb = root.pendingSectionCb
      root.pendingSection = ""; root.pendingSectionCb = null
      if (!key) return
      if (!root.notebooks.some(function(b) { return b.key === key })) {
        root.notebooks = root.notebooks.concat([{ key: key, name: key, dir: root.dirOf(key) }])
        root.persistNotebookOrder()
      }
      root.rebuild()
      if (cb) cb({ key: key, target: "section:" + key })
    }
  }

  // Lists notebooks (folders) and their notes, oldest-first by birth time —
  // see list.py for the D/O/B/N line format and the read policy (every file
  // through readfile.py; symlinked notes and notebooks are not listed).
  Process {
    id: listProc
    command: ["python3", root.listScript, root.notesDir, String(root.maxListBytes)]
    stdout: StdioCollector { onStreamFinished: root.loadList(this.text) }
  }
}
