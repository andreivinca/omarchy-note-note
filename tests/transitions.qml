import QtQuick
import Quickshell
import "app/ui" as Ui
import "app/services/notes" as Notes
import "app/services/providers" as Providers
import "app/services/processes"
import "app/services/files"
import "app/providers/local" as Local
import "app/providers/onenote" as OneNote
import "app/services/microsoft" as Microsoft
import "app/services/notes/sidebar.js" as Sidebar
import "app/services/providers/settings.js" as Settings
import "app/ui/MarkdownBlocks.js" as Blocks
import "app/ui/KeyBindings.js" as Keys
import "app/ui/editing/ToolbarSettings.js" as ToolbarSettings
import "app/tests" as Tests

ShellRoot {
  id: test
  property var results: []
  property int processes: 0
  property bool localFinished: false
  property bool watchFinished: false
  property bool editorFinished: false
  property var appHost: null
  function hostSearchCases() {
    var app = test.appHost
    var source = { id: "cachetest", sections: [], replies: [], search: function(query, callback) { this.replies.push(callback) } }
    var other = { id: "othertest", sections: [], replies: [], search: function(query, callback) { this.replies.push(callback) } }
    app.providers = [source, other]
    app.filterText = "needle"
    app.runContentSearch()
    other.replies[0]({ paths: ["othertest:hit"] })
    app.invalidateContentSearch(source)
    app.refreshCachedSearch()
    source.replies[1]({ paths: ["cachetest:new"] })
    source.replies[0]({ paths: ["cachetest:old"] })
    check("cache refresh rejects an older answer to the same query",
          app.contentHits.cachetest["cachetest:new"] && !app.contentHits.cachetest["cachetest:old"])
    check("indexing refreshes only its provider", other.replies.length === 1 && app.contentHits.othertest["othertest:hit"])
    app.askProvider(source, "needle", app.searchSeq)
    app.setFilter("changed")
    source.replies[2]({ paths: ["cachetest:late"] })
    check("typing rejects in-flight cache search results", Object.keys(app.contentHits).length === 0)
    app.providers = []
    app.setFilter("")
  }
  function hostFooterCases() {
    var app = test.appHost
    var calls = []
    var first = { id: "first", name: "First", sections: [{ key: "s", name: "First", rows: [],
      footerActions: [{ path: "logout", title: "Sign out of first" }] }],
      action: function(id) { calls.push("first:" + id) } }
    var second = { id: "second", name: "Second", sections: [{ key: "s", name: "Second", rows: [],
      footerActions: [{ path: "logout", title: "Sign out of second" }] }],
      action: function(id) { calls.push("second:" + id) } }
    app.providers = [first, second]
    app.activeSection = "second/s"
    app.rebuildRows()
    check("host publishes the active provider footer", app.footerActions[0].title === "Sign out of second")
    check("footer clicks reach the active provider despite duplicate action ids",
          app.runAction("logout") && calls.join(",") === "second:logout")
    app.activeSection = "first/s"
    app.rebuildRows()
    app.runAction("logout")
    check("switching tabs switches footer action ownership", calls.join(",") === "second:logout,first:logout")
    app.providers = []
    app.rebuildRows()
    check("removing providers clears footer actions", app.footerActions.length === 0 && !app.runAction("logout"))
  }
  function check(name, ok, detail) {
    test.results.push({ name: name, ok: !!ok, detail: detail || "" })
  }
  ProcessRunner { id: runner }
  FileStore { id: files }
  Local.Provider { id: local; notesDir: Quickshell.env("NOTE_NOTE_TEST_DIR") }
  Tests.EditorKeys {
    runKeys: !Quickshell.env("NOTE_NOTE_TEST_HOST")
    onChecked: function(name, ok, detail) { test.check(name, ok, detail) }
    onFinished: test.editorFinished = true
  }

  QtObject {
    id: conversions
    property var reads: []
    property var renders: []
    property string highlight: "#f9e2af"
    property string highlightInk: "#1e1e2e"
    property string link: "#4282d7"
    property string codeChip: "transparent"
    function toMarkdown(html, callback) { reads.push(callback) }
    function toHtml(markdown, callback) { renders.push(callback) }
  }
  QtObject {
    id: clipboard
    property var callback: null
    function takeText(done) { callback = done }
    function takeHtml(done) { callback = done }
    function takeImage(done) { callback = done }
    function hasImage(done) { callback = done }
  }
  Ui.NoteEditor {
    id: editor
    width: 700
    height: 500
    hasNote: true
    markdown: conversions
    clipboard: clipboard
  }

  function show(text) {
    editor.restoreDocument({ title: "", body: "<p>" + text + "</p>", base: "" })
    editor.readOnly = false
  }
  function editorCases() {
    show("A")
    editor.withMarkdown(function(lines) { editor.replaceDoc(lines.join("\n"), 0) })
    show("B")
    conversions.reads.shift()("A", { ok: true, blocks: [0] })
    check("format conversion cannot cross note identity", conversions.renders.length === 0 && editor.plainText() === "B")

    show("A")
    editor.replaceDoc("formatted A", 0)
    show("B")
    conversions.renders.shift()("<p>formatted A</p>", true)
    check("replacement conversion cannot overwrite a different note", editor.plainText() === "B")

    show("original")
    editor.replaceDoc("formatted", 0)
    editor.edited() // a change to the current document invalidates its snapshot
    conversions.renders.shift()("<p>formatted</p>", true)
    check("replacement rejects a newer document revision", editor.plainText() === "original")

    show("caret")
    editor.withMarkdown(function() { test.check("stale selection applied", false) })
    editor.setCursorPosition(3)
    conversions.reads.shift()("caret", { ok: true, blocks: [0] })
    check("moving the caret leaves the document intact", editor.plainText() === "caret")

    ;[editor.paste, editor.pasteRich, editor.pastePlain].forEach(function(paste) {
      show("A")
      paste()
      show("B")
      clipboard.callback("clipboard text")
      check("clipboard reply belongs to its original note", editor.plainText() === "B")
    })
    show("A")
    editor.replaceDoc("valid", 0)
    conversions.renders.shift()("<p>valid</p>", true)
    check("an unchanged document accepts the requested edit", editor.plainText() === "valid")
    var fenced = ["````", "before", "```", "after", "````", "tail"]
    check("shorter backticks inside code are content", Blocks.fences(fenced)[2].end === 4)
    check("snippets land after the entire code block", editor.blockEndLine(fenced, 2) === 4)
  }

  QtObject {
    id: document
    property string title: ""
    property string body: ""
    property string documentBase: ""
    property bool readOnly: false
    property var conversions: []
    property var viewProps: null
    function cursorPosition() { return 0 }
    function setCursorPosition(position) {}
    function viewState() { return { cursor: 0, scroll: 0 } }
    function restoreViewState(state) {}
    function clearNotice() { viewProps = null }
    function showView(component, props) { viewProps = props }
    function setNote(t, b, shown) {
      title = t
      body = b
      if (shown) {
        shown(true)
      }
    }
    function snapshotDocument() { return { title: title, body: body, base: documentBase } }
    function restoreDocument(snapshot) { title = snapshot.title; body = snapshot.body; documentBase = snapshot.base }
    function requestMarkdown(callback) { document.conversions.push(callback) }
  }
  QtObject {
    id: provider
    property string id: "test"
    property string name: "Test"
    property var loads: []
    property var saves: []
    property var deletions: []
    function remove(path, callback) { deletions.push(callback) }
    function load(path, callback) { loads.push(callback); return { cancel: function() {} } }
    function save(path, title, body, callback, options) {
      saves.push({ path: path, body: body, callback: callback, options: options })
    }
    function noteEdited(path) {}
  }

  Ui.MergeConflict {
    id: conflictPane
    width: 700
    height: 500
    conflict: ({ id: "conflict", parts: [
      { id: "body:0", field: "body", base: "original", local: "ours", remote: "theirs" }
    ] })
  }
  Notes.NoteSession {
    id: mergeSession
    editor: document
    providerFor: function(path) { return provider }
    versionFor: function(path) { return "1" }
    report: function(message) {}
  }
  function mergeCases() {
    provider.loads = []
    provider.saves = []
    mergeSession.selectPath("test:merge")
    provider.loads.shift()({ body: "original" })
    document.body = "ours"
    mergeSession.onEdited()
    mergeSession.flushSave()
    document.conversions.shift()("ours", true)
    provider.saves.shift().callback({ error: "conflict", conflict: conflictPane.conflict })
    check("conflict holds the draft and pauses saving", mergeSession.dirty && document.readOnly && !!document.viewProps)
    conflictPane.choose("body:0", "both")
    check("conflict view enables save after each choice", conflictPane.complete)
    document.viewProps.resolve(conflictPane.choices)
    document.conversions.shift()("ours", true)
    var save = provider.saves.shift()
    check("resolution travels with the save snapshot", save.options.resolution.id === "conflict" &&
          save.options.resolution.choices["body:0"] === "both")
    save.callback({})
    check("resolved save releases the draft", !mergeSession.dirty && !document.readOnly && !document.viewProps)

    document.body = "older edit"
    mergeSession.onEdited()
    mergeSession.flushSave()
    document.conversions.shift()("older edit", true)
    document.body = "newer edit"
    mergeSession.onEdited()
    provider.saves.shift().callback({ error: "conflict", conflict: conflictPane.conflict })
    check("older conflict cannot decide text typed during a save", document.body === "newer edit" &&
          !document.viewProps && !document.readOnly && mergeSession.dirty)
    mergeSession.flushSave()
    document.conversions.shift()("newer edit", true)
    provider.saves.shift().callback({})

    document.body = "edit before leaving"
    mergeSession.onEdited()
    mergeSession.selectPath("test:away")
    document.conversions.shift()("edit before leaving", true)
    provider.loads.shift()({ body: "another note" })
    provider.saves.shift().callback({ error: "conflict", conflict: conflictPane.conflict })
    check("late conflict preserves the selected note", document.body === "another note" && !document.viewProps)
    mergeSession.selectPath("test:merge")
    check("returning to a conflicted draft opens its review", document.body === "edit before leaving" &&
          !!document.viewProps && document.readOnly)
    mergeSession.cancelPendingSave("test:merge")
    mergeSession.dirty = false
    mergeSession.selectPath("test:recovery")
    provider.loads.shift()({ body: "recovered draft", recovered: true, conflict: conflictPane.conflict })
    check("recovery loads as unsaved and opens its conflict", mergeSession.dirty &&
          document.body === "recovered draft" && !!document.viewProps)
    document.viewProps.continueEditing()
    check("conflict can return to editable draft", !document.readOnly && !document.viewProps)
    mergeSession.cancelPendingSave("test:recovery")
    mergeSession.dirty = false
    mergeSession.currentPath = ""
    document.body = "B"
  }
  Notes.NoteSession {
    id: session
    editor: document
    providerFor: function(path) { return provider }
    versionFor: function(path) { return "1" }
    report: function(message) {}
  }
  function sessionCases() {
    session.selectPath("test:A")
    session.selectPath("test:B")
    session.selectPath("test:A")
    provider.loads[2]({ body: "new A", view: "accepted-A" })
    provider.loads[0]({ body: "old A", view: "discarded-A" })
    provider.loads[1]({ body: "B", view: "discarded-B" })
    check("A to B to A rejects older documents and baseline tokens",
          document.body === "new A" && session.editingView === "accepted-A")
    session.onEdited()
    document.body = "unsaved A"
    session.selectPath("test:B")
    provider.loads[3]({ body: "B", view: "accepted-B" })
    document.conversions.shift()("unsaved A", true)
    check("a save retains its original note and body", provider.saves[0].path === "test:A" && provider.saves[0].body === "unsaved A")
    check("delayed conversion retains the captured editing baseline", provider.saves[0].options.view === "accepted-A")
    provider.saves.shift().callback({ error: "disk full" })
    session.selectPath("test:A")
    check("failed save draft and baseline survive switching away and back",
          document.body === "unsaved A" && session.dirty && session.editingView === "accepted-A")
    session.flushSave()
    document.conversions.shift()("unsaved A", true)
    provider.saves.shift().callback({ version: "2" })
    check("successful retry releases the retained draft", !session.drafts["test:A"] && !session.busy && session.loadedVersion === "2")
    session.reloadCurrent()
    session.selectPath("test:B")
    provider.loads[4]({ body: "late reload" })
    provider.loads[5]({ body: "B" })
    check("reload and selection share the same generation guard", document.body === "B")
    session.onEdited()
    session.remove("test:B", function(result) {})
    provider.deletions.shift()({ error: "delete refused" })
    check("failed delete preserves the editable unsaved note", session.dirty && document.body === "B" && !document.readOnly)

  }

  QtObject {
    id: host
    property var config: ({ providers: { test: { enabled: true, notebookTabs: false } } })
    property var providerUrls: ({ test: "app/providers/local/Provider.qml" })
    property string configPath: "unused-in-mock"
    property var providerState: ({})
    property var providers: [configured]
    property bool opened: false
    property int retired: 0
    function mergeConfigDefaults(value) { return value }
    function providerById(id) { return configured }
    function providerOf(path) { return configured }
    function providerSnapshot() { return {} }
    function providerBusy(p) { return p.busy }
    function applyProviderSettings(p) { p.notebookTabs = config.providers.test.notebookTabs }
    function retireProvider(p) { retired++ }
    function addProvider(url) { return configured }
    function reorderProviders() {}
    function rebuildRows() {}
    function saveState() {}
  }
  QtObject {
    id: configured
    property bool notebookTabs: false
    property bool busy: false
    function rebuild() {}
    function refresh() {}
  }
  QtObject {
    id: configFiles
    property var callback: null
    property int writes: 0
    property string lastText: ""
    function write(path, text, done) {
      writes++
      lastText = text
      callback = done
    }
  }
  Providers.ProviderLifecycle {
    id: lifecycle
    host: host
    session: session
    editor: document
    files: configFiles
  }
  function lifecycleCases() {
    var result = null
    session.onEdited()
    document.body = "settings draft"
    lifecycle.apply(JSON.stringify({ providers: { test: { enabled: true, notebookTabs: true } } }), function(r) { result = r })
    check("settings drain waits for document conversion", lifecycle.busy && configFiles.writes === 0)
    document.conversions.shift()("settings draft", true)
    lifecycle.tryCommit()
    check("settings drain waits for provider completion", configFiles.writes === 0)
    provider.saves.shift().callback({ error: "write failed" })
    lifecycle.tryCommit()
    check("failed save prevents teardown and config commit", result && result.error && host.retired === 0 && configFiles.writes === 0)
    check("failed settings transition keeps the editable draft", session.dirty && !document.readOnly && !session.locked)

    result = null
    lifecycle.apply(JSON.stringify({ providers: { test: { enabled: true, notebookTabs: true } } }), function(r) { result = r })
    document.conversions.shift()("settings draft", true)
    provider.saves.shift().callback({})
    lifecycle.tryCommit()
    check("config is not applied before file commit", host.config.providers.test.notebookTabs === false)
    configFiles.callback({ ok: true })
    check("presentation change updates the existing provider", result && result.ok && configured.notebookTabs && host.retired === 0)
    check("presentation change keeps the current note", session.currentPath === "test:B" && document.body === "settings draft")

    lifecycle.apply(JSON.stringify({ providers: { test: { enabled: false } } }), function(r) { result = r })
    configFiles.callback({ error: "permission denied" })
    check("failed config write leaves the running setup intact", result.error && host.retired === 0 && session.currentPath === "test:B")

    var layout = [["italic"], [{ dropdown: "insert", items: [
      { dropdown: "insertMonth", items: ["bold", "futureTool"] }
    ] }]]
    var toolbarConfig = { providers: host.config.providers, editor: { toolbar: layout } }
    lifecycle.apply(JSON.stringify(toolbarConfig), function(r) { result = r })
    configFiles.callback({ error: "permission denied" })
    check("failed toolbar settings save preserves the active layout", result.error && !host.config.editor)
    lifecycle.apply(JSON.stringify(toolbarConfig), function(r) { result = r })
    configFiles.callback({ ok: true })
    check("toolbar settings commit without replacing providers or losing the note",
          result.ok && host.retired === 0 && session.currentPath === "test:B"
          && JSON.stringify(host.config.editor.toolbar) === JSON.stringify(layout))
    check("saved toolbar order and future tool ids survive JSON reload",
          JSON.stringify(ToolbarSettings.editorDefaults(JSON.parse(configFiles.lastText).editor).toolbar) === JSON.stringify(layout))
    var previousWrites = configFiles.writes
    toolbarConfig.editor.toolbar = [["bold", { dropdown: "insert", items: ["bold"] }]]
    lifecycle.apply(JSON.stringify(toolbarConfig), function(r) { result = r })
    check("invalid toolbar settings are rejected before writes or document locks",
          result.error && configFiles.writes === previousWrites && !session.locked
          && JSON.stringify(host.config.editor.toolbar) === JSON.stringify(layout))

    configured.busy = true
    lifecycle.apply(JSON.stringify({ providers: { test: { enabled: false } } }), function(r) { result = r })
    var writes = configFiles.writes
    lifecycle.tryCommit()
    check("provider retirement waits for accepted mutations", host.retired === 0 && configFiles.writes === writes)
    configured.busy = false
    lifecycle.tryCommit()
    configFiles.callback({ ok: true })
    check("provider retires only after drain and confirmed settings write", host.retired === 1 && session.currentPath === "")
  }

  function pureCases() {
    var tools = [
      { toolId: "bold", isMenu: false },
      { toolId: "italic", isMenu: false },
      { toolId: "insert", isMenu: true },
      { toolId: "newTool", isMenu: false }
    ]
    var layout = [["italic", "uninstalled"], [], [{ dropdown: "insert", items: ["bold", "future"] }]]
    var layoutBefore = JSON.stringify(layout)
    var resolved = ToolbarSettings.resolve(layout, tools)
    check("toolbar resolves ordered groups, dropdown members and omitted extensions",
          resolved.toolbar.map(function(entry) { return entry.tool.toolId }).join(",") === "italic,insert,newTool"
          && resolved.toolbar[1].group === 2 && resolved.toolbar[2].group === 3
          && resolved.menus.insert[0].toolId === "bold")
    check("toolbar resolution preserves user settings", JSON.stringify(layout) === layoutBefore)
    var nestedTools = tools.concat([
      { toolId: "insertMonth", isMenu: true },
      { toolId: "more", isMenu: true }
    ])
    var nested = [[{ dropdown: "insert", items: [
      { dropdown: "insertMonth", items: ["italic", { dropdown: "more", items: ["bold", "future"] }] }
    ] }]]
    var nestedBefore = JSON.stringify(nested)
    var nestedResolved = ToolbarSettings.resolve(nested, nestedTools)
    check("nested dropdowns preserve order and keep descendants off the toolbar",
          !ToolbarSettings.validate(nested)
          && nestedResolved.toolbar.map(function(entry) { return entry.tool.toolId }).join(",") === "insert,newTool"
          && nestedResolved.menus.insert[0].toolId === "insertMonth"
          && nestedResolved.menus.insertMonth.map(function(tool) { return tool.toolId }).join(",") === "italic,more"
          && nestedResolved.menus.more[0].toolId === "bold"
          && JSON.stringify(nested) === nestedBefore)
    var missingChild = ToolbarSettings.resolve(nested, tools)
    check("removing a submenu returns its descendants to the toolbar",
          missingChild.menus.insert.length === 0 && missingChild.toolbar.length === tools.length)
    var fallback = ToolbarSettings.resolve([[{ dropdown: "removedMenu", items: ["bold"] }]], tools)
    check("removing a dropdown tool returns its members to the toolbar", fallback.toolbar.length === tools.length)
    check("older settings get the full default layout",
          JSON.stringify(ToolbarSettings.editorDefaults().toolbar) === JSON.stringify(ToolbarSettings.defaults()))
    check("explicit empty layouts and unknown editor settings survive default merging",
          ToolbarSettings.editorDefaults({ toolbar: [], future: 42 }).toolbar.length === 0
          && ToolbarSettings.editorDefaults({ future: 42 }).future === 42)
    var invalid = [null, {}, ["bold"], [[null]], [[""]], [[{ dropdown: "insert" }]],
      [["bold", "bold"]], [["bold", { dropdown: "insert", items: ["bold"] }]],
      [[{ dropdown: "insert", items: [{ dropdown: "nested", items: [null] }] }]],
      [[{ dropdown: "insert", items: [{ dropdown: "insert", items: [] }] }]],
      [["bold", { dropdown: "insert", items: [{ dropdown: "nested", items: ["bold"] }] }]]]
    check("toolbar validation rejects malformed entries and duplicates at any depth", invalid.every(function(value) {
      return !!ToolbarSettings.validate(value)
    }))
    check("toolbar validation permits empty groups and tools not installed yet", !ToolbarSettings.validate(layout))
    check("editor settings validation rejects invalid containers", [null, [], "invalid"].every(function(value) {
      return !!ToolbarSettings.validateConfig({ editor: value })
    }))
    check("malformed toolbar defaults preserve unrelated editor settings",
          JSON.stringify(ToolbarSettings.editorDefaults({ toolbar: ["bold"], future: 42 }).toolbar) === JSON.stringify(ToolbarSettings.defaults())
          && ToolbarSettings.editorDefaults({ toolbar: ["bold"], future: 42 }).future === 42)
    var source = [{ id: "test", canReorder: true, sections: [{ key: "s", name: "Section", rows: [],
      footerActions: [{ path: "logout", title: "Sign out" }],
      notes: [{ kind: "note", path: "test:A", title: "Hidden note" }] }] }]
    var before = JSON.stringify(source)
    var model = Sidebar.build(source, "test/s", "hidden", {})
    check("sidebar search includes notes inside folded trees", model.rows.length === 1 && model.hits["test/s"] === 1)
    check("sidebar footer survives search without becoming a result", model.footerActions.length === 1 &&
          model.footerActions[0].path === "logout" && model.tabs[0].count === 1)
    var logoutSearch = Sidebar.build(source, "test/s", "sign out", {})
    check("footer labels do not count as matching notes", logoutSearch.rows.length === 0 && logoutSearch.hits["test/s"] === 0)
    check("leaving a provider clears its footer", Sidebar.build(source, "other/s", "", {}).footerActions.length === 0)
    check("sidebar builder does not mutate provider input", JSON.stringify(source) === before)
    check("provider setting order does not cause replacement", Settings.plan(
      { providers: { a: { path: "x", enabled: true } } },
      { providers: { a: { enabled: true, path: "x" } } }, ["a"]).length === 0)
    check("changing a resource requires replacement", Settings.plan(
      { providers: { a: { path: "x" } } }, { providers: { a: { path: "y" } } }, ["a"])[0].replace)
    if (Quickshell.env("NOTE_NOTE_TEST_HOST") === "1") {
      var component = Qt.createComponent("app/Notes.qml")
      check("the complete host component compiles", component.status === Component.Ready, component.errorString())
      if (component.status === Component.Ready) {
        test.appHost = component.createObject(test)
        check("the host instantiates with its real controllers", !!test.appHost)
        if (test.appHost) {
          var oldConfig = test.appHost.mergeConfigDefaults({ providers: {} })
          check("host adds toolbar settings to older configuration", JSON.stringify(oldConfig.editor.toolbar) === JSON.stringify(ToolbarSettings.defaults()))
          var customConfig = test.appHost.mergeConfigDefaults({ editor: { toolbar: layout, future: 42 } })
          check("host preserves custom toolbar order and unknown editor settings", JSON.stringify(customConfig.editor.toolbar) === layoutBefore && customConfig.editor.future === 42)
          var malformedConfig = test.appHost.mergeConfigDefaults({ providers: { local: { enabled: false } }, editor: { toolbar: ["bold"] } })
          check("invalid toolbar at startup does not reset valid provider settings", !malformedConfig.providers.local.enabled
                && JSON.stringify(malformedConfig.editor.toolbar) === JSON.stringify(ToolbarSettings.defaults()))
        }
      }
    }
    check("shortcut dispatch and help use common definitions", Keys.match({ key: Qt.Key_N, modifiers: Qt.ControlModifier | Qt.ShiftModifier }, "workspace") === "newNotebook" && Keys.text().indexOf("ctrl+shift+n") >= 0)

  }

  function processCase(name, options, expected, cancel) {
    test.processes++
    var calls = 0
    var handle = runner.run(options, function(result) {
      calls++
      check(name, expected(result), JSON.stringify(result))
      test.processes--
    })
    if (cancel) {
      handle.cancel()
      handle.cancel()
    }
    completionChecks.push(function() { check(name + " completes once", calls === 1) })
  }
  property var completionChecks: []
  function processCases() {
    processCase("JSON process success", { command: ["python3", "-c", "import sys; print(sys.stdin.read())"], payload: '{"ok":true}' }, function(r) { return r.ok })
    processCase("process startup failure", { command: ["/note-note-command-does-not-exist"] }, function(r) { return !!r.error })
    processCase("nonzero process exit", { command: ["python3", "-c", "print('{}'); exit(3)"] }, function(r) { return !!r.error })
    processCase("malformed process output", { command: ["python3", "-c", "print('not json')"] }, function(r) { return !!r.error })
    processCase("process deadline", { command: ["python3", "-c", "import time; time.sleep(10)"], timeoutMs: 80 }, function(r) { return r.error === "operation timed out" })
    processCase("process cancellation", { command: ["python3", "-c", "import time; time.sleep(10)"] }, function(r) { return r.cancelled }, true)
  }

  function localCases() {
    local.watch(true)
    test.processes++
    local.load(local.pathOf(local.notesRoot + "/Large.md"), function(result) {
      check("oversized UTF-8 note is never returned as editable truncated text", !!result.error && !result.editable && result.body === undefined)
      test.processes--
    })
    local.createSection("Broken", function(result) {
      check("failed mkdir is reported without publishing a notebook", !!result.error && !local.notebooks.some(function(b) { return b.key === "Broken" }))
    })
    local.createSection("Work", function(result) {
      check("local section commit", !result.error, result.error)
      local.create("section:Work", function(created) {
        check("local create commit", !!created.path, created.error)
        var path = created.path, order = []
        var staged = "![](file://" + Quickshell.env("HOME") + "/.cache/omarchy/note-note-paste/image.png)"
        local.save(path, "A", staged, function(saved) { order.push(1); check("image save commits", !saved.error, saved.error) })
        local.save(path, "B", "newest text", function(saved) {
          order.push(2)
          check("image and image-free saves are ordered", order.join(",") === "1,2")
          files.write(local.notesRoot + "/External.md", "---\ntitle: External changed\n---\nexternal content", function(result) {
            check("external edit fixture committed", !result.error)
            watchCheck.start()
          })
          local.load(path, function(loaded) {
            check("older staging cannot overwrite newer text", loaded.body === "newest text", JSON.stringify(loaded))
            local.save(path, "C", staged, function(answer) { order.push(3) })
            local.remove(path, function(removed) {
              check("delete waits for an active image save", !removed.error && order.join(",") === "1,2,3")
              local.load(path, function(missing) {
                check("delete cannot be undone by a late stage", !!missing.error)
                local.save(path, "stale", "stale", function(failed) {
                  check("failed write is reported", !!failed.error)
                  test.localFinished = true
                })
              })
            })
          })
        })
      })
    })
  }

  function report() {
    local.watch(false)
    console.log("<<<RESULT>>>" + JSON.stringify(test.results) + "<<<END>>>")
    Qt.callLater(Qt.quit)
  }
  QtObject {
    id: oneNoteAccount
    property bool configured: true
    property bool signedIn: true
    property bool loggingIn: false
    property bool filesRead: false
    property string account: "test"
    property string cacheSession: ""
    property var env: ({})
    property int optionalLogins: 0
    property int destructiveLogins: 0
    signal updated()
    function hasScope(scope) { return scope === "Notes.ReadWrite" || (scope === "Files.Read" && filesRead) }
    function loginOptional() { optionalLogins++ }
    function relogin() { destructiveLogins++ }
  }
  OneNote.Provider { id: oneNote; ms: oneNoteAccount }
  Notes.NoteSession {
    id: oneNoteSession
    editor: document
    providerFor: function(path) { return oneNote }
    versionFor: function(path) { return "1" }
    report: function(message) {}
  }
  QtObject {
    id: mergeLane
    property var jobs: []
    property int depth: 0
    function enqueue(options, start, settled) {
      jobs.push({ options: options, start: start, settled: settled })
      return { cancel: function() {} }
    }
  }
  Component { id: oneNoteFactory; OneNote.Provider {} }
  Microsoft.Account {
    id: scopeAccount
    scopes: "offline_access User.Read Notes.ReadWrite"
    optionalScopes: "Files.Read"
  }
  function oneNoteCases() {
    var created = oneNoteFactory.createObject(test, {
      host: { currentPath: "onenote:page" }, ms: oneNoteAccount
    })
    check("OneNote search waits for inventory during dynamic provider startup",
          created && created.searchStatus("onenote") === "Preparing content search…")
    created.onSections = [{ id: "section", notebookId: "book" }, { id: "other", notebookId: "other-book" }]
    created.pages = []
    created.searchInventoryReady = true
    check("OneNote search scope follows the initialized inventory",
          JSON.stringify(created.searchSections("book")) === '["section"]')
    created.destroy()
    oneNote.onSections = [{ id: "section", name: "Section", notebookId: "book", notebook: "Book" }]
    oneNote.pages = [{ id: "page", sectionId: "section", title: "Note" }]
    oneNote.rebuild()
    check("OneNote stays ready without Files.Read", oneNote.ready && oneNote.accountRows() === null)
    check("OneNote notes remain visible without Files.Read", oneNote.sections[0].notes.length === 1)
    check("optional consent is offered without replacing notebook rows",
          oneNote.sections[0].footerActions.some(function(action) { return action.path === "enableorder" }) &&
          oneNote.sections[0].rows.some(function(row) { return row.path === "book" }))
    check("OneNote keeps sign-out out of the scrolling tree",
          oneNote.sections[0].footerActions.some(function(action) { return action.path === "logout" }) &&
          !oneNote.sections[0].rows.some(function(row) { return row.path === "logout" }))
    oneNote.notebookTabs = true
    oneNote.rebuild()
    check("OneNote notebook tabs retain the account footer",
          oneNote.sections[0].key === "book" && oneNote.sections[0].footerActions.some(function(action) { return action.path === "logout" }))
    oneNote.notebookTabs = false
    oneNote.action("enableorder")
    check("optional consent does not sign out first", oneNoteAccount.optionalLogins === 1 && oneNoteAccount.destructiveLogins === 0)
    oneNoteAccount.filesRead = true
    oneNote.rebuild()
    check("consented ordering removes the optional action", !oneNote.sections[0].footerActions.some(function(action) { return action.path === "enableorder" }))
    oneNoteAccount.filesRead = false
    oneNote.rebuild()
    check("losing Files.Read does not hide notes", oneNote.ready && oneNote.sections[0].notes.length === 1)
    check("normal sign-in excludes optional scopes", scopeAccount.env.NOTE_NOTE_MS_SCOPES.indexOf("Files.Read") < 0 &&
          scopeAccount.env.NOTE_NOTE_MS_OPTIONAL_SCOPES === "Files.Read")

    var changed = 0
    var onChanged = function(path) { changed++ }
    oneNote.noteChanged.connect(onChanged)
    oneNote.rq = mergeLane
    oneNote.cacheBody("onenote:page", { title: "Title", body: "original", view: "editor-base", editable: true })
    oneNoteSession.selectPath("onenote:page")
    var baseline = { view: oneNoteSession.editingView }
    oneNote.save("onenote:page", "Title", "first edit", function(r) {}, baseline)
    oneNote.save("onenote:page", "Title", "second edit", function(r) {}, baseline)
    oneNote.applyCheck("onenote:page", { title: "Title", body: "phone edit", editable: true })
    check("poll leaves an active OneNote editing baseline intact", oneNoteSession.editingView === "editor-base")
    changed = 0
    mergeLane.jobs.shift().settled({ title: "Title", body: "older merge", view: "old-result", merged: true })
    check("older save result cannot reload over a newer save", changed === 0)
    mergeLane.jobs.shift().settled({ title: "Title", body: "newer merge", view: "new-result", merged: true })
    check("successful merge has a separate future editing view", changed === 1 &&
          oneNote.bodies.page.view === "new-result" && oneNoteSession.editingView === "editor-base")
    oneNoteSession.reloadCurrent()
    check("baseline switches when the merged note is displayed", oneNoteSession.editingView === "new-result")
    changed = 0
    oneNote.save("onenote:page", "Title", "ordinary edit", function(r) {}, { view: oneNoteSession.editingView })
    mergeLane.jobs.shift().settled({ title: "Title", body: "ordinary edit", view: "ordinary-result", merged: false })
    check("ordinary autosave does not reload and clear undo", changed === 0)
    var conflictResult = null
    oneNote.save("onenote:page", "Title", "overlap", function(r) { conflictResult = r }, { view: oneNoteSession.editingView })
    mergeLane.jobs.shift().settled({ error: "conflict", conflict: conflictPane.conflict })
    check("OneNote passes structured conflicts to the host", conflictResult.conflict.id === "conflict")
    oneNoteSession.selectPath("onenote:race")
    oneNoteSession.selectPath("onenote:away")
    oneNoteSession.selectPath("onenote:race")
    var abandoned = mergeLane.jobs.shift()
    var away = mergeLane.jobs.shift()
    mergeLane.jobs.shift().settled({ title: "Title", body: "Displayed body", view: "displayed-view", editable: true })
    abandoned.settled({ title: "Title", body: "Unseen cloud body", view: "abandoned-view", editable: true })
    away.settled({ title: "Other", body: "Other body", view: "other-view", editable: true })
    check("discarded OneNote loads cannot replace the accepted document, baseline, or cache",
          document.body === "Displayed body" && oneNoteSession.editingView === "displayed-view" &&
          oneNote.bodies.race.view === "displayed-view")
    document.title = "Only a title edit"
    oneNoteSession.onEdited()
    oneNoteSession.flushSave()
    document.conversions.shift()("Displayed body", true)
    check("a title edit captures the displayed OneNote baseline", oneNoteSession.drafts["onenote:race"].view === "displayed-view")
    mergeLane.jobs.shift().settled({ title: document.title, body: "Displayed body", view: "saved-view", merged: false })
    oneNoteSession.currentPath = ""
    oneNote.noteChanged.disconnect(onChanged)
    oneNote.rq = null
  }
  Component.onCompleted: {
    try {
      editorCases()
      sessionCases()
      mergeCases()
      lifecycleCases()
      pureCases()
      oneNoteCases()
      processCases()
      localCases()
    } catch (error) {
      check("test setup completed", false, error.message + " " + error.stack)
      report()
    }
  }
  Timer {
    interval: 250
    repeat: true
    running: true
    onTriggered: {
      if (test.localFinished && test.watchFinished && test.editorFinished && test.processes === 0 && (!test.appHost || test.appHost.providersLoaded)) {
        if (test.appHost) {
          test.check("host reads framed configuration at startup", test.appHost.configReady && test.appHost.providers.length === 0)
          test.hostSearchCases()
          test.hostFooterCases()
        }
        test.completionChecks.forEach(function(check) { check() })
        test.check("runner releases every process", runner.active === 0)
        test.report()
      }
    }
  }
  Timer {
    id: watchCheck
    interval: 1500
    onTriggered: {
      test.check("own saves do not hide external filesystem events",
                 local.notes.some(function(note) { return note.title === "External changed" }))
      test.watchFinished = true
    }
  }
  Timer {
    // Real keyboard and pointer coverage takes around 20 seconds. Leave
    // room for the remaining cases and for slower desktop runs.
    // The editor suite includes a save/undo/redo round trip for every tool.
    interval: 90000
    running: true
    onTriggered: {
      test.check("all asynchronous scenarios finished", false, JSON.stringify({
        local: test.localFinished,
        watcher: test.watchFinished,
        editor: test.editorFinished,
        processes: test.processes,
        host: !test.appHost || test.appHost.providersLoaded
      }))
      test.report()
    }
  }
}
