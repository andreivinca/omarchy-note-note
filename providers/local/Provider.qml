import Quickshell
import Quickshell.Io
import QtQuick
import "../../services/processes"
import "../../services/requests"

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

  // A write here is a file on this disk rather than a request, so the note
  // can follow the typing closely: the pause is only long enough that a word
  // being typed is one write and not five (noteEdited / saveRequested,
  // PROVIDERS.md).
  signal saveRequested(string path)
  function noteEdited(path) { saveSchedule.path = path; saveSchedule.restart() }
  Timer {
    id: saveSchedule
    property string path: ""
    interval: 500
    onTriggered: root.saveRequested(saveSchedule.path)
  }

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
  // Available before the first notebook exists as well as on every tab.
  readonly property var footerActions: [
    { path: "newNotebook", title: "New notebook", icon: "󰉗",
      inputPlaceholder: "Notebook name", shortcut: "newNotebook" }
  ]

  function notebookActions() {
    return [{ path: "newNote", title: "New Note", icon: "󰐕", shortcut: "newNote" }].concat(root.footerActions)
  }

  function dirOf(key) { return key ? root.notesRoot + "/" + key : root.notesRoot }
  function baseName(p) { return p.substring(p.lastIndexOf("/") + 1) }
  function fileOf(path) { return path.substring(root.id.length + 1) }
  function pathOf(file) { return root.id + ":" + file }
  function noteAt(path) {
    for (var i = 0; i < root.notes.length; i++) {
      if (root.notes[i].path === path) {
        return root.notes[i]
      }
    }
    return null
  }
  function nameOf(key) {
    for (var i = 0; i < root.notebooks.length; i++) {
      if (root.notebooks[i].key === key) {
        return root.notebooks[i].name
      }
    }
    return key || "Notes"
  }

  // ── file format ─────────────────────────────────────────────────────
  function parseNote(raw) {
    var m = /^---\n(?:title:[ \t]?(.*))?\n?---\n?/.exec(raw)
    if (!m) {
      return { title: "", body: raw }
    }
    return { title: (m[1] || "").trim(), body: raw.substring(m[0].length) }
  }
  function previewOf(body) {
    var lines = body.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].replace(/^[#>\-\*\s]+/, "").replace(/[*_`]/g, "").trim()
      if (l) {
        return l
      }
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
      if (n.key !== nb.key) {
        continue
      }
      rows.push({ kind: "note", path: n.path, title: n.title, preview: n.preview, level: level, fixed: fixed, version: n.version || "", modified: Math.floor(Number(n.version || 0) / 1000000) })
    }
    if (level > 0) {
      rows.push({ kind: "new", path: "section:" + nb.key, level: level })
    }
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
        out.push({ key: nb.key, name: nb.name, rows: notebookRows(nb, 0, false),
                   groupByDate: false, footerActions: notebookActions() })
      }
      root.sections = out
    } else {
      var rows = []
      for (var t = 0; t < root.notebooks.length; t++) {
        var book = root.notebooks[t], open = root.folded.indexOf(book.key) < 0
        rows.push({ kind: "tree", path: "book:" + book.key, title: book.name, level: 0, expanded: open })
        if (open) {
          rows = rows.concat(notebookRows(book, 1, true))
        }
      }
      // Folded trees hide note rows, so the tab's count and the searchable
      // list are given whole (`count` and `notes` in PROVIDERS.md).
      root.sections = [{ key: "notes", name: "Notes", count: root.notes.length,
                         notes: root.notes.map(function(n) { return { path: n.path, title: n.title, preview: n.preview, modified: Math.floor(Number(n.version || 0) / 1000000) } }),
                         rows: rows, groupByDate: false,
                         footerActions: root.notebooks.length ? notebookActions() : root.footerActions }]
    }
    root.updated()
  }

  function crumb(path) { var n = noteAt(path); return n ? nameOf(n.key) : root.name }
  function storageLabel(path) { return baseName(fileOf(path)) }
  function createTargetFor(path) { var n = noteAt(path); return n ? "section:" + n.key : (root.notebooks.length ? "section:" + root.notebooks[root.notebooks.length - 1].key : "") }
  function restoreState(obj) {
    if (obj && Array.isArray(obj.folded)) {
      root.folded = obj.folded
    }
  }
  function saveState() { return { folded: root.folded } }
  function action(id, value, sectionKey) {
    if (id === "newNote") {
      var target = root.notebookTabs ? "section:" + sectionKey : createTargetFor(root.host.currentPath)
      root.host.newNote(root.id, target)
    } else if (id === "newNotebook") {
      root.host.newNotebook(value, root.id)
    }
  }
  function toggleTree(id) {
    if (id.indexOf("book:") !== 0) {
      return
    }
    var key = id.substring(5), at = root.folded.indexOf(key), next = root.folded.slice()
    if (at >= 0) {
      next.splice(at, 1)
    } else {
      next.push(key)
    }
    root.folded = next
    rebuild()
    root.persistRequested()
  }
  // A note inside a folded notebook has no row; unfold it so the host can
  // scroll to the row — asked for when a search ends on such a note.
  function revealPath(path) {
    var n = noteAt(path)
    if (!n || root.folded.indexOf(n.key) < 0) {
      return
    }
    root.folded = root.folded.filter(function(k) { return k !== n.key })
    rebuild()
    root.persistRequested()
  }

  property bool listing: false
  property bool relistDue: false
  function refresh() {
    root.relistDue = true
    if (root.listing || mutations.depth > 0) {
      return
    }
    root.relistDue = false
    root.listing = true
    var revision = root.mutationRevision
    runner.run({ command: ["python3", root.listScript, root.notesRoot, String(root.maxListBytes)], raw: true }, function(result) {
      root.listing = false
      if (result.error) {
        root.statusRequested(root.name + ": " + result.error)
      } else if (revision === root.mutationRevision) {
        root.loadList(result.text)
      } else {
        root.relistDue = true
      }
      if (root.relistDue) {
        Qt.callLater(root.refresh)
      }
    })
  }

  // A superseded search settles its old caller before starting the new one.
  property var searchHandle: null
  function search(query, callback) {
    if (root.searchHandle) {
      root.searchHandle.cancel()
    }
    root.searchHandle = runner.run({ command: ["python3", root.searchScript, root.notesRoot, query, String(root.maxNoteBytes)], raw: true }, function(result) {
      callback({ paths: (result.text || "").split("\n").filter(function(line) { return !!line }).map(root.pathOf) })
    })
  }

  // Saved order first, then anything unlisted in the given (birth-time) order.
  function applyOrder(entries, keyOf, savedNames) {
    var rank = {}
    for (var i = 0; i < savedNames.length; i++) {
      if (savedNames[i]) {
        rank[savedNames[i]] = i
      }
    }
    return entries.map(function(e, i) { return { e: e, i: i } })
      .sort(function(a, b) {
        var ra = rank[keyOf(a.e)], rb = rank[keyOf(b.e)], ha = ra !== undefined, hb = rb !== undefined
        if (ha && hb) {
          return ra - rb
        }
        if (ha) {
          return -1
        }
        if (hb) {
          return 1
        }
        return a.i - b.i
      }).map(function(x) { return x.e })
  }

  // Parses the listing script's output.
  function loadList(raw) {
    var lines = raw.split("\n"), dirs = [], orders = {}, bookOrder = [], entries = []
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p[0] === "D") {
        dirs.push(p[1] || "")
      } else if (p[0] === "O") {
        (orders[p[1] || ""] = orders[p[1] || ""] || []).push(p[2])
      } else if (p[0] === "B") {
        bookOrder.push(p[1])
      } else if (p[0] === "N") {
        entries.push({ key: p[1] || "", file: p[2], path: pathOf(p[2]), title: p[3] || "", preview: p[4] || "", size: Number(p[5] || 0), version: p[6] || "" })
      }
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

  // Reads retain errors and the byte limit from the same descriptor as the text.
  ProcessRunner { id: runner }
  RequestQueue {
    id: mutations
    domain: "local"
    concurrency: 1
    onUpdated: {
      if (mutations.depth === 0 && root.relistDue) {
        Qt.callLater(root.refresh)
      }
    }
  }
  readonly property bool busy: mutations.depth > 0 || runner.active > 0
  property int mutationRevision: 0
  property var deleting: ({})

  function load(path, cb) {
    var file = root.fileOf(path)
    return runner.run({ command: ["python3", root.readScript, "--json", file, String(root.maxNoteBytes)] }, function(result) {
      if (result.error) {
        cb(result)
        return
      }
      var note = root.parseNote(result.text)
      cb({ title: note.title, body: note.body, editable: true, version: result.version,
           base: file.substring(0, file.lastIndexOf("/")) })
    })
  }

  // Staging, writing, creating and deleting share one ordering policy.
  // Callers and models see success only after the filesystem has committed.
  function mutate(key, payload, commit, cb) {
    return mutations.enqueue({ key: key, mode: "append", owner: root, flush: true }, function(ctx) {
      root.mutationRevision++
      var request = typeof payload === "function" ? payload() : payload
      request.root = root.notesRoot
      runner.run({ command: ["python3", root.dir + "/operations.py"],
                   payload: JSON.stringify(request), timeoutMs: 60000 }, ctx.done)
    }, function(result, info) {
      root.mutationRevision++
      var answer = result || { error: info.cancelled ? "operation cancelled" : "operation was not completed" }
      if (!answer.error) {
        commit(answer)
      }
      if (cb) {
        cb(answer)
      } else if (answer.error) {
        root.statusRequested(root.name + ": " + answer.error)
      }
    })
  }

  function save(path, title, body, cb) {
    if (root.deleting[path]) {
      cb({ error: "the note is being deleted" })
      return
    }
    mutate(path, { action: "save", file: fileOf(path), title: title, body: body }, function(result) {
      root.notes = root.notes.map(function(note) {
        if (note.path !== path) {
          return note
        }
        return { key: note.key, file: note.file, path: path, title: title.trim(),
                 preview: previewOf(result.body), size: result.bytes, version: result.version }
      })
      rebuild()
    }, cb)
  }

  function create(target, cb) {
    var key = target.indexOf("section:") === 0 ? target.substring(8) : ""
    mutate("create:" + key, { action: "create", key: key }, function(result) {
      root.folded = root.folded.filter(function(k) { return k !== key })
      root.persistRequested()
      var entry = { key: key, file: result.file, path: pathOf(result.file),
                    title: "", preview: "", size: result.bytes, version: result.version }
      var arr = root.notes.slice(), at = arr.length
      for (var i = arr.length - 1; i >= 0; i--) {
        if (arr[i].key === key) {
          at = i + 1
          break
        }
      }
      arr.splice(at, 0, entry)
      root.notes = arr
      result.path = entry.path
      rebuild()
      persistOrder(key)
    }, cb)
  }

  function remove(path, cb) {
    var note = noteAt(path)
    if (!note) {
      cb({ error: "unknown note" })
      return
    }
    root.deleting[path] = true
    mutate(path, { action: "remove", file: note.file }, function(result) {
      root.notes = root.notes.filter(function(n) { return n.path !== path })
      rebuild()
      persistOrder(note.key)
    }, function(result) {
      delete root.deleting[path]
      if (cb) {
        cb(result)
      }
    })
  }

  function createSection(name, cb) {
    var key = name.replace(/[/\\]/g, "-").trim()
    if (!key || key[0] === ".") {
      cb({ error: "invalid name" })
      return
    }
    mutate("section:" + key, { action: "section", key: key }, function(result) {
      if (!root.notebooks.some(function(book) { return book.key === key })) {
        root.notebooks = root.notebooks.concat([{ key: key, name: key, dir: root.dirOf(key) }])
        persistNotebookOrder()
      }
      result.key = root.notebookTabs ? key : "notes"
      result.target = "section:" + key
      rebuild()
    }, cb)
  }

  function reorderNotes(sectionKey, paths) {
    var rank = {}
    paths.forEach(function(path, index) { rank[path] = index })
    var mine = root.notes.filter(function(note) { return note.key === sectionKey })
    mine = mine.map(function(note, index) { return { note: note, index: index } })
      .sort(function(a, b) {
        var left = rank[a.note.path], right = rank[b.note.path]
        return (left === undefined ? paths.length + a.index : left)
             - (right === undefined ? paths.length + b.index : right)
      }).map(function(entry) { return entry.note })
    var next = 0
    return root.notes.map(function(note) { return note.key === sectionKey ? mine[next++] : note })
  }

  function setOrder(sectionKey, paths) {
    var file = dirOf(sectionKey) + "/.order"
    mutate("order:" + file, function() {
      var names = reorderNotes(sectionKey, paths).filter(function(note) { return note.key === sectionKey })
        .map(function(note) { return baseName(note.file) })
      return { action: "order", file: file, text: names.join("\n") + "\n" }
    }, function(result) {
      root.notes = reorderNotes(sectionKey, paths)
      rebuild()
    })
  }

  // ── watching: inotify while the app is open (event-driven, no polling) ──
  function watch(on) {
    if (on && !watchProc.running) {
      watchProc.running = true
    } else if (!on && watchProc.running) {
      watchProc.running = false
    }
  }
  function poll() { root.refresh() }
  Timer { id: relistDebounce; interval: 400; onTriggered: root.refresh() }
  Process {
    id: watchProc
    command: ["inotifywait", "-m", "-r", "-q", "-e", "create,delete,move,close_write", "--format", "%e %w%f", "--", root.notesRoot]
    stdout: SplitParser {
      onRead: function(line) {
        if (/\/\.(order|notebooks)(\s|$)/.test(line)) {
          return  // our bookkeeping files
        }
        relistDebounce.restart()
      }
    }
  }

  function persistOrder(key) {
    var file = dirOf(key) + "/.order"
    mutate("order:" + file, function() {
      var names = root.notes.filter(function(note) { return note.key === key }).map(function(note) { return baseName(note.file) })
      return { action: "order", file: file, text: names.join("\n") + "\n" }
    }, function(result) {})
  }

  function persistNotebookOrder() {
    var file = root.notesRoot + "/.notebooks"
    mutate("order:" + file, function() {
      var keys = root.notebooks.filter(function(book) { return !!book.key }).map(function(book) { return book.key })
      return { action: "order", file: file, text: keys.join("\n") + "\n" }
    }, function(result) {})
  }
}
