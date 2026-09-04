import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui

// OneNote: notebooks → sections → pages. One tab holding the whole tree by
// default, or — the host's notebookTabs setting — a binder tab per
// notebook, the way the local folders show. Pages are fetched on demand as
// Markdown (onenote.py + onenote_md.py) and written back as OneNote HTML.
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
  // This provider's own app registration: an Entra public client for
  // personal and work accounts, registered by the author, that every user
  // of OneNote here signs in through. Sticky Notes has one of its own.
  readonly property string microsoftClientId: "1ed713b0-195a-4360-88b4-993f3aeaa262"

  // When the note is written is this provider's own to decide; the host only
  // says that it changed. Every save is a PATCH against Graph, paced and
  // retried by the lane behind it and counted against an account's budget, so
  // the typing is let settle first: long enough that a sentence is one
  // request rather than one per word.
  signal saveRequested(string path)
  function noteEdited(path) { saveSchedule.path = path; saveSchedule.restart() }
  Timer {
    id: saveSchedule
    property string path: ""
    interval: 1500
    onTriggered: root.saveRequested(saveSchedule.path)
  }

  property var host: null
  property var services: null
  // Assigned by the host from config.providers.onenote.notebookTabs
  // (~/.config/notenote/config.json): each notebook a binder tab of its own
  // when true; the whole tree in one OneNote tab when false, the default.
  property bool notebookTabs: false
  // This provider's own Microsoft sign-in: own registration, own token file,
  // own scope.
  property var ms: null
  // And its own request lane, keyed to its own Graph budget: everything below
  // goes through it, in order, and it parks whole when OneNote says it has
  // had enough (services/requests/, providers/PROVIDERS.md). Sticky Notes has
  // a lane of its own, so a OneNote throttle never reaches it.
  property var rq: null
  Component.onCompleted: {
    if (services && services.microsoft) root.ms = services.microsoft.create(root.id, root.microsoftScopes, root.microsoftClientId)
    if (services && services.requests) root.rq = services.requests.queueFor("graph-onenote", root)
  }
  // A provider is destroyed and rebuilt when its settings change, and on
  // sign-out. What it had not started yet goes with it; what is already
  // running finishes, since its process is running either way.
  Component.onDestruction: { if (services && services.requests) services.requests.cancelOwner(root) }

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

  // The account rows every shape starts from: null when the tree can show,
  // the one action row that says why it cannot otherwise.
  function accountRows() {
    if (!ms || !ms.configured) return [{ kind: "action", path: "unavailable", title: "Not available in this build", icon: "󰒓" }]
    if (!ms.signedIn) return [{ kind: "action", path: "login", title: ms.loggingIn ? "Cancel signing in…" : "Sign in to Microsoft…", icon: ms.loggingIn ? "󰅖" : "󰊻" }]
    if (!ms.hasScope("Notes.ReadWrite")) return [{ kind: "action", path: "relogin", title: ms.loggingIn ? "Cancel signing in…" : "Sign in again to enable OneNote…", icon: ms.loggingIn ? "󰅖" : "󰊻" }]
    return null
  }
  function bookList() {
    var books = [], seen = {}
    for (var i = 0; i < root.onSections.length; i++) {
      var s = root.onSections[i]
      if (!seen[s.notebookId]) { seen[s.notebookId] = true; books.push({ id: s.notebookId, name: s.notebook || "Notebook" }) }
    }
    books.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return books
  }
  // One notebook's rows — "New section…", then each section as a tree with
  // its pages when open — starting at `level`: 0 when the notebook is a tab
  // of its own, 1 when it sits under its own tree row.
  function bookRows(bookId, level) {
    var rows = [{ kind: "action", path: "newsection:" + bookId, title: "New section…", icon: "+", level: level }]
    for (var k = 0; k < root.onSections.length; k++) {
      var sec = root.onSections[k]
      if (sec.notebookId !== bookId) continue
      var secOpen = root.expanded.indexOf(sec.id) >= 0
      rows.push({ kind: "tree", path: sec.id, title: sec.name, level: level, expanded: secOpen })
      if (!secOpen) continue
      for (var p = 0; p < root.pages.length; p++) {
        var pg = root.pages[p]
        if (pg.sectionId !== sec.id) continue
        rows.push({ kind: "note", path: pathOf(pg.id), title: pg.title, preview: "", level: level + 1, fixed: true, version: pg.modified || "" })
      }
      rows.push({ kind: "new", path: "section:" + sec.id, level: level + 1 })
    }
    return rows
  }
  function noteList(pgs) { return pgs.map(function(p) { return { path: pathOf(p.id), title: p.title, preview: "" } }) }
  function logoutRow() { return { kind: "action", path: "logout", title: "Sign out" + (ms.account ? " (" + ms.account + ")" : ""), icon: "󰍃" } }

  // `notes` on a section is its searchable whole, fold state ignored: rows
  // only carry the pages of expanded sections, and a search (and the hit
  // count on the tab) must see the closed ones too.
  function rebuild() {
    var account = accountRows(), books = account ? [] : bookList()
    if (root.notebookTabs && books.length > 0) {
      // A tab per notebook. No colour: each takes a pastel from its own
      // name, which is what tells Work from Personal apart (the logo keeps
      // them OneNote's); the sign-out row rides on every tab, since any of
      // them is equally the account's.
      root.sections = books.map(function(b) {
        var pgs = root.pages.filter(function(p) { var sec = root.sectionAt(p.sectionId); return sec && sec.notebookId === b.id })
        return { key: b.id, name: b.name, count: pgs.length, notes: noteList(pgs),
                 rows: bookRows(b.id, 0).concat([logoutRow()]) }
      })
      root.updated()
      return
    }
    // One OneNote tab: the sign-in states, or the notebooks as trees. The
    // empty listing lands here too, whatever the setting says — no notebooks
    // means nothing to spread, and the tab must exist to say so.
    var rows = []
    if (account) rows = account
    else {
      for (var b = 0; b < books.length; b++) {
        var open = root.expanded.indexOf(books[b].id) >= 0
        rows.push({ kind: "tree", path: books[b].id, title: books[b].name, level: 0, expanded: open })
        if (open) rows = rows.concat(bookRows(books[b].id, 1))
      }
      if (books.length === 0) rows.push(root.listing
        ? { kind: "action", path: "refresh", title: "Loading notebooks…", icon: "󰑐" }
        : { kind: "action", path: "refresh", title: "No notebooks found — refresh", icon: "󰑐" })
      rows.push(logoutRow())
    }
    root.sections = [{ key: "onenote", name: "OneNote", color: "#7719AA", count: root.pages.length, notes: noteList(root.pages), rows: rows }]
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
    if (id === "login") { if (ms.loggingIn) { ms.cancelLogin(); root.noticeCleared() } else ms.login() }
    else if (id === "relogin") { if (ms.loggingIn) { ms.cancelLogin(); root.noticeCleared() } else ms.relogin() }
    else if (id === "logout") root.noticeRequested("Sign out of OneNote?",
      "You'll need to sign in again" + (ms.account ? " as " + ms.account : "") + " to keep using OneNote.", "",
      [{ label: "Sign out", action: function() { root.noticeCleared(); ms.logout() } },
       { label: "Cancel", action: function() { root.noticeCleared() } }])
    else if (id === "refresh") root.listPages(true)
    else if (id.indexOf("newsection:") === 0) {
      root.newSectionNotebook = id.substring(11)
      root.newSectionError = ""
      root.viewRequested("New section in " + notebookName(root.newSectionNotebook), sectionView, {})
    }
    else if (id === "unavailable") root.noticeRequested("Microsoft sign-in is not configured in this build",
      "This copy of Note Note has no app registration for OneNote built in (microsoftClientId in providers/onenote/Provider.qml), so nobody can sign in yet.", "", [])
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
    if (root.newSectionBusy || !root.rq) return
    var notebook = root.newSectionNotebook
    root.newSectionBusy = true
    root.newSectionError = ""
    root.rq.enqueue({ key: "section:" + notebook, mode: "append", priority: 0, owner: root,
                      flush: true, label: "new section" },
      function(ctx) { root.runScript(["create-section", notebook, "-"], JSON.stringify({ name: n }), ctx) },
      function(r, info) {
        root.newSectionBusy = false
        if (!r) { root.newSectionError = info.cancelled ? "The window closed before the section was made." : ""; return }
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
      })
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

  // ── running the script ──────────────────────────────────────────────
  // One process per job, made when the job runs and destroyed when it
  // answers, so the callback travels with the process instead of living in a
  // single `saveCb`-shaped slot that the next save would overwrite. (That
  // slot is where a second save used to drop the first one's answer.)
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
      // A script that died without writing anything — killed, or crashed
      // before its own error handler — would otherwise leave its job in
      // flight for ever, and everything behind it in the lane with it.
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
    if (!proc) { ctx.done({ error: "could not start onenote.py" }); return }
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

  function refresh() {
    if (!root.ready) { root.onSections = []; root.pages = []; rebuild(); return }
    // The cached read is a local file and no request at all, so it does not
    // belong in the lane — it must answer instantly even while OneNote is
    // parked, which is what keeps the sidebar populated during a throttle.
    cachedProc.running = true
    root.listPages(false)
  }

  // The account-wide listing. One request when nothing changed (the sections
  // call reports each section's own timestamp and onenote.py fetches pages
  // only for the ones that moved), and ~40 when everything has.
  function listPages(force) {
    if (!root.rq || !root.ready) return
    root.rq.enqueue({ key: "list", mode: force ? "replace" : "dedupe", priority: 1,
                      owner: root, label: "listing" },
      function(ctx) { root.runScript(["list"].concat(force ? ["--force"] : ["--max-age", "600"]), "", ctx) },
      function(r) {
        if (!r) return                       // superseded by a Refresh, or cancelled
        if (r.error) root.statusRequested("OneNote: " + r.error)
        else {
          if (Array.isArray(r.sections)) root.onSections = r.sections
          if (Array.isArray(r.pages)) root.pages = r.pages
        }
        root.rebuild()
      })
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
      if (!root.ms.signedIn) {
        root.onSections = []; root.pages = []; root.bodies = ({}); clearProc.running = true
        // Nothing queued belongs to the account that just left. The rate
        // cooldown is deliberately *not* cleared: Microsoft throttles per
        // app+user, so signing back in does not lift it, and pretending
        // otherwise would just spend the first request learning that again.
        if (services && services.requests) services.requests.cancelOwner(root)
      }
      root.refresh()
    }
  }

  // ── pages ───────────────────────────────────────────────────────────
  // Every call below hands the lane a key, a mode and a callback, and the
  // lane decides when it runs. The keys are what say which requests may not
  // overlap: a page's save, delete and load are three different intents about
  // one page, and only the first two must be ordered against each other.
  function load(path, cb) {
    var id = idOf(path), cached = root.bodies[id], pg = pageAt(path)
    // A cached body is only good while the page's modified time matches.
    if (cached && (!pg || cached.version === (pg.modified || ""))) { cb({ title: cached.title, body: cached.body, editable: cached.editable, version: cached.version || "" }); return }
    if (!root.rq) { cb({ error: "not ready" }); return }
    // dedupe: asking for the same page twice before it arrives is one read,
    // and both askers are answered from it. The handle goes back to the
    // caller: the host withdraws the load of a note the user has stepped
    // past, so the one they stopped on is not stuck queueing behind it.
    return root.rq.enqueue({ key: "load:" + path, mode: "dedupe", priority: 0, owner: root, label: "page" },
      function(ctx) { root.runScript(["page", id], "", ctx) },
      function(r) {
        if (!r) { if (cb) cb({ error: "not loaded — the window closed" }); return }
        if (r.error) { if (cb) cb({ error: r.error }); return }
        var page = root.pageAt(path), title = r.title || (page ? page.title : "")
        var ver = page ? page.modified || "" : ""
        var b = root.bodies
        b[root.idOf(path)] = { title: title, body: r.body || "", editable: r.editable === true, originalTitle: title, version: ver }
        root.bodies = b
        if (cb) cb({ title: title, body: r.body || "", editable: r.editable === true, version: ver })
      })
  }

  function save(path, title, body, cb) {
    var id = idOf(path), b = root.bodies
    var original = b[id] && b[id].originalTitle !== undefined ? b[id].originalTitle : title
    b[id] = { title: title, body: body, editable: true, originalTitle: original, version: "" }
    root.bodies = b
    var pgs = root.pages.slice()
    for (var i = 0; i < pgs.length; i++) if (pgs[i].id === id) pgs[i] = { id: id, sectionId: pgs[i].sectionId, title: title, modified: pgs[i].modified }
    root.pages = pgs
    rebuild()
    if (!root.rq) { if (cb) cb({ error: "not ready" }); return }
    // replace: a newer save of one page strictly contains the older one's
    // intent, so a queued one is dropped rather than sent. flush: a save the
    // app has accepted is finished even if the window closes over it.
    var payload = JSON.stringify({ title: title, originalTitle: original, body: body })
    root.rq.enqueue({ key: "page:" + id, mode: "replace", priority: 0, owner: root, flush: true, label: "save" },
      function(ctx) { root.runScript(["update", id, "-"], payload, ctx) },
      function(r) {
        if (!r) { if (cb) cb({}); return }    // superseded or cancelled: the newer save answers
        if (r.error) { if (cb) cb({ error: r.error }); return }
        var bodiesNow = root.bodies, k = root.idOf(path)
        if (!r.warning && bodiesNow[k]) { bodiesNow[k].originalTitle = bodiesNow[k].title; root.bodies = bodiesNow }
        if (cb) cb(r.warning ? { warning: r.warning } : {})
      })
  }

  function create(target, cb) {
    if (!root.ready || !root.rq || target.indexOf("section:") !== 0) { if (cb) cb({ error: "not ready" }); return }
    root.statusRequested("Creating a OneNote page…")
    var section = target.substring(8)
    // Not deduped: two Ctrl+Ns mean two pages. During a cooldown this fails
    // fast rather than being sent, which is what stops the "page created
    // while throttled 404s for ever" poisoning (docs/testing.md).
    root.rq.enqueue({ key: "create:" + target, mode: "append", priority: 0, owner: root, flush: true, label: "new page" },
      function(ctx) { root.runScript(["create", section, "-"], JSON.stringify({ title: "", body: "" }), ctx) },
      function(r) {
        root.statusRequested("")
        if (!r) { if (cb) cb({ error: "the window closed before the page was made" }); return }
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
      })
  }

  function remove(path, cb) {
    var id = idOf(path)
    root.pages = root.pages.filter(function(p) { return p.id !== id })
    rebuild()
    if (!root.rq) { if (cb) cb({ error: "not ready" }); return }
    // The page's own key, and replace: a delete supersedes a save of the same
    // page that has not gone yet (there is nothing left to save it into), and
    // queues behind one that has — per-key order means no resurrection, and
    // no lost answer either way.
    root.rq.enqueue({ key: "page:" + id, mode: "replace", priority: 0, owner: root, flush: true, label: "delete" },
      function(ctx) { root.runScript(["delete", id], "", ctx) },
      function(r) { if (cb) cb(r && r.error ? { error: r.error } : {}) })
  }

  function setOrder(sectionKey, paths) {}

  // Polling, on a diet. Every third tick (so once a minute) this costs at
  // most two requests: the open page, and the pages of the section it is in.
  // It used to re-list *every* expanded section — up to eleven requests a
  // minute, which is 660 an hour against a budget of 400, so polling alone
  // could exhaust the account. Other sections come back with the periodic
  // listing (which now fetches only what changed) or a manual refresh.
  property int pollTick: 0
  function poll(currentPath) {
    if (!root.ready || !root.rq) return
    root.pollTick++
    // Everything the poll no longer looks at comes back here instead: every
    // fifth minute the account is re-listed, which is one request while
    // nothing has changed (onenote.py diffs each section's own timestamp) and
    // usually not even that, since the script serves its cache under
    // --max-age. That is the whole of the budget the old poll was spending.
    if (root.pollTick % 15 === 0) root.listPages(false)
    if (root.pollTick % 3 !== 0) return
    var mine = currentPath && currentPath.indexOf(root.id + ":") === 0
    if (mine) {
      root.rq.enqueue({ key: "check:" + currentPath, mode: "dedupe", priority: 1, owner: root, label: "check" },
        function(ctx) { root.runScript(["page", root.idOf(currentPath)], "", ctx) },
        function(r) { if (r && !r.error) root.applyCheck(currentPath, r) })
    }
    var page = mine ? root.pageAt(currentPath) : null
    if (!page || !page.sectionId) return
    root.rq.enqueue({ key: "pages:" + page.sectionId, mode: "dedupe", priority: 1, owner: root, label: "section pages" },
      function(ctx) { root.runScript(["pages", page.sectionId], "", ctx) },
      function(r) {
        if (!r || r.error || !Array.isArray(r.pages) || !Array.isArray(r.sections)) return
        var ids = {}; r.sections.forEach(function(id) { ids[id] = true })
        var merged = root.pages.filter(function(p) { return !ids[p.sectionId] }).concat(r.pages)
        if (JSON.stringify(merged) !== JSON.stringify(root.pages)) { root.pages = merged; root.rebuild() }
      })
  }

  // Graph does not reliably bump a page's lastModifiedDateTime, so the open
  // page is compared by its text instead.
  function applyCheck(path, r) {
    var id = root.idOf(path), old = root.bodies[id]
    if (old && old.body === (r.body || "") && old.title === (r.title || old.title)) return
    var pg = root.pageAt(path)
    var b = root.bodies
    b[id] = { title: r.title || (pg ? pg.title : ""), body: r.body || "", editable: r.editable === true,
              originalTitle: r.title || (pg ? pg.title : ""), version: pg ? pg.modified || "" : "" }
    root.bodies = b
    root.noteChanged(path)
  }

  function parse(text) { try { return JSON.parse(text) } catch (e) { return { error: "unexpected reply" } } }

  // The cache, read straight off disk so the sidebar fills instantly — and
  // still fills while the account is parked, which is the point of reading it
  // outside the lane.
  readonly property bool listing: cachedProc.running || (root.rq ? root.rq.depth > 0 : false)
  Process {
    id: cachedProc
    environment: root.ms ? root.ms.env : ({})
    command: ["python3", root.script, "list", "--cached"]
    stdout: StdioCollector {
      onStreamFinished: {
        var res = root.parse(this.text)
        if (!res.error) {
          if (Array.isArray(res.sections)) root.onSections = res.sections
          if (Array.isArray(res.pages)) root.pages = res.pages
        }
        root.rebuild()
      }
    }
  }
  Process { id: clearProc; environment: root.ms ? root.ms.env : ({}); command: ["python3", root.script, "clear-cache"] }
}
