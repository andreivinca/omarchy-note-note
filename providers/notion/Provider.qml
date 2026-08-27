import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// Notion: the pages shared with an internal integration, through the
// official API (notion.py). Setup is a pasted integration secret, stored by
// the provider itself; blocks are shown and edited as Markdown.
Item {
  id: root

  readonly property string id: "notion"
  readonly property string name: "Notion"
  readonly property url logo: Qt.resolvedUrl("logo.svg")
  readonly property bool markdown: true
  readonly property bool hasTitle: true
  readonly property bool canCreate: true
  readonly property bool canDelete: true
  readonly property bool canReorder: false
  readonly property bool canCreateSection: false
  readonly property var microsoftScopes: []
  // Formatting tools this provider can store (see PROVIDERS.md). No table:
  // Notion tables are not representable as Markdown tables here.
  readonly property var tools: ["bold", "italic", "underline", "strikeout", "highlight", "code",
                                "h1", "h2", "h3", "p", "ul", "ol", "todo", "indent", "outdent",
                                "quote", "codeblock", "rule", "link"]

  property var host: null
  property var services: null

  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: dir + "/notion.py"

  signal updated()
  signal statusRequested(string text)
  signal noticeRequested(string title, string text, string code, var actions)
  signal noticeCleared()
  signal viewRequested(string title, var component, var props)
  signal viewCleared()
  signal persistRequested()

  property bool configured: false
  property string workspace: ""
  property var pages: []          // [{ id, title, parent, edited }]
  property var bodies: ({})       // id -> { title, body, editable }
  property var sections: []

  function idOf(path) { return path.substring(root.id.length + 1) }
  function pathOf(id) { return root.id + ":" + id }
  function pageAt(path) {
    var id = idOf(path)
    for (var i = 0; i < root.pages.length; i++) if (root.pages[i].id === id) return root.pages[i]
    return null
  }

  function rebuild() {
    var rows = []
    if (!root.configured) rows.push({ kind: "action", path: "setup", title: "Set up…", icon: "󰒓" })
    else {
      for (var i = 0; i < root.pages.length; i++)
        rows.push({ kind: "note", path: pathOf(root.pages[i].id), title: root.pages[i].title, preview: "", fixed: true, version: root.pages[i].edited || "" })
      rows.push({ kind: "new", path: "new" })
      rows.push({ kind: "action", path: "refresh", title: "Refresh", icon: "󰑐" })
      rows.push({ kind: "action", path: "settings", title: "Settings…" + (root.workspace ? " (" + root.workspace + ")" : ""), icon: "󰒓" })
    }
    // Notion is black and white, which has no hue to soften; a warm
    // neutral is the honest answer.
    root.sections = [{ key: "notion", name: "Notion", color: "#B8B0A8", rows: rows }]
    root.updated()
  }

  // No `search()` here, deliberately: the public API's search endpoint
  // matches page *titles* only (developers.notion.com/reference/post-search —
  // the page is titled "Search by title"), so the only way to search content
  // would be fetching every page's blocks on every query. The titles are
  // already in the listing, where the host matches them itself.
  function crumb(path) { return root.workspace ? "Notion › " + root.workspace : "Notion" }
  // New pages go under the page you are on; otherwise under the first page
  // (the API cannot create top-level pages).
  function createTargetFor(path) {
    var pg = pageAt(path)
    if (pg) return "parent:" + pg.id
    return root.pages.length ? "parent:" + root.pages[0].id : ""
  }
  function restoreState(obj) {}
  function saveState() { return {} }
  function toggleTree(id) {}
  function setOrder(sectionKey, paths) {}
  // One search request per minute while open.
  property int pollTick: 0
  function poll() {
    if (!root.configured) return
    root.pollTick++
    if (root.pollTick % 3 !== 0 || listProc.running) return
    listProc.cached = false; listProc.force = true; listProc.running = true
  }

  function action(id) {
    if (id === "setup" || id === "settings") root.viewRequested(root.configured ? "Notion — settings" : "Set up Notion", setupView, {})
    else if (id === "refresh") { listProc.cached = false; listProc.force = true; listProc.running = true }
  }

  function refresh() { statusProc.running = true }

  // ── notes ───────────────────────────────────────────────────────────
  property var loadQueue: ({})
  function load(path, cb) {
    var id = idOf(path), cached = root.bodies[id], pg = pageAt(path)
    if (cached && (!pg || cached.version === (pg.edited || ""))) { cb({ title: cached.title, body: cached.body, editable: cached.editable, version: cached.version || "" }); return }
    root.loadQueue[path] = cb
    if (pageProc.running) return
    pageProc.path = path
    pageProc.command = ["python3", root.script, "page", id]
    pageProc.running = true
  }

  property var saveCb: null
  function save(path, title, body, cb) {
    var id = idOf(path), b = root.bodies
    b[id] = { title: title, body: body, editable: true, version: "" }
    root.bodies = b
    var pgs = root.pages.slice()
    for (var i = 0; i < pgs.length; i++) if (pgs[i].id === id) pgs[i] = { id: id, title: title, parent: pgs[i].parent, edited: pgs[i].edited }
    root.pages = pgs
    rebuild()
    root.saveCb = cb
    saveProc.command = ["python3", root.script, "update", id, "-"]
    saveProc.stdinEnabled = true
    saveProc.running = true
    saveProc.write(JSON.stringify({ title: title, body: body }))
    saveProc.stdinEnabled = false          // close stdin: the script reads to EOF
  }

  property var createCb: null
  function create(target, cb) {
    if (!root.configured || createProc.running) { if (cb) cb({ error: "not ready" }); return }
    var parent = target === "new" ? (root.pages.length ? root.pages[0].id : "") : (target.indexOf("parent:") === 0 ? target.substring(7) : "")
    if (!parent) { if (cb) cb({ error: "share at least one page with the integration first — new pages need a parent" }); return }
    root.statusRequested("Creating a Notion page…")
    root.createCb = cb
    createProc.command = ["python3", root.script, "create", parent, "-"]
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

  function parse(text) { try { return JSON.parse(text) } catch (e) { return { error: "unexpected reply" } } }

  // ── processes ───────────────────────────────────────────────────────
  Process {
    id: statusProc
    command: ["python3", root.script, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        var st = root.parse(this.text)
        root.configured = st.configured === true
        root.workspace = st.workspace || ""
        if (!root.configured) { root.pages = []; root.bodies = ({}); rebuild(); return }
        listProc.cached = true
        listProc.running = true
      }
    }
  }
  Process {
    id: listProc
    property bool cached: true
    property bool force: false
    command: ["python3", root.script, "list"].concat(cached ? ["--cached"] : (force ? [] : ["--max-age", "300"]))
    stdout: StdioCollector {
      onStreamFinished: {
        var res = root.parse(this.text)
        if (res.error) { if (!listProc.cached) root.statusRequested("Notion: " + res.error) }
        else if (Array.isArray(res.pages)) root.pages = res.pages
        root.rebuild()
      }
    }
    onExited: {
      if (cached && root.configured) Qt.callLater(function() { listProc.cached = false; listProc.force = false; listProc.running = true })
      else listProc.force = false
    }
  }
  Process {
    id: pageProc
    property string path: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var path = pageProc.path, cb = root.loadQueue[path]
        delete root.loadQueue[path]
        var r = root.parse(this.text)
        if (!r.error) {
          var pg = root.pageAt(path), ver = pg ? pg.edited || "" : ""
          var b = root.bodies; b[root.idOf(path)] = { title: r.title || "", body: r.body || "", editable: r.editable === true, version: ver }; root.bodies = b
          if (cb) cb({ title: r.title || "", body: r.body || "", editable: r.editable === true, version: ver })
        } else if (cb) cb({ error: r.error })
      }
    }
    onExited: { for (var next in root.loadQueue) { var cb = root.loadQueue[next]; delete root.loadQueue[next]; Qt.callLater(function() { root.load(next, cb) }); break } }
  }
  Process {
    id: saveProc
    stdout: StdioCollector { onStreamFinished: { var cb = root.saveCb; root.saveCb = null; var r = root.parse(this.text); if (cb) cb(r.error ? { error: r.error } : {}) } }
  }
  Process {
    id: createProc
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = root.createCb; root.createCb = null
        root.statusRequested("")
        var r = root.parse(this.text)
        if (r.error) { if (cb) cb({ error: r.error }); return }
        root.pages = [r.page].concat(root.pages)
        var b = root.bodies; b[r.page.id] = { title: "", body: "", editable: true }; root.bodies = b
        root.rebuild()
        if (cb) cb({ path: root.pathOf(r.page.id) })
      }
    }
  }
  Process {
    id: deleteProc
    stdout: StdioCollector { onStreamFinished: { var cb = root.removeCb; root.removeCb = null; var r = root.parse(this.text); if (cb) cb(r.error ? { error: r.error } : {}) } }
  }
  Process {
    id: setupProc
    stdout: StdioCollector {
      onStreamFinished: {
        var r = root.parse(this.text)
        root.setupBusy = false
        if (r.error) { root.setupError = r.error; return }
        root.setupError = ""
        root.viewCleared()
        root.refresh()
      }
    }
  }
  Process { id: logoutProc; command: ["python3", root.script, "logout"]; onExited: { root.bodies = ({}); root.refresh() } }

  // ── setup: the provider's own screen ────────────────────────────────
  property bool setupBusy: false
  property string setupError: ""
  function submitToken(token) {
    var t = token.trim()
    if (!t) { root.setupError = "Paste the integration secret."; return }
    root.setupBusy = true
    root.setupError = ""
    setupProc.command = ["python3", root.script, "setup", "-"]
    setupProc.stdinEnabled = true
    setupProc.running = true
    setupProc.write(JSON.stringify({ token: t }))
    setupProc.stdinEnabled = false          // close stdin: the script reads to EOF
  }

  Component {
    id: setupView
    FocusScope {
      id: view
      property bool confirmingRemove: false
      width: parent ? parent.width : Style.space(600)
      height: column.implicitHeight

      Column {
        id: column
        spacing: Style.spacing.md
        leftPadding: Style.spacing.md
        topPadding: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          width: Style.space(560)
          wrapMode: Text.Wrap
          lineHeight: 1.25
          text: "Note Note talks to Notion through an integration of your own:\n\n"
              + "1. Open notion.so/profile/integrations and create an internal integration for your workspace (any name, read + update + insert content).\n"
              + "2. Copy its Internal Integration Secret and paste it below.\n"
              + "3. In Notion, open each page you want here → ··· → Connections → add the integration. Sub-pages come along.\n\n"
              + "The secret is stored only on this machine, readable by you alone."
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }
        TextField {
          id: tokenField
          width: Style.space(420)
          placeholderText: "ntn_… or secret_…"
          password: true
          foreground: Color.menu.text
          accent: Color.accent
          font.family: Style.font.menuFamily
          focus: true
          Keys.onReturnPressed: root.submitToken(text)
        }
        Text {
          textFormat: Text.PlainText
          visible: root.setupError.length > 0
          text: root.setupError
          color: Color.urgent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
        }
        Row {
          spacing: Style.spacing.sm
          Button {
            text: root.setupBusy ? "Checking…" : "Save"
            iconText: "󰆓"
            bordered: true
            enabled: !root.setupBusy
            foreground: Color.menu.text
            accent: Color.accent
            onClicked: root.submitToken(tokenField.text)
          }
          Button {
            text: "Cancel"
            bordered: true
            foreground: Color.menu.text
            accent: Color.accent
            onClicked: root.viewCleared()
          }
          Button {
            visible: root.configured && !view.confirmingRemove
            text: "Remove integration"
            iconText: "󰍃"
            bordered: true
            foreground: Color.menu.text
            accent: Color.accent
            onClicked: view.confirmingRemove = true
          }
          Button {
            visible: root.configured && view.confirmingRemove
            text: "Really remove it?"
            bordered: true
            foreground: Color.urgent
            accent: Color.accent
            onClicked: { root.viewCleared(); logoutProc.running = true }
          }
          Button {
            visible: root.configured && view.confirmingRemove
            text: "Keep it"
            bordered: true
            foreground: Color.menu.text
            accent: Color.accent
            onClicked: view.confirmingRemove = false
          }
        }
      }
    }
  }
}
