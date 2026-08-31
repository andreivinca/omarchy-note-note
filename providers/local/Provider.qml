import Quickshell
import Quickshell.Io
import QtQuick

// Local notebooks: folders under ~/Notes (or $NOTE_NOTE_DIR) holding Markdown
// files with a tiny title front-matter. Notes directly in the root show up as
// a "Notes" notebook. Each folder keeps its order in .order; the notebook
// order lives in .notebooks. A binder tab per folder, or one "Notes" tab of
// fold-out trees — the host's notebookTabs setting decides (true here by
// default).
Item {
  id: root

  readonly property string id: "local"
  // The header titles whichever provider's tab is open; the local notebooks
  // are the app's own, so they go by the app's name.
  readonly property string name: "Note Note"
  readonly property bool markdown: true
  readonly property bool hasTitle: true
  // A pasted picture is copied into `.assets/` beside the note on save
  // (images.py) and the note keeps a relative link, resolved through the
  // `base` this provider returns from load().
  readonly property bool canImages: true
  readonly property bool canCreate: true
  readonly property bool canDelete: true
  readonly property bool canReorder: true
  readonly property bool canCreateSection: true
  readonly property var microsoftScopes: []

  property var host: null
  property var services: null

  // The host assigns these from config.providers.local right after creating
  // this provider (~/.config/notenote/config.json); the initial values only
  // stand in for the rare case they never arrive.
  // notebookTabs: one binder tab per notebook folder — this provider's
  // historic shape — or, false, a single "Notes" tab holding the folders as
  // fold-out trees, the same shape the remote providers use.
  property bool notebookTabs: true
  property string notesDir: Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes")
  // notesDir as everything below reads it: "~" expands here, not in the
  // host — the path is this provider's to interpret, and it reaches
  // processes as a literal argv entry, never through a shell, so nothing
  // else would expand it. An emptied setting falls back to the default.
  readonly property string notesRoot: {
    var p = root.notesDir || Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes")
    return p.charAt(0) === "~" ? Quickshell.env("HOME") + p.substring(1) : p
  }
  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  // Both readers refuse symlinks and special files and race a deadline
  // (docs/security.md, rule 9): a path under ~/Notes is user-writable and
  // cannot be trusted to be a plain file.
  readonly property string listScript: dir + "/list.py"
  readonly property string searchScript: dir + "/search.py"
  readonly property string imagesScript: dir + "/images.py"
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

  function dirOf(key) { return key ? root.notesRoot + "/" + key : root.notesRoot }
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
  // Notebooks the user folded shut (single-tab shape only), by key — kept in
  // the host's state file. The folded set rather than the open one, so the
  // first flip of the setting shows every notebook open instead of every
  // notebook gone.
  property var folded: []

  function notebookRows(nb, level, fixed) {
    var rows = []
    for (var i = 0; i < root.notes.length; i++) {
      var n = root.notes[i]
      if (n.key !== nb.key) continue
      rows.push({ kind: "note", path: n.path, title: n.title, preview: n.preview, level: level, fixed: fixed, version: n.version || "" })
    }
    rows.push({ kind: "new", path: "section:" + nb.key, level: level })
    return rows
  }
  // Two shapes, one setting (notebookTabs): a binder tab per notebook
  // folder, or one "Notes" tab holding the folders as fold-out trees. In the
  // single tab the note rows are fixed: a drag across trees would be a move
  // between notebooks, which is a different feature, not a reorder.
  function rebuild() {
    if (root.notebookTabs) {
      var out = []
      for (var b = 0; b < root.notebooks.length; b++) {
        var nb = root.notebooks[b]
        // No colour: a notebook takes its own from its name, so Work and
        // Personal never look alike.
        out.push({ key: nb.key, name: nb.name, rows: notebookRows(nb, 0, false) })
      }
      root.sections = out
    } else {
      var rows = []
      for (var t = 0; t < root.notebooks.length; t++) {
        var book = root.notebooks[t], open = root.folded.indexOf(book.key) < 0
        rows.push({ kind: "tree", path: "book:" + book.key, title: book.name, level: 0, expanded: open })
        if (open) rows = rows.concat(notebookRows(book, 1, true))
      }
      // Folded trees hide note rows, so the tab's count and the searchable
      // list are given whole (`count` and `notes` in PROVIDERS.md).
      root.sections = [{ key: "notes", name: "Notes", count: root.notes.length,
                         notes: root.notes.map(function(n) { return { path: n.path, title: n.title, preview: n.preview } }),
                         rows: rows }]
    }
    root.updated()
  }

  function crumb(path) { var n = noteAt(path); return n ? nameOf(n.key) : root.name }
  function createTargetFor(path) { var n = noteAt(path); return n ? "section:" + n.key : (root.notebooks.length ? "section:" + root.notebooks[root.notebooks.length - 1].key : "") }
  function restoreState(obj) { if (obj && Array.isArray(obj.folded)) root.folded = obj.folded }
  function saveState() { return { folded: root.folded } }
  function action(id) {}
  function toggleTree(id) {
    if (id.indexOf("book:") !== 0) return
    var key = id.substring(5), at = root.folded.indexOf(key), next = root.folded.slice()
    if (at >= 0) next.splice(at, 1); else next.push(key)
    root.folded = next
    rebuild()
    root.persistRequested()
  }
  // A note inside a folded notebook has no row; unfold it so the host can
  // scroll to the row — asked for when a search ends on such a note.
  function revealPath(path) {
    var n = noteAt(path)
    if (!n || root.folded.indexOf(n.key) < 0) return
    root.folded = root.folded.filter(function(k) { return k !== n.key })
    rebuild()
    root.persistRequested()
  }

  function refresh() { listProc.running = true }

  // ── content search ──────────────────────────────────────────────────
  // The host matches titles and previews itself; this answers the rest —
  // the paths of notes whose *body* holds the query (search.py, same walk
  // and read policy as the listing). One process at a time: a query that
  // arrives while one runs kills it, and the exit starts the newer one.
  property var searchCb: null
  property string searchPending: ""
  function search(query, cb) {
    // A newer ask supersedes the one still in flight, but its callback
    // still gets an answer — empty, which best-effort allows — so "call cb
    // exactly once" holds no matter what the host does between asks.
    if (root.searchCb) root.searchCb({ paths: [] })
    root.searchCb = cb
    root.searchPending = query
    if (searchProc.running) { searchProc.running = false; return }
    runSearch()
  }
  function runSearch() {
    if (root.searchPending === "") return
    searchProc.command = ["python3", root.searchScript, root.notesRoot, root.searchPending, String(root.maxNoteBytes)]
    root.searchPending = ""
    searchProc.running = true
  }
  Process {
    id: searchProc
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.searchPending !== "") return   // superseded; the newer query answers
        var cb = root.searchCb
        root.searchCb = null
        if (!cb) return
        cb({ paths: this.text.split("\n").filter(function(l) { return l.length > 0 }).map(root.pathOf) })
      }
    }
    onExited: if (root.searchPending !== "") Qt.callLater(root.runSearch)
  }

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
          // `base` is the note's own folder: how the editor and the
          // converter resolve the relative image links this provider keeps.
          var file = root.fileOf(job.path)
          job.cb({ title: n.title, body: n.body, editable: true, version: ver,
                   base: file.substring(0, file.lastIndexOf("/")) })
        }
      }
    }
    onExited: Qt.callLater(root.nextRead)
  }

  // Our own writes fire inotify too; ignore events that follow one closely.
  property double lastOwnWrite: 0
  function save(path, title, body, cb) {
    // A pasted picture is still a link into the clipboard's staging dir;
    // images.py copies it into `.assets/` beside the note and hands back the
    // body with the link made relative. Bodies without file:// links — the
    // ordinary case — skip the process entirely.
    if (body.indexOf("](file://") >= 0) stageImages(path, title, body, cb)
    else writeNote(path, title, body, cb, "")
  }

  function writeNote(path, title, body, cb, warning) {
    root.lastOwnWrite = Date.now()
    writeFile.path = fileOf(path)
    writeFile.setText(serializeNote(title, body))
    var arr = root.notes.slice()
    for (var i = 0; i < arr.length; i++) if (arr[i].path === path)
      arr[i] = { key: arr[i].key, file: arr[i].file, path: path, title: title.trim(), preview: previewOf(body), size: body.length, version: "" }
    root.notes = arr
    rebuild()
    if (cb) cb(warning ? { warning: warning } : {})
  }

  // A note with a pasted picture is the one save here that is not immediate:
  // images.py has to copy the file into `.assets/` before the note can name
  // it. So two saves of one note can be in flight at once, and the slower one
  // would land last and undo the newer text. One stage per note, then: a save
  // arriving while one runs waits for it, replacing whatever was already
  // waiting — the newest text strictly contains the older, and its caller is
  // answered rather than dropped. (The remote providers get the same
  // guarantee from their queue's "replace" mode; this is the local shape of
  // it, for the one path here that needs it.)
  property var staging: ({})     // path -> true while a stage runs
  property var stageNext: ({})   // path -> the newest save waiting behind it

  // The note is written no matter what: a failed copy only leaves the link
  // pointing at the staged file (still shown, pruned eventually) and says so.
  function stageImages(path, title, body, cb) {
    if (root.staging[path]) {
      var waiting = root.stageNext[path]
      root.stageNext[path] = { title: title, body: body, cb: cb }
      if (waiting && waiting.cb) waiting.cb({})    // superseded, never silent
      return
    }
    root.staging[path] = true
    root.lastOwnWrite = Date.now()
    var proc = imageStager.createObject(root, {
      command: ["python3", root.imagesScript, root.notesRoot, fileOf(path)],
      callback: function(result) {
        var ok = result && result.body !== undefined
        delete root.staging[path]
        writeNote(path, title, ok ? result.body : body, cb,
                  (result && (result.warning || result.error)) || (ok ? "" : "pasted images were not copied into the notebook"))
        var next = root.stageNext[path]
        if (next) { delete root.stageNext[path]; root.stageImages(path, next.title, next.body, next.cb) }
      }
    })
    proc.stdinEnabled = true                 // stdin must be open before it starts
    proc.running = true
    proc.write(body)
    proc.stdinEnabled = false                // close stdin: the script reads to EOF
  }

  Component {
    id: imageStager
    Process {
      id: proc
      // The note goes over stdin, never argv (docs/security.md rule 2).
      property var callback: null
      stdout: StdioCollector {
        onStreamFinished: {
          var done = proc.callback
          proc.callback = null
          var result = null
          try { result = JSON.parse(this.text) } catch (error) { result = null }
          if (done) done(result)
          Qt.callLater(function() { proc.destroy() })
        }
      }
      onExited: function(code) {
        if (proc.callback) { var done = proc.callback; proc.callback = null; done(null) }
      }
    }
  }

  function create(target, cb) {
    var key = target.indexOf("section:") === 0 ? target.substring(8) : ""
    // A note made into a folded notebook must land on a visible row, so the
    // fold opens — the same courtesy OneNote's create() extends.
    if (root.folded.indexOf(key) >= 0) { root.folded = root.folded.filter(function(k) { return k !== key }); root.persistRequested() }
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
    command: ["inotifywait", "-m", "-r", "-q", "-e", "create,delete,move,close_write", "--format", "%e %w%f", "--", root.notesRoot]
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
    orderFile.path = root.notesRoot + "/.notebooks"
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
      // The tab this opens as: the new folder's own when each notebook is a
      // tab, the one "Notes" tab that holds it when they fold — the host
      // opens whichever key is answered (PROVIDERS.md).
      if (cb) cb({ key: root.notebookTabs ? key : "notes", target: "section:" + key })
    }
  }

  // Lists notebooks (folders) and their notes, oldest-first by birth time —
  // see list.py for the D/O/B/N line format and the read policy (every file
  // through readfile.py; symlinked notes and notebooks are not listed).
  Process {
    id: listProc
    command: ["python3", root.listScript, root.notesRoot, String(root.maxListBytes)]
    stdout: StdioCollector { onStreamFinished: root.loadList(this.text) }
  }
}
