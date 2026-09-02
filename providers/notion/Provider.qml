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
  // This provider's own request lane, keyed to Notion's own limit — a
  // Microsoft throttle has nothing to do with it (providers/PROVIDERS.md).
  property var rq: null
  Component.onCompleted: { if (services && services.requests) root.rq = services.requests.queueFor("notion", root) }
  Component.onDestruction: { if (services && services.requests) services.requests.cancelOwner(root) }

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
    if (root.pollTick % 3 !== 0) return
    root.listPages(true)
  }

  function action(id) {
    if (id === "setup" || id === "settings") root.viewRequested(root.configured ? "Notion — settings" : "Set up Notion", setupView, {})
    else if (id === "refresh") root.listPages(true)
  }

  function refresh() { statusProc.running = true }

  // The listing. Deduped, so the poll and an open() collapse into one; a
  // Refresh replaces a queued one so the user's explicit ask is the one sent.
  function listPages(force) {
    if (!root.rq || !root.configured) return
    root.rq.enqueue({ key: "list", mode: force ? "replace" : "dedupe", priority: 1, owner: root, label: "listing" },
      function(ctx) { root.runScript(["list"].concat(force ? [] : ["--max-age", "300"]), "", ctx) },
      function(r) {
        if (!r) return
        if (r.error) root.statusRequested("Notion: " + r.error)
        else if (Array.isArray(r.pages)) root.pages = r.pages
        root.rebuild()
      })
  }

  // ── notes ───────────────────────────────────────────────────────────
  function load(path, cb) {
    var id = idOf(path), cached = root.bodies[id], pg = pageAt(path)
    if (cached && (!pg || cached.version === (pg.edited || ""))) { cb({ title: cached.title, body: cached.body, editable: cached.editable, version: cached.version || "" }); return }
    if (!root.rq) { cb({ error: "not ready" }); return }
    // The handle goes back to the caller: the host withdraws the load of a
    // note the user has stepped past, so the one they stopped on is not
    // stuck queueing behind it.
    return root.rq.enqueue({ key: "load:" + path, mode: "dedupe", priority: 0, owner: root, label: "page" },
      function(ctx) { root.runScript(["page", id], "", ctx) },
      function(r) {
        if (!r) { if (cb) cb({ error: "not loaded — the window closed" }); return }
        if (r.error) { if (cb) cb({ error: r.error }); return }
        var pg2 = root.pageAt(path), ver = pg2 ? pg2.edited || "" : ""
        var b = root.bodies
        b[root.idOf(path)] = { title: r.title || "", body: r.body || "", editable: r.editable === true, version: ver }
        root.bodies = b
        if (cb) cb({ title: r.title || "", body: r.body || "", editable: r.editable === true, version: ver })
      })
  }

  function save(path, title, body, cb) {
    var id = idOf(path), b = root.bodies
    b[id] = { title: title, body: body, editable: true, version: "" }
    root.bodies = b
    var pgs = root.pages.slice()
    for (var i = 0; i < pgs.length; i++) if (pgs[i].id === id) pgs[i] = { id: id, title: title, parent: pgs[i].parent, edited: pgs[i].edited }
    root.pages = pgs
    rebuild()
    if (!root.rq) { if (cb) cb({ error: "not ready" }); return }
    var payload = JSON.stringify({ title: title, body: body })
    root.rq.enqueue({ key: "page:" + id, mode: "replace", priority: 0, owner: root, flush: true, label: "save" },
      function(ctx) { root.runScript(["update", id, "-"], payload, ctx) },
      function(r) {
        if (!r) { if (cb) cb({}); return }     // superseded: the newer save answers
        if (cb) cb(r.error ? { error: r.error } : {})
      })
  }

  function create(target, cb) {
    if (!root.configured || !root.rq) { if (cb) cb({ error: "not ready" }); return }
    var parent = target === "new" ? (root.pages.length ? root.pages[0].id : "") : (target.indexOf("parent:") === 0 ? target.substring(7) : "")
    if (!parent) { if (cb) cb({ error: "share at least one page with the integration first — new pages need a parent" }); return }
    root.statusRequested("Creating a Notion page…")
    root.rq.enqueue({ key: "create:" + parent, mode: "append", priority: 0, owner: root, flush: true, label: "new page" },
      function(ctx) { root.runScript(["create", parent, "-"], JSON.stringify({ title: "", body: "" }), ctx) },
      function(r) {
        root.statusRequested("")
        if (!r) { if (cb) cb({ error: "the window closed before the page was made" }); return }
        if (r.error) { if (cb) cb({ error: r.error }); return }
        root.pages = [r.page].concat(root.pages)
        var b = root.bodies; b[r.page.id] = { title: "", body: "", editable: true }; root.bodies = b
        root.rebuild()
        if (cb) cb({ path: root.pathOf(r.page.id) })
      })
  }

  function remove(path, cb) {
    var id = idOf(path)
    root.pages = root.pages.filter(function(p) { return p.id !== id })
    rebuild()
    if (!root.rq) { if (cb) cb({ error: "not ready" }); return }
    root.rq.enqueue({ key: "page:" + id, mode: "replace", priority: 0, owner: root, flush: true, label: "delete" },
      function(ctx) { root.runScript(["delete", id], "", ctx) },
      function(r) { if (cb) cb(r && r.error ? { error: r.error } : {}) })
  }

  function parse(text) { try { return JSON.parse(text) } catch (e) { return { error: "unexpected reply" } } }

  // One process per job, so its callback travels with it (the same shape as
  // providers/onenote/Provider.qml).
  Component {
    id: jobProcess
    Process {
      id: proc
      property var ctx: null
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
    if (!proc) { ctx.done({ error: "could not start notion.py" }); return }
    proc.command = ["python3", root.script].concat(args)
    if (payload) {
      proc.stdinEnabled = true               // stdin must be open before it starts
      proc.running = true
      proc.write(payload)                    // the secret and the note go over stdin
      proc.stdinEnabled = false              // close stdin: the script reads to EOF
    } else {
      proc.running = true
    }
  }

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
        cachedProc.running = true
        root.listPages(false)
      }
    }
  }
  // The cache, read straight off disk: no request, so no lane — the sidebar
  // fills instantly and keeps filling while Notion is parked.
  Process {
    id: cachedProc
    command: ["python3", root.script, "list", "--cached"]
    stdout: StdioCollector {
      onStreamFinished: {
        var res = root.parse(this.text)
        if (!res.error && Array.isArray(res.pages)) root.pages = res.pages
        root.rebuild()
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
    if (!root.rq) { root.setupError = "The request queue is not available."; return }
    root.setupBusy = true
    root.setupError = ""
    // Verifying the secret is a request to Notion like any other, so it is
    // paced like one — and it is interactive, so it goes ahead of any listing.
    root.rq.enqueue({ key: "setup", mode: "replace", priority: 0, owner: root, flush: true, label: "setup" },
      function(ctx) { root.runScript(["setup", "-"], JSON.stringify({ token: t }), ctx) },
      function(r, info) {
        root.setupBusy = false
        if (!r) { root.setupError = info.cancelled ? "The window closed before the secret was checked." : ""; return }
        if (r.error) { root.setupError = r.error; return }
        root.setupError = ""
        root.viewCleared()
        root.refresh()
      })
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
          // Confirmed inline, unlike the sign-out confirms elsewhere: this
          // button lives inside the setup view, and a notice would replace
          // the view — half-pasted token and all.
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
