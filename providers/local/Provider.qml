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
  readonly property string name: "Notes"
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
        rows.push({ kind: "note", path: n.path, title: n.title, preview: n.preview })
      }
      rows.push({ kind: "new", path: "section:" + nb.key })
      out.push({ key: nb.key, name: nb.name, collapsedByDefault: false, rows: rows })
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
      else if (p[0] === "N") entries.push({ key: p[1] || "", file: p[2], path: pathOf(p[2]), title: p[3] || "", preview: p[4] || "" })
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
  property var pendingLoad: null
  function load(path, cb) {
    root.pendingLoad = { path: path, cb: cb }
    noteFile.path = fileOf(path)
    noteFile.reload()
  }

  function save(path, title, body, cb) {
    writeFile.path = fileOf(path)
    writeFile.setText(serializeNote(title, body))
    var arr = root.notes.slice()
    for (var i = 0; i < arr.length; i++) if (arr[i].path === path)
      arr[i] = { key: arr[i].key, file: arr[i].file, path: path, title: title.trim(), preview: previewOf(body) }
    root.notes = arr
    rebuild()
    if (cb) cb({})
  }

  function create(target, cb) {
    var key = target.indexOf("section:") === 0 ? target.substring(8) : ""
    var file = dirOf(key) + "/note-" + Date.now() + ".md"
    writeFile.path = file
    writeFile.setText(serializeNote("", ""))
    var entry = { key: key, file: file, path: pathOf(file), title: "", preview: "" }
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

  function persistOrder(key) {
    var names = root.notes.filter(function(n) { return n.key === key }).map(function(n) { return baseName(n.file) })
    orderFile.path = dirOf(key) + "/.order"
    orderFile.setText(names.join("\n") + "\n")
  }
  function persistNotebookOrder() {
    orderFile.path = root.notesDir + "/.notebooks"
    orderFile.setText(root.notebooks.filter(function(b) { return b.key }).map(function(b) { return b.key }).join("\n") + "\n")
  }

  FileView {
    id: noteFile
    printErrors: false
    onLoaded: {
      var p = root.pendingLoad; root.pendingLoad = null
      if (!p) return
      var n = root.parseNote(text())
      p.cb({ title: n.title, body: n.body, editable: true })
    }
    onLoadFailed: {
      var p = root.pendingLoad; root.pendingLoad = null
      if (p) p.cb({ title: "", body: "", editable: true })
    }
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
      if (cb) cb({ key: key })
    }
  }

  // Lists notebooks (folders) and their notes, oldest-first by birth time:
  //   D<TAB>key / O<TAB>key<TAB>name / B<TAB>key / N<TAB>key<TAB>path<TAB>title<TAB>preview
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
}
