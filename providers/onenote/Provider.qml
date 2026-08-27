import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// OneNote: one section holding the whole tree — notebooks → sections →
// pages, expandable in place. Pages are fetched on demand as Markdown
// (onenote.py + onenote_md.py) and written back as OneNote HTML.
Item {
  id: root

  readonly property string id: "onenote"
  readonly property string name: "OneNote"
  readonly property url logo: Qt.resolvedUrl("logo.svg")
  readonly property bool markdown: true
  readonly property bool hasTitle: true
  readonly property bool canCreate: true
  readonly property bool canDelete: true
  readonly property bool canReorder: false
  readonly property bool canCreateSection: false
  // Pages carry their images through an edit, and a pasted one is uploaded
  // with the save (onenote.py).
  readonly property bool canImages: true
  readonly property var microsoftScopes: ["Notes.ReadWrite"]

  property var host: null
  property var services: null
  // This provider's own Microsoft sign-in: own token file, own scope.
  property var ms: null
  Component.onCompleted: { if (services && services.microsoft) root.ms = services.microsoft.create(root.id, root.microsoftScopes) }

  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: dir + "/onenote.py"

  signal updated()
  signal statusRequested(string text)
  signal noticeRequested(string title, string text, string code, var actions)
  signal noticeCleared()
  signal viewRequested(string title, var component, var props)
  signal viewCleared()
  signal persistRequested()
  // Graph does not reliably bump a page's lastModifiedDateTime, so the open
  // page is re-read on poll and reported when its text differs.
  signal noteChanged(string path)

  property var onSections: []    // [{ id, name, notebook, notebookId }]
  property var pages: []         // [{ id, sectionId, title, modified }]
  property var bodies: ({})      // id -> { title, body, editable, originalTitle }
  property var expanded: []      // notebook/section ids the user opened
  property var sections: []
  readonly property bool ready: ms && ms.signedIn && ms.hasScope("Notes.ReadWrite")

  function idOf(path) { return path.substring(root.id.length + 1) }
  function pathOf(id) { return root.id + ":" + id }
  function pageAt(path) {
    var id = idOf(path)
    for (var i = 0; i < root.pages.length; i++) if (root.pages[i].id === id) return root.pages[i]
    return null
  }
  function sectionAt(id) {
    for (var i = 0; i < root.onSections.length; i++) if (root.onSections[i].id === id) return root.onSections[i]
    return null
  }
  function sectionName(id) {
    var s = sectionAt(id)
    return s ? "OneNote › " + (s.notebook ? s.notebook + " › " : "") + s.name : "OneNote"
  }

  function rebuild() {
    var rows = []
    if (!ms || !ms.configured) rows.push({ kind: "action", path: "unavailable", title: "Not available in this build", icon: "󰒓" })
    else if (!ms.signedIn) rows.push({ kind: "action", path: "login", title: ms.loggingIn ? "Signing in…" : "Sign in to Microsoft…", icon: "󰊻" })
    else if (!ms.hasScope("Notes.ReadWrite")) rows.push({ kind: "action", path: "relogin", title: ms.loggingIn ? "Signing in…" : "Sign in again to enable OneNote…", icon: "󰊻" })
    else {
      var books = [], seen = {}
      for (var i = 0; i < root.onSections.length; i++) {
        var s = root.onSections[i]
        if (!seen[s.notebookId]) { seen[s.notebookId] = true; books.push({ id: s.notebookId, name: s.notebook || "Notebook" }) }
      }
      books.sort(function(a, b) { return a.name.localeCompare(b.name) })
      for (var b = 0; b < books.length; b++) {
        var open = root.expanded.indexOf(books[b].id) >= 0
        rows.push({ kind: "tree", path: books[b].id, title: books[b].name, level: 0, expanded: open })
        if (!open) continue
        rows.push({ kind: "action", path: "newsection:" + books[b].id, title: "New section…", icon: "+", level: 1 })
        for (var k = 0; k < root.onSections.length; k++) {
          var sec = root.onSections[k]
          if (sec.notebookId !== books[b].id) continue
          var secOpen = root.expanded.indexOf(sec.id) >= 0
          rows.push({ kind: "tree", path: sec.id, title: sec.name, level: 1, expanded: secOpen })
          if (!secOpen) continue
          for (var p = 0; p < root.pages.length; p++) {
            var pg = root.pages[p]
            if (pg.sectionId !== sec.id) continue
            rows.push({ kind: "note", path: pathOf(pg.id), title: pg.title, preview: "", level: 2, fixed: true, version: pg.modified || "" })
          }
          rows.push({ kind: "new", path: "section:" + sec.id, level: 2 })
        }
      }
      if (books.length === 0) rows.push({ kind: "action", path: "refresh", title: "No notebooks found — refresh", icon: "󰑐" })
      rows.push({ kind: "action", path: "logout", title: "Sign out" + (ms.account ? " (" + ms.account + ")" : ""), icon: "󰍃" })
    }
    // `notes` is every page, fold state ignored: rows only carry the pages of
    // expanded sections, and a search (and the hit count on the tab) must see
    // the closed ones too.
    var all = root.pages.map(function(p) { return { path: pathOf(p.id), title: p.title, preview: "" } })
    root.sections = [{ key: "onenote", name: "OneNote", color: "#7719AA", count: root.pages.length, notes: all, rows: rows }]
    root.updated()
  }

  function crumb(path) { var pg = pageAt(path); return pg ? sectionName(pg.sectionId) : "OneNote" }
  function createTargetFor(path) { var pg = pageAt(path); return pg ? "section:" + pg.sectionId : "" }
  function restoreState(obj) { if (obj && Array.isArray(obj.expanded)) root.expanded = obj.expanded }
  function saveState() { return { expanded: root.expanded } }

  function toggleTree(id) {
    var i = root.expanded.indexOf(id), next = root.expanded.slice()
    if (i >= 0) next.splice(i, 1); else next.push(id)
    root.expanded = next
    rebuild()
    root.persistRequested()
  }

  // A page in a folded section has no row. Revealing one opens its section
  // and its notebook, so the row exists when the host scrolls to it — asked
  // for when a search ends on a page the tree was hiding.
  function revealPath(path) {
    var pg = pageAt(path)
    if (!pg) return
    var sec = sectionAt(pg.sectionId), next = root.expanded.slice()
    if (sec && next.indexOf(sec.notebookId) < 0) next.push(sec.notebookId)
    if (next.indexOf(pg.sectionId) < 0) next.push(pg.sectionId)
    if (next.length === root.expanded.length) return
    root.expanded = next
    rebuild()
    root.persistRequested()
  }

  function action(id) {
    if (!ms) return
    if (id === "login") ms.login()
    else if (id === "relogin") ms.relogin()
    else if (id === "logout") root.noticeRequested("Sign out of OneNote?",
      "You'll need to sign in again" + (ms.account ? " as " + ms.account : "") + " to keep using OneNote.", "",
      [{ label: "Sign out", action: function() { root.noticeCleared(); ms.logout() } },
       { label: "Cancel", action: function() { root.noticeCleared() } }])
    else if (id === "refresh") { listProc.cached = false; listProc.force = true; listProc.running = true }
    else if (id.indexOf("newsection:") === 0) {
      root.newSectionNotebook = id.substring(11)
      root.newSectionError = ""
      root.viewRequested("New section in " + notebookName(root.newSectionNotebook), sectionView, {})
    }
    else if (id === "unavailable") root.noticeRequested("Microsoft sign-in is not configured in this build",
      "This copy of Note Note has no Microsoft app registration built in (CLIENT_ID in services/microsoft/msgraph.py), so nobody can sign in yet.", "", [])
  }

  function notebookName(id) {
    for (var i = 0; i < root.onSections.length; i++)
      if (root.onSections[i].notebookId === id) return root.onSections[i].notebook || "OneNote"
    return "OneNote"
  }

  // ── new section ─────────────────────────────────────────────────────
  property string newSectionNotebook: ""
  property string newSectionError: ""
  property bool newSectionBusy: false
  function createSection(name) {
    var n = name.trim()
    if (!n) { root.newSectionError = "A section needs a name."; return }
    if (sectionProc.running) return
    root.newSectionBusy = true
    root.newSectionError = ""
    sectionProc.command = ["python3", root.script, "create-section", root.newSectionNotebook, "-"]
    sectionProc.stdinEnabled = true
    sectionProc.running = true
    sectionProc.write(JSON.stringify({ name: n }))
    sectionProc.stdinEnabled = false          // close stdin: the script reads to EOF
  }

  Component {
    id: sectionView
    FocusScope {
      width: parent ? parent.width : Style.space(600)
      height: column.implicitHeight
      Column {
        id: column
        spacing: Style.spacing.md
        leftPadding: Style.spacing.md
        topPadding: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          width: Style.space(520)
          wrapMode: Text.Wrap
          text: "The section is created in OneNote and appears in the tree; pages you add go into it."
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }
        TextField {
          id: nameField
          width: Style.space(320)
          placeholderText: "Section name"
          foreground: Color.menu.text
          accent: Color.accent
          font.family: Style.font.menuFamily
          focus: true
          Keys.onReturnPressed: root.createSection(text)
        }
        Text {
          textFormat: Text.PlainText
          visible: root.newSectionError.length > 0
          text: root.newSectionError
          color: Color.urgent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
        }
        Row {
          spacing: Style.spacing.sm
          Button {
            text: root.newSectionBusy ? "Creating…" : "Create"
            iconText: "+"
            bordered: true
            enabled: !root.newSectionBusy
            foreground: Color.menu.text
            accent: Color.accent
            onClicked: root.createSection(nameField.text)
          }
          Button {
            text: "Cancel"
            bordered: true
            foreground: Color.menu.text
            accent: Color.accent
            onClicked: root.viewCleared()
          }
        }
      }
    }
  }

  Process {
    id: sectionProc
    environment: root.ms ? root.ms.env : ({})
    stdout: StdioCollector {
      onStreamFinished: {
        root.newSectionBusy = false
        var r = root.parse(this.text)
        if (r.error) { root.newSectionError = r.error; return }
        var sct = r.section
        if (!sct.notebook) sct.notebook = root.notebookName(sct.notebookId)
        root.onSections = root.onSections.concat([sct])
        var exp = root.expanded.slice()
        if (exp.indexOf(sct.notebookId) < 0) exp.push(sct.notebookId)
        if (exp.indexOf(sct.id) < 0) exp.push(sct.id)
        root.expanded = exp
        root.viewCleared()
        root.rebuild()
        root.persistRequested()
        root.statusRequested("Section created")
      }
    }
  }

  function refresh() {
    if (!root.ready) { root.onSections = []; root.pages = []; rebuild(); return }
    listProc.cached = true
    listProc.running = true
  }

  // No `search()` here, deliberately: Microsoft Graph's OneNote pages
  // endpoint has no content-search parameter at all — `search=` and
  // `$search=` both come back 400 "unsupported OData query parameters" for
  // every account type, verified against a live personal account (the one
  // case older docs implied it might work for). The endpoint's own
  // documented query options are filter/orderby/select/expand/top/skip/
  // count/pagelevel, search among them nowhere. Titles are already in the
  // listing, where the host matches them itself — the same shape as Notion.

  Connections {
    target: root.ms
    function onUpdated() {
      if (!root.ms.signedIn) { root.onSections = []; root.pages = []; root.bodies = ({}); clearProc.running = true }
      root.refresh()
    }
  }

  // ── pages ───────────────────────────────────────────────────────────
  property var loadQueue: ({})   // path -> cb
  function load(path, cb) {
    var id = idOf(path), cached = root.bodies[id], pg = pageAt(path)
    // A cached body is only good while the page's modified time matches.
    if (cached && (!pg || cached.version === (pg.modified || ""))) { cb({ title: cached.title, body: cached.body, editable: cached.editable, version: cached.version || "" }); return }
    root.loadQueue[path] = cb
    if (pageProc.running) return
    pageProc.path = path
    pageProc.command = ["python3", root.script, "page", id]
    pageProc.running = true
  }

  property var saveCb: null
  function save(path, title, body, cb) {
    var id = idOf(path), b = root.bodies
    var original = b[id] && b[id].originalTitle !== undefined ? b[id].originalTitle : title
    b[id] = { title: title, body: body, editable: true, originalTitle: original, version: "" }
    root.bodies = b
    var pgs = root.pages.slice()
    for (var i = 0; i < pgs.length; i++) if (pgs[i].id === id) pgs[i] = { id: id, sectionId: pgs[i].sectionId, title: title, modified: pgs[i].modified }
    root.pages = pgs
    rebuild()
    root.saveCb = cb
    saveProc.path = path
    saveProc.command = ["python3", root.script, "update", id, "-"]
    saveProc.stdinEnabled = true
    saveProc.running = true
    saveProc.write(JSON.stringify({ title: title, originalTitle: original, body: body }))
    saveProc.stdinEnabled = false          // close stdin: the script reads to EOF
  }

  property var createCb: null
  function create(target, cb) {
    if (!root.ready || createProc.running || target.indexOf("section:") !== 0) { if (cb) cb({ error: "not ready" }); return }
    root.statusRequested("Creating a OneNote page…")
    root.createCb = cb
    createProc.command = ["python3", root.script, "create", target.substring(8), "-"]
    createProc.stdinEnabled = true
    createProc.running = true
    createProc.write(JSON.stringify({ title: "", body: "" }))
    createProc.stdinEnabled = false          // close stdin: the script reads to EOF
  }

  property var removeCb: null
  function remove(path, cb) {
    root.pages = root.pages.filter(function(p) { return p.id !== idOf(path) })
    rebuild()
    root.removeCb = cb
    deleteProc.command = ["python3", root.script, "delete", idOf(path)]
    deleteProc.running = true
  }

  function setOrder(sectionKey, paths) {}

  // Polling: every minute, re-list only the sections the user has open —
  // one small request each; the account-wide listing stays on its cache.
  property int pollTick: 0
  function poll(currentPath) {
    if (!root.ready) return
    root.pollTick++
    if (root.pollTick % 3 !== 0) return
    if (currentPath && currentPath.indexOf(root.id + ":") === 0 && !checkProc.running && !pageProc.running) {
      checkProc.path = currentPath
      checkProc.command = ["python3", root.script, "page", idOf(currentPath)]
      checkProc.running = true
    }
    if (pagesProc.running) return
    var open = root.onSections.filter(function(s) { return root.expanded.indexOf(s.id) >= 0 }).map(function(s) { return s.id })
    if (open.length === 0) return
    pagesProc.command = ["python3", root.script, "pages"].concat(open.slice(0, 10))
    pagesProc.running = true
  }
  Process {
    id: checkProc
    property string path: ""
    environment: root.ms ? root.ms.env : ({})
    stdout: StdioCollector {
      onStreamFinished: {
        var r = root.parse(this.text)
        if (r.error) return
        var id = root.idOf(checkProc.path), old = root.bodies[id]
        if (old && old.body === (r.body || "") && old.title === (r.title || old.title)) return
        var pg = root.pageAt(checkProc.path)
        var b = root.bodies
        b[id] = { title: r.title || (pg ? pg.title : ""), body: r.body || "", editable: r.editable === true,
                  originalTitle: r.title || (pg ? pg.title : ""), version: pg ? pg.modified || "" : "" }
        root.bodies = b
        root.noteChanged(checkProc.path)
      }
    }
  }
  Process {
    id: pagesProc
    environment: root.ms ? root.ms.env : ({})
    stdout: StdioCollector {
      onStreamFinished: {
        var r = root.parse(this.text)
        if (r.error || !Array.isArray(r.pages)) return
        var ids = {}; r.sections.forEach(function(id) { ids[id] = true })
        var merged = root.pages.filter(function(p) { return !ids[p.sectionId] }).concat(r.pages)
        if (JSON.stringify(merged) !== JSON.stringify(root.pages)) { root.pages = merged; root.rebuild() }
      }
    }
  }
  function parse(text) { try { return JSON.parse(text) } catch (e) { return { error: "unexpected reply" } } }

  // A full listing is ~40 Graph calls; do it at most every ten minutes unless
  // asked (the "refresh" row), and show the cache meanwhile.
  Process {
    id: listProc
    property bool cached: true
    property bool force: false
    environment: root.ms ? root.ms.env : ({})
    command: ["python3", root.script, "list"].concat(cached ? ["--cached"] : (force ? [] : ["--max-age", "600"]))
    stdout: StdioCollector {
      onStreamFinished: {
        var res = root.parse(this.text)
        if (res.error) { if (!listProc.cached) root.statusRequested("OneNote: " + res.error) }
        else {
          if (Array.isArray(res.sections)) root.onSections = res.sections
          if (Array.isArray(res.pages)) root.pages = res.pages
        }
        root.rebuild()
      }
    }
    onExited: {
      if (cached && root.ready) Qt.callLater(function() { listProc.cached = false; listProc.force = false; listProc.running = true })
      else listProc.force = false
    }
  }
  Process {
    id: pageProc
    environment: root.ms ? root.ms.env : ({})
    property string path: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var path = pageProc.path, cb = root.loadQueue[path]
        delete root.loadQueue[path]
        var r = root.parse(this.text)
        if (!r.error) {
          var pg = root.pageAt(path), title = r.title || (pg ? pg.title : "")
          var ver = pg ? pg.modified || "" : ""
          var b = root.bodies; b[root.idOf(path)] = { title: title, body: r.body || "", editable: r.editable === true, originalTitle: title, version: ver }; root.bodies = b
          if (cb) cb({ title: title, body: r.body || "", editable: r.editable === true, version: ver })
        } else if (cb) cb({ error: r.error })
      }
    }
    onExited: {
      // serve whatever was requested while this one ran
      for (var next in root.loadQueue) { var cb = root.loadQueue[next]; delete root.loadQueue[next]; Qt.callLater(function() { root.load(next, cb) }); break }
    }
  }
  Process {
    id: saveProc
    environment: root.ms ? root.ms.env : ({})
    property string path: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = root.saveCb; root.saveCb = null
        var r = root.parse(this.text)
        if (r.error) { if (cb) cb({ error: r.error }); return }
        var b = root.bodies, k = root.idOf(saveProc.path)
        if (!r.warning && b[k]) { b[k].originalTitle = b[k].title; root.bodies = b }
        if (cb) cb(r.warning ? { warning: r.warning } : {})
      }
    }
  }
  Process {
    id: createProc
    environment: root.ms ? root.ms.env : ({})
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = root.createCb; root.createCb = null
        root.statusRequested("")
        var r = root.parse(this.text)
        if (r.error) { if (cb) cb({ error: r.error }); return }
        root.pages = [r.page].concat(root.pages)
        var b = root.bodies; b[r.page.id] = { title: "", body: "", editable: true, originalTitle: "" }; root.bodies = b
        var sec = root.sectionAt(r.page.sectionId), exp = root.expanded.slice()
        if (sec && exp.indexOf(sec.notebookId) < 0) exp.push(sec.notebookId)
        if (exp.indexOf(r.page.sectionId) < 0) exp.push(r.page.sectionId)
        root.expanded = exp
        root.rebuild()
        root.persistRequested()
        if (cb) cb({ path: root.pathOf(r.page.id) })
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
