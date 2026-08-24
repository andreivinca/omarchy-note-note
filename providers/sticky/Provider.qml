import Quickshell
import Quickshell.Io
import QtQuick

// Microsoft Sticky Notes: items in the Outlook mailbox's Notes folder, read
// and written online through Graph (sticky.py). Needs services.microsoft.
Item {
  id: root

  readonly property string id: "sticky"
  readonly property string name: "Sticky Notes"
  readonly property url logo: Qt.resolvedUrl("logo.svg")
  readonly property bool markdown: false
  readonly property bool hasTitle: false      // subject == first line
  readonly property bool canCreate: true
  readonly property bool canDelete: true
  readonly property bool canReorder: false
  readonly property bool canCreateSection: false
  readonly property var microsoftScopes: ["Mail.ReadWrite"]

  property var host: null
  property var services: null
  // This provider's own Microsoft sign-in: own token file, own scope.
  property var ms: null
  Component.onCompleted: { if (services && services.microsoft) root.ms = services.microsoft.create(root.id, root.microsoftScopes) }

  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: dir + "/sticky.py"

  signal updated()
  signal statusRequested(string text)
  signal noticeRequested(string title, string text, string code, var actions)
  signal noticeCleared()
  signal viewRequested(string title, var component, var props)
  signal viewCleared()
  signal persistRequested()

  property var notes: []        // [{ id, title, body, modified }]
  property var sections: []
  readonly property bool ready: ms && ms.signedIn && ms.hasScope("Mail.ReadWrite")

  function idOf(path) { return path.substring(root.id.length + 1) }
  function pathOf(id) { return root.id + ":" + id }
  function noteAt(path) {
    var id = idOf(path)
    for (var i = 0; i < root.notes.length; i++) if (root.notes[i].id === id) return root.notes[i]
    return null
  }
  function previewOf(body) {
    var lines = body.split("\n")
    for (var i = 0; i < lines.length; i++) { var l = lines[i].replace(/^[#>\-\*\s]+/, "").replace(/[*_`]/g, "").trim(); if (l) return l }
    return ""
  }

  function rebuild() {
    var rows = []
    if (!ms || !ms.configured) rows.push({ kind: "action", path: "unavailable", title: "Not available in this build", icon: "󰒓" })
    else if (!ms.signedIn) rows.push({ kind: "action", path: "login", title: ms.loggingIn ? "Signing in…" : "Sign in to Microsoft…", icon: "󰊻" })
    else if (!ms.hasScope("Mail.ReadWrite")) rows.push({ kind: "action", path: "relogin", title: ms.loggingIn ? "Signing in…" : "Sign in again to enable Sticky Notes…", icon: "󰊻" })
    else {
      for (var i = 0; i < root.notes.length; i++)
        rows.push({ kind: "note", path: pathOf(root.notes[i].id), title: "", preview: previewOf(root.notes[i].body), fixed: true, version: root.notes[i].modified || "" })
      rows.push({ kind: "new", path: "new" })
      rows.push({ kind: "action", path: "logout", title: "Sign out" + (ms.account ? " (" + ms.account + ")" : ""), icon: "󰍃" })
    }
    // The sticky-note yellow, which is recognisable where Microsoft's
    // corporate purple is not. "Sticky Notes" because a tab is narrow.
    root.sections = [{ key: "sticky", name: "Sticky Notes", color: "#F5D33F", rows: rows }]
    root.updated()
  }

  function crumb(path) { return "Microsoft Sticky Notes" }
  function createTargetFor(path) { return root.ready ? "new" : "" }
  function restoreState(obj) {}
  function saveState() { return {} }
  function toggleTree(id) {}

  function action(id) {
    if (!ms) return
    if (id === "login") ms.login()
    else if (id === "relogin") ms.relogin()
    else if (id === "logout") ms.logout()
    else if (id === "unavailable") root.noticeRequested("Microsoft sign-in is not configured in this build",
      "This copy of Note Note has no Microsoft app registration built in (CLIENT_ID in services/microsoft/msgraph.py), so nobody can sign in yet.", "", [])
  }

  function refresh() {
    if (!root.ready) { root.notes = []; rebuild(); return }
    listProc.cached = true
    listProc.running = true
  }

  Connections {
    target: root.ms
    function onUpdated() {
      if (!root.ms.signedIn) { root.notes = []; clearProc.running = true }
      root.refresh()
    }
  }

  function load(path, cb) {
    var n = noteAt(path)
    cb(n ? { title: "", body: n.body, editable: true, version: n.modified || "" } : { error: "unknown note" })
  }

  property var saveCb: null
  function save(path, title, body, cb) {
    var n = noteAt(path)
    if (n) n.body = body
    rebuild()
    root.saveCb = cb
    saveProc.command = ["python3", root.script, "update", idOf(path), "-"]
    saveProc.stdinEnabled = true
    saveProc.running = true
    saveProc.write(JSON.stringify({ title: title, body: body }))
    saveProc.stdinEnabled = false          // close stdin: the script reads to EOF
  }

  property var createCb: null
  function create(target, cb) {
    if (!root.ready || createProc.running) { if (cb) cb({ error: "not ready" }); return }
    root.statusRequested("Creating a sticky note…")
    root.createCb = cb
    createProc.running = true
  }

  property var removeCb: null
  function remove(path, cb) {
    root.notes = root.notes.filter(function(n) { return n.id !== idOf(path) })
    rebuild()
    root.removeCb = cb
    deleteProc.command = ["python3", root.script, "delete", idOf(path)]
    deleteProc.running = true
  }

  function setOrder(sectionKey, paths) {}
  // One listing request per poll; nothing else is needed to spot changes.
  function poll() { if (root.ready && !listProc.running) { listProc.cached = false; listProc.running = true } }

  function parse(text) { try { return JSON.parse(text) } catch (e) { return { error: "unexpected reply" } } }

  Process {
    id: listProc
    property bool cached: true
    environment: root.ms ? root.ms.env : ({})
    command: ["python3", root.script, "list"].concat(cached ? ["--cached"] : [])
    stdout: StdioCollector {
      onStreamFinished: {
        var res = root.parse(this.text)
        if (res.error) {
          if (!listProc.cached) root.statusRequested("Sticky Notes: " + res.error)
          if (/not signed in|expired/.test(res.error) && root.ms) root.ms.refresh()
        } else if (Array.isArray(res.notes)) root.notes = res.notes
        root.rebuild()
      }
    }
    onExited: if (cached && root.ready) Qt.callLater(function() { listProc.cached = false; listProc.running = true })
  }
  Process {
    id: saveProc
    environment: root.ms ? root.ms.env : ({})
    stdout: StdioCollector { onStreamFinished: { var cb = root.saveCb; root.saveCb = null; var r = root.parse(this.text); if (cb) cb(r.error ? { error: r.error } : {}) } }
  }
  Process {
    id: createProc
    environment: root.ms ? root.ms.env : ({})
    command: ["python3", root.script, "create"]
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = root.createCb; root.createCb = null
        root.statusRequested("")
        var r = root.parse(this.text)
        if (r.error) { if (cb) cb({ error: r.error }); return }
        root.notes = [r.note].concat(root.notes)
        root.rebuild()
        if (cb) cb({ path: root.pathOf(r.note.id) })
      }
    }
  }
  Process {
    id: deleteProc
    environment: root.ms ? root.ms.env : ({})
    stdout: StdioCollector { onStreamFinished: { var cb = root.removeCb; root.removeCb = null; var r = root.parse(this.text); if (cb) cb(r.error ? { error: r.error } : {}) } }
  }
  Process { id: clearProc; environment: root.ms ? root.ms.env : ({}); command: ["python3", root.script, "clear-cache"] }
}
