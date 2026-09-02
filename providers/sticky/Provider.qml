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
  // This provider's own app registration: an Entra public client for
  // personal and work accounts, registered by the author, that every user
  // of Sticky Notes here signs in through. OneNote has one of its own.
  readonly property string microsoftClientId: "867770a1-477d-4864-9e09-8e3019ca336c"

  property var host: null
  property var services: null
  // This provider's own Microsoft sign-in: own registration, own token file,
  // own scope.
  property var ms: null
  // And its own request lane. Mail's limits are far above OneNote's, so this
  // lane exists mostly to keep sticky notes moving *while* OneNote is parked:
  // separate keys, separate cooldowns (providers/PROVIDERS.md).
  property var rq: null
  Component.onCompleted: {
    if (services && services.microsoft) root.ms = services.microsoft.create(root.id, root.microsoftScopes, root.microsoftClientId)
    if (services && services.requests) root.rq = services.requests.queueFor("graph-mail", root)
  }
  Component.onDestruction: { if (services && services.requests) services.requests.cancelOwner(root) }

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
    else if (!ms.signedIn) rows.push({ kind: "action", path: "login", title: ms.loggingIn ? "Cancel signing in…" : "Sign in to Microsoft…", icon: ms.loggingIn ? "󰅖" : "󰊻" })
    else if (!ms.hasScope("Mail.ReadWrite")) rows.push({ kind: "action", path: "relogin", title: ms.loggingIn ? "Cancel signing in…" : "Sign in again to enable Sticky Notes…", icon: ms.loggingIn ? "󰅖" : "󰊻" })
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
    if (id === "login") { if (ms.loggingIn) { ms.cancelLogin(); root.noticeCleared() } else ms.login() }
    else if (id === "relogin") { if (ms.loggingIn) { ms.cancelLogin(); root.noticeCleared() } else ms.relogin() }
    else if (id === "logout") root.noticeRequested("Sign out of Sticky Notes?",
      "You'll need to sign in again" + (ms.account ? " as " + ms.account : "") + " to keep using Sticky Notes.", "",
      [{ label: "Sign out", action: function() { root.noticeCleared(); ms.logout() } },
       { label: "Cancel", action: function() { root.noticeCleared() } }])
    else if (id === "unavailable") root.noticeRequested("Microsoft sign-in is not configured in this build",
      "This copy of Note Note has no app registration for Sticky Notes built in (microsoftClientId in providers/sticky/Provider.qml), so nobody can sign in yet.", "", [])
  }

  function refresh() {
    if (!root.ready) { root.notes = []; rebuild(); return }
    cachedProc.running = true       // a local file: instant, and never queued
    root.listNotes()
  }

  // One listing request, deduped: open() and the account's own updated()
  // both ask, and one request answers both.
  function listNotes() {
    if (!root.rq || !root.ready) return
    root.rq.enqueue({ key: "list", mode: "dedupe", priority: 1, owner: root, label: "listing" },
      function(ctx) { root.runScript(["list"], "", ctx) },
      function(r) {
        if (!r) return
        if (r.error) {
          root.statusRequested("Sticky Notes: " + r.error)
          if (/not signed in|expired/.test(r.error) && root.ms) root.ms.refresh()
        } else if (Array.isArray(r.notes)) root.notes = r.notes
        root.rebuild()
      })
  }

  // Content search, answered from memory: the listing already carries every
  // note's whole body (a sticky note is small), so nothing is fetched. The
  // host matches the first line itself (the row's preview); this adds the
  // lines below it.
  function search(query, cb) {
    var q = query.toLowerCase(), paths = []
    for (var i = 0; i < root.notes.length; i++)
      if ((root.notes[i].body || "").toLowerCase().indexOf(q) >= 0) paths.push(pathOf(root.notes[i].id))
    cb({ paths: paths })
  }

  Connections {
    target: root.ms
    function onUpdated() {
      if (!root.ms.signedIn) {
        root.notes = []; clearProc.running = true
        if (services && services.requests) services.requests.cancelOwner(root)
      }
      root.refresh()
    }
  }

  function load(path, cb) {
    var n = noteAt(path)
    cb(n ? { title: "", body: n.body, editable: true, version: n.modified || "" } : { error: "unknown note" })
  }

  function save(path, title, body, cb) {
    var n = noteAt(path)
    if (n) n.body = body
    rebuild()
    if (!root.rq) { if (cb) cb({ error: "not ready" }); return }
    var id = idOf(path), payload = JSON.stringify({ title: title, body: body })
    // A note's save and delete share one key, so they can never overlap; a
    // newer save replaces a queued older one, and flush keeps it draining
    // after the window closes.
    root.rq.enqueue({ key: "note:" + id, mode: "replace", priority: 0, owner: root, flush: true, label: "save" },
      function(ctx) { root.runScript(["update", id, "-"], payload, ctx) },
      function(r) {
        if (!r) { if (cb) cb({}); return }     // superseded: the newer save answers
        if (cb) cb(r.error ? { error: r.error } : {})
      })
  }

  function create(target, cb) {
    if (!root.ready || !root.rq) { if (cb) cb({ error: "not ready" }); return }
    root.statusRequested("Creating a sticky note…")
    root.rq.enqueue({ key: "create", mode: "append", priority: 0, owner: root, flush: true, label: "new note" },
      function(ctx) { root.runScript(["create"], "", ctx) },
      function(r) {
        root.statusRequested("")
        if (!r) { if (cb) cb({ error: "the window closed before the note was made" }); return }
        if (r.error) { if (cb) cb({ error: r.error }); return }
        root.notes = [r.note].concat(root.notes)
        root.rebuild()
        if (cb) cb({ path: root.pathOf(r.note.id) })
      })
  }

  function remove(path, cb) {
    var id = idOf(path)
    root.notes = root.notes.filter(function(n) { return n.id !== id })
    rebuild()
    if (!root.rq) { if (cb) cb({ error: "not ready" }); return }
    root.rq.enqueue({ key: "note:" + id, mode: "replace", priority: 0, owner: root, flush: true, label: "delete" },
      function(ctx) { root.runScript(["delete", id], "", ctx) },
      function(r) { if (cb) cb(r && r.error ? { error: r.error } : {}) })
  }

  function setOrder(sectionKey, paths) {}
  // One listing request per poll; nothing else is needed to spot changes.
  function poll() { root.listNotes() }

  function parse(text) { try { return JSON.parse(text) } catch (e) { return { error: "unexpected reply" } } }

  // One process per job, so its callback travels with it (the same shape as
  // providers/onenote/Provider.qml).
  Component {
    id: jobProcess
    Process {
      id: proc
      property var ctx: null
      environment: root.ms ? root.ms.env : ({})
      stdout: StdioCollector {
        onStreamFinished: {
          var answer = proc.ctx
          proc.ctx = null
          if (answer) answer.done(root.parse(this.text))
          Qt.callLater(function() { proc.destroy() })
        }
      }
      onExited: {
        if (!proc.ctx) return
        var answer = proc.ctx
        proc.ctx = null
        answer.done({ error: "unexpected reply" })
        Qt.callLater(function() { proc.destroy() })
      }
    }
  }

  function runScript(args, payload, ctx) {
    var proc = jobProcess.createObject(root, { ctx: ctx })
    if (!proc) { ctx.done({ error: "could not start sticky.py" }); return }
    proc.command = ["python3", root.script].concat(args)
    if (payload) {
      proc.stdinEnabled = true               // stdin must be open before it starts
      proc.running = true
      proc.write(payload)                    // the note goes over stdin, never argv
      proc.stdinEnabled = false              // close stdin: the script reads to EOF
    } else {
      proc.running = true
    }
  }

  Process {
    id: cachedProc
    environment: root.ms ? root.ms.env : ({})
    command: ["python3", root.script, "list", "--cached"]
    stdout: StdioCollector {
      onStreamFinished: {
        var res = root.parse(this.text)
        if (!res.error && Array.isArray(res.notes)) root.notes = res.notes
        root.rebuild()
      }
    }
  }
  Process { id: clearProc; environment: root.ms ? root.ms.env : ({}); command: ["python3", root.script, "clear-cache"] }
}
