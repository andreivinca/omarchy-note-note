import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ui"
import "ui/TabColors.js" as TabColors
import "services/clipboard" as Clipboard
import "services/markdown" as Markdown
import "services/microsoft" as Microsoft

// Note Note — notes for the Omarchy shell, laid out like Toolroll: a header
// with search and key hints, a sidebar of notebooks, and the note itself on
// the right, always editable. Summoned as an overlay, or detached into an
// ordinary window.
//
// Where notes come from is the providers' business (see
// providers/PROVIDERS.md): built-in ones under providers/, external ones
// under ~/.config/omarchy/note-note/providers/<id>/Provider.qml. The host
// only knows the provider contract.
Item {
  id: root

  // Injected by the shell's panel loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.andreivinca.note-note"
  readonly property string externalProvidersDir: Quickshell.env("HOME") + "/.config/omarchy/note-note/providers"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/note-note.json"

  property bool opened: false
  property bool detached: false
  property bool deleteConfirmOpen: false
  property string filterText: ""
  property string statusText: ""

  // Current note. `loadingNote` guards against editor change signals firing
  // a save while a note is being swapped in.
  property string currentPath: ""
  property bool loadingNote: false
  property bool dirty: false
  property string currentCrumb: ""
  property string loadingPath: ""

  // Shares the [menu] surface tokens, so a theme that styles the launcher
  // styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText

  // ── shell contract ──────────────────────────────────────────────────
  function open(payloadJson) {
    root.opened = true
    root.deleteConfirmOpen = false
    editor.clearNotice()
    for (var a = 0; a < root.accounts.length; a++) root.accounts[a].refresh()
    for (var i = 0; i < root.providers.length; i++) { root.providers[i].refresh(); if (typeof root.providers[i].watch === "function") root.providers[i].watch(true) }
    Qt.callLater(function() { editor.focusEditor() })
  }
  function stopWatching() { for (var i = 0; i < root.providers.length; i++) if (typeof root.providers[i].watch === "function") root.providers[i].watch(false) }
  function close() { root.flushSave(); root.opened = false; stopWatching() }
  function dismiss() {
    root.flushSave()
    root.opened = false
    stopWatching()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }
  function toggle() { if (root.opened) root.dismiss(); else root.open("{}") }

  function setDetached(value) {
    var next = value === true || value === "true"
    if (next === root.detached) return
    root.detached = next
    saveState()
    root.statusText = next ? "Detached — an ordinary window now, so move, resize and tile it as usual" : "Back to the summoned overlay"
    statusTimer.restart()
  }

  function goBack() {
    if (searchField.activeFocus) {
      if (root.filterText.length > 0) { root.clearSearch() }
      else if (!root.detached) root.dismiss()
      return
    }
    if (root.detached) searchField.forceActiveFocus()
    else root.dismiss()
  }

  function showStatus(text) { root.statusText = text; if (text) statusTimer.restart() }

  // While the app is visible, ask each provider every 20 s whether something
  // changed behind our back. Providers decide what is cheap (see poll()).
  Timer {
    id: pollTimer
    interval: 20000
    repeat: true
    running: root.opened && root.providersLoaded
    onTriggered: { for (var i = 0; i < root.providers.length; i++) if (typeof root.providers[i].poll === "function") root.providers[i].poll(root.currentPath) }
  }
  Timer { id: statusTimer; interval: 3500; onTriggered: root.statusText = "" }

  // ── services & providers ────────────────────────────────────────────
  // Providers get their own Microsoft sign-in (own token, own scopes) from
  // the shared service code: services.microsoft.create(providerId, scopes).
  property var accounts: []
  function createMicrosoftAccount(owner, scopes) {
    var acc = accountComponent.createObject(root, { owner: owner, scopes: ["offline_access", "User.Read"].concat(scopes || []).join(" ") })
    acc.codeReceived.connect(function(code, uri) {
      editor.showNotice("Sign in to Microsoft for " + owner,
        "Open " + uri + " in a browser, enter this code, and sign in with your Microsoft account. This screen updates by itself once you are done.", code,
        [{ label: "Copy code", icon: "󰆏", action: function() { Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", code]) } },
         { label: "Open sign-in page", icon: "󰖟", action: function() { Quickshell.execDetached(["xdg-open", uri]) } }])
    })
    acc.loginSucceeded.connect(function() { editor.showNotice("Signed in", "Fetching your notes…", "", []) })
    acc.loginFailed.connect(function(error) {
      editor.showNotice("Sign-in failed", error, "", [{ label: "Try again", icon: "󰑐", action: function() { acc.login() } }])
    })
    acc.updated.connect(function() { if (acc.signedIn && editor.noticeTitle === "Signed in") editor.clearNotice(); root.rebuildRows() })
    root.accounts = root.accounts.concat([acc])
    return acc
  }
  Component { id: accountComponent; Microsoft.Account {} }

  // Markdown on disk, rich text in the editor: everything the note pane shows
  // or saves passes through here (services/markdown/Markdown.qml).
  Markdown.Markdown { id: markdownService }

  // Pasting a picture into a note; only providers that can store one take it.
  Clipboard.Clipboard { id: clipboardService }
  readonly property var services: ({ microsoft: { create: function(owner, scopes) { return root.createMicrosoftAccount(owner, scopes) } } })

  property var providers: []
  property var providerState: ({})
  property bool providersLoaded: false

  function providerOf(path) {
    if (!path) return null
    var pid = path.substring(0, path.indexOf(":"))
    for (var i = 0; i < root.providers.length; i++) if (root.providers[i].id === pid) return root.providers[i]
    return null
  }
  function providerById(id) { return providerOf(id + ":") }
  // The provider of the open tab. Section keys start with the provider's id.
  function activeProvider() { var k = activeKey(); return k ? providerById(k.substring(0, k.indexOf("/"))) : null }
  function canCreateNotebook() { var p = activeProvider(); return !!p && p.canCreateSection === true }

  function addProvider(url) {
    var comp = Qt.createComponent(url)
    if (comp.status === Component.Error) { console.warn("note-note: provider failed:", url, comp.errorString()); return null }
    var p = comp.createObject(root, { host: root, services: root.services })
    if (!p || !p.id) { console.warn("note-note: provider has no id:", url); return null }
    p.updated.connect(function() { root.rebuildRows() })
    p.statusRequested.connect(function(t) { root.showStatus(t) })
    p.noticeRequested.connect(function(title, text, code, actions) { editor.showNotice(title, text, code, actions) })
    p.noticeCleared.connect(function() { editor.clearNotice() })
    p.viewRequested.connect(function(title, component, props) { editor.showNotice(title, " ", "", []); editor.showView(component, props) })
    p.viewCleared.connect(function() { editor.clearNotice() })
    p.persistRequested.connect(function() { root.saveState() })
    if (p.noteChanged) p.noteChanged.connect(function(path) {
      if (path === root.currentPath && !root.dirty && !root.saving && !root.loadingNote) root.reloadCurrent()
    })
    if (root.providerState[p.id]) p.restoreState(root.providerState[p.id])
    root.providers = root.providers.concat([p])
    return p
  }

  function loadProviders(externalDirs) {
    var urls = [Qt.resolvedUrl("providers/local/Provider.qml"),
                Qt.resolvedUrl("providers/sticky/Provider.qml"),
                Qt.resolvedUrl("providers/onenote/Provider.qml"),
                Qt.resolvedUrl("providers/notion/Provider.qml")]
    for (var i = 0; i < externalDirs.length; i++) urls.push("file://" + externalDirs[i] + "/Provider.qml")
    for (var u = 0; u < urls.length; u++) addProvider(urls[u])
    root.providersLoaded = true
    if (root.opened) root.open("{}")
  }

  Process {
    id: scanProviders
    command: ["sh", "-c", 'for d in "$1"/*/; do [ -f "$d/Provider.qml" ] && printf "%s\\n" "${d%/}"; done; true', "sh", root.externalProvidersDir]
    stdout: StdioCollector { onStreamFinished: root.loadProviders(this.text.split("\n").filter(function(l) { return l.length > 0 })) }
  }

  // ── sidebar rows ────────────────────────────────────────────────────
  property var rows: []
  property int revision: 0
  property bool pickedInitial: false
  // The tab the sidebar is open at, persisted verbatim. It is deliberately not
  // resolved against the live sections here: a provider that has not listed yet
  // (OneNote is async) must not cost the user their tab.
  property string activeSection: ""
  property var tabs: []
  property bool switchingTab: false
  function sectionKey(p, s) { return p.id + "/" + s.key }
  function sectionKeys() { var out = []; eachSection(function(p, s, k) { out.push(k) }); return out }
  // What the rail actually opens: the stored tab while it exists, else the
  // first local notebook — the user's own files come first, which is where this
  // used to land the selection anyway.
  function activeKey() {
    var keys = sectionKeys()
    if (keys.indexOf(root.activeSection) >= 0) return root.activeSection
    for (var i = 0; i < keys.length; i++) if (keys[i].indexOf("local/") === 0) return keys[i]
    return keys.length ? keys[0] : ""
  }
  function eachSection(fn) {
    for (var p = 0; p < root.providers.length; p++) {
      var prov = root.providers[p], secs = prov.sections || []
      for (var s = 0; s < secs.length; s++) fn(prov, secs[s], sectionKey(prov, secs[s]))
    }
  }
  function setActiveSection(key) {
    if (!key || key === activeKey()) return
    // Opening another notebook puts the one you were reading away: a note from
    // a tab you have left is not what the panel beside it is showing. Unsaved
    // edits are flushed on the way out.
    selectPath("")
    root.activeSection = key
    root.switchingTab = true
    rebuildRows()
    saveState()
  }
  function cycleSection(delta) {
    var keys = sectionKeys()
    if (keys.length < 2) return
    setActiveSection(keys[(keys.indexOf(activeKey()) + delta + keys.length) % keys.length])
  }
  // Two notebooks whose names happen to hash to the same pastel are told apart
  // by walking the second one along the palette. Only the host can do this: it
  // is the only thing that sees every tab at once. A provider that named its
  // own colour keeps it — a brand is not ours to move.
  function decollide(tabs) {
    var taken = {}, i, j, c
    for (i = 0; i < tabs.length; i++) if (tabs[i].color) taken[TabColors.pastelize(tabs[i].color)] = true
    for (i = 0; i < tabs.length; i++) {
      if (tabs[i].color) continue
      var from = TabColors.indexFor(tabs[i].name)
      for (j = 0; j < TabColors.PALETTE.length; j++) {
        c = TabColors.PALETTE[(from + j) % TabColors.PALETTE.length]
        if (!taken[TabColors.pastelize(c)]) break
      }
      taken[TabColors.pastelize(c)] = true
      tabs[i].color = c
    }
    return tabs
  }
  function matches(r) {
    if (!root.filterText) return true
    var q = root.filterText.toLowerCase()
    return (r.title || "").toLowerCase().indexOf(q) >= 0 || (r.preview || "").toLowerCase().indexOf(q) >= 0
  }
  function displayTitle(title, preview) {
    if (title) return title
    if (!preview) return "Untitled"
    // A checkbox line reads as a box, not as its Markdown.
    var text = preview.replace(/^\[[xX]\]\s*/, "☑ ").replace(/^\[\s?\]\s*/, "☐ ").replace(/\u00a0/g, " ").trim()
    if (!text) return "Untitled"
    var words = text.split(/\s+/).slice(0, 5).join(" ")
    return words.length < text.length ? words + "…" : words
  }
  function row(provider, key, r) {
    return { provider: provider.id, notebook: key, kind: r.kind || "note", path: r.path || "",
             title: r.title || "", preview: r.preview || "", icon: r.icon || "",
             fixed: r.fixed === true || !provider.canReorder, level: r.level || 0, expanded: r.expanded === true,
             version: r.version || "" }
  }
  function rebuildRows() {
    root.revision++
    root.currentCrumb = crumbOf(root.currentPath)
    // Opening another tab starts at the top; a refresh of the one already open
    // keeps its place.
    var keep = root.switchingTab ? 0 : list.scrollOffset(), out = [], tabs = [], active = activeKey()
    root.switchingTab = false
    eachSection(function(prov, s, key) {
      var all = s.rows || [], notes = all.filter(function(r) { return r.kind === "note" })
      // Every tab counts its own hits, the closed ones included — that is what
      // the number on a tab says while a search is running.
      tabs.push({ key: key, name: s.name, color: s.color || "", logo: prov.logo || "",
                  count: s.count !== undefined ? s.count : notes.length,
                  matches: root.filterText ? notes.filter(matches).length : 0 })
      if (key !== active) return
      if (root.filterText) {
        for (var i = 0; i < notes.length; i++) if (matches(notes[i])) out.push(row(prov, key, notes[i]))
        return
      }
      for (var j = 0; j < all.length; j++) out.push(row(prov, key, all[j]))
    })
    root.tabs = decollide(tabs)
    root.rows = out
    if (keep > 0) Qt.callLater(function() { list.setScrollOffset(keep) })
    // First open: land on the most recent note of the tab that opened.
    if (!root.currentPath && !root.filterText && !root.pickedInitial) {
      var local = root.providerById("local")
      if (local && local.sections.length) {
        root.pickedInitial = true
        for (var i = out.length - 1; i >= 0; i--) if (out[i].kind === "note" && out[i].provider === "local") { selectPath(out[i].path); break }
      }
    }
    // A note that vanished from its provider (deleted elsewhere, signed out)
    // is deselected; one merely sitting in another tab is kept.
    if (root.currentPath && !root.filterText && !noteExists(root.currentPath)) { selectPath(""); return }
    // The open note changed elsewhere (its version moved): reload it, unless
    // there are unsaved edits here.
    var v = versionOf(root.currentPath)
    if (root.currentPath && v && root.loadedVersion !== "" && v !== root.loadedVersion && !root.dirty && !root.saving && !root.loadingNote) reloadCurrent()
    else if (v && root.loadedVersion === "") root.loadedVersion = v
  }
  property string loadedVersion: ""
  function versionOf(path) {
    var v = ""
    eachSection(function(prov, s, key) { (s.rows || []).forEach(function(r) { if (r.kind === "note" && r.path === path && r.version) v = r.version }) })
    return v
  }
  function reloadCurrent() {
    var path = root.currentPath, p = providerOf(path)
    if (!p) return
    root.loadingNote = true
    root.loadedVersion = versionOf(path)
    p.load(path, function(r) {
      if (root.currentPath !== path) return
      if (r.error) { root.loadingNote = false; return }
      var pos = editor.cursorPosition()
      editor.setNote(r.title || "", r.body || "")
      editor.setCursorPosition(pos)
      editor.readOnly = r.editable === false
      root.loadingNote = false
      root.dirty = false
      showStatus(p.name + ": reloaded, changed elsewhere")
    })
  }
  function noteExists(path) {
    var found = false
    eachSection(function(prov, s, key) { if ((s.rows || []).some(function(r) { return r.kind === "note" && r.path === path })) found = true })
    if (!found) { var p = providerOf(path); if (p && p.id === "onenote" && p.pageAt && p.pageAt(path)) found = true }
    return found
  }
  function rowIndexOf(path) {
    if (!path) return -1
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].kind === "note" && root.rows[i].path === path) return i
    return -1
  }
  // Ends a search and puts the field back. The open note is deliberately left
  // alone: it is the one you found, and it is what you want to be looking at
  // once the full list comes back.
  function clearSearch() {
    searchField.text = ""
    setFilter("")
    searchField.forceActiveFocus()
  }
  function setFilter(text) {
    root.filterText = text
    rebuildRows()
    // Searching still spans every tab. When the open one has nothing, move to
    // the first that does, so a first keystroke always lands on something.
    if (root.filterText && root.rows.length === 0)
      for (var t = 0; t < root.tabs.length; t++) if (root.tabs[t].matches > 0) { setActiveSection(root.tabs[t].key); break }
    if (root.filterText && rowIndexOf(root.currentPath) < 0)
      for (var i = 0; i < root.rows.length; i++) if (root.rows[i].kind === "note") { selectPath(root.rows[i].path); break }
  }
  function crumbOf(path) { var p = providerOf(path); return p ? p.crumb(path) : "" }

  // IPC helpers (omarchy-shell shell call <id> scrollList 400).
  function activateSection(key) { setActiveSection(String(key)); return root.activeSection }
  function tabsInfo(x) { return JSON.stringify(root.tabs) }
  function scrollList(y) { list.setScrollOffset(Number(y)); return list.scrollOffset() }
  function listOffset() { return list.scrollOffset() }
  function debugState() {
    return JSON.stringify({ currentPath: root.currentPath, loadingPath: root.loadingPath, loadingNote: root.loadingNote,
                            status: root.statusText, readOnly: editor.readOnly, words: editor.wordCount, notice: editor.noticeTitle, viewFocused: editor.viewHasFocus,
                            providers: root.providers.map(function(p) { return p.id }) })
  }
  // Asked of the providers rather than of the visible rows: an action belonging
  // to a tab that is not open is still an action.
  function runAction(id) {
    var done = false
    eachSection(function(prov, s, key) {
      if (done || !(s.rows || []).some(function(r) { return r.kind === "action" && r.path === id })) return
      prov.action(id); done = true
    })
    return done
  }
  function rowsOf(providerId) {
    return JSON.stringify(root.rows.filter(function(r) { return r.provider === providerId }).map(function(r) { return r.kind + ":" + r.path.substring(0, 24) }))
  }
  function sectionsOf(providerId) { var p = providerById(providerId); return p ? JSON.stringify(p.sections.map(function(s) { return s.key + "(" + s.rows.length + ")" })) : "no provider" }
  function editorTool(id) { editor.tool(id); return true }
  function editorPaste(x) { editor.paste(); return true }
  function editorUndo(n) { for (var i = 0; i < Number(n || 1); i++) editor.undo(); return editor.wordCount }
  function editorCursor(pos) { editor.setCursorPosition(Number(pos)); editor.updateInTable(); return editor.cursorPosition() + (editor.inTable ? " in-table" : " outside") }
  function treeToggle(id) {
    var done = false
    eachSection(function(prov, s, key) {
      if (done || !(s.rows || []).some(function(r) { return r.kind === "tree" && r.path === id })) return
      prov.toggleTree(id); done = true
    })
    return done
  }

  // ── selection ───────────────────────────────────────────────────────
  function selectPath(path) {
    if (path === root.currentPath) return
    var p = providerOf(path)
    if (path && !p) return
    root.flushSave()
    editor.clearNotice()
    root.loadingNote = true
    root.currentPath = path
    root.currentCrumb = crumbOf(path)
    editor.readOnly = false
    if (!path) { editor.setNote("", ""); root.loadingNote = false; return }
    root.loadingPath = path
    editor.setNote("", "")
    editor.readOnly = true
    root.loadedVersion = ""
    p.load(path, function(r) {
      if (root.currentPath !== path) return
      root.loadingPath = ""
      if (r.error) { root.loadingNote = false; showStatus(p.name + ": " + r.error); return }
      root.loadedVersion = r.version || versionOf(path)
      editor.setNote(r.title || "", r.body || "")
      editor.readOnly = r.editable === false
      root.loadingNote = false
      root.dirty = false
    })
  }

  function moveSelection(delta) {
    var idx = [], cur = -1
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].kind !== "note") continue
      if (root.rows[i].path === root.currentPath) cur = idx.length
      idx.push(i)
    }
    if (idx.length === 0) return
    var next = (cur + delta + idx.length) % idx.length
    if (cur < 0) next = delta < 0 ? idx.length - 1 : 0
    selectPath(root.rows[idx[next]].path)
    list.positionViewAtIndex(idx[next], ListView.Contain)
  }

  // ── create / delete ─────────────────────────────────────────────────
  function newNote(providerId, target) {
    root.flushSave()
    if (root.filterText) { searchField.text = ""; setFilter("") }
    var p = providerId ? providerById(providerId) : providerOf(root.currentPath)
    if (p && target === undefined) target = p.createTargetFor(root.currentPath)
    if (!p || !target) { p = providerById("local"); target = p ? p.createTargetFor("") : "" }
    if (!p || !target) { root.startNewNotebook(); return }
    if (!p.canCreate) return
    p.create(target, function(r) {
      if (r.error) { showStatus(p.name + ": " + r.error); return }
      root.currentPath = ""
      selectPath(r.path)
      var mi = rowIndexOf(r.path)
      Qt.callLater(function() { if (mi >= 0) list.positionViewAtIndex(mi, ListView.Contain) })
      if (p.hasTitle) editor.focusTitle(); else editor.focusEditor()
    })
  }

  // "New notebook…" makes one inside the tab you are on, and only where the
  // provider says it can: the local one, whose notebooks are folders and each
  // its own tab, so a new one opens the moment it exists. The others keep
  // their notebooks inside their single tab and are made where they live.
  function newNotebook(name) {
    var p = activeProvider()
    if (!p || !p.canCreateSection) return
    p.createSection(name, function(r) {
      if (r.error) { showStatus(p.name + ": " + r.error); return }
      setActiveSection(p.id + "/" + r.key)
      // Where a note in the new section goes is the provider's to say.
      if (r.target) root.newNote(p.id, r.target)
    })
  }
  function startNewNotebook() {
    var p = activeProvider()
    if (canCreateNotebook()) { list.startNewNotebook(); return }
    showStatus((p ? p.name : "This tab") + ": notebooks are made where they live, not here")
  }

  property string deletePath: ""
  function requestDelete(path) {
    var target = path || root.currentPath, p = providerOf(target)
    if (!target || !p || !p.canDelete) return
    root.deletePath = target
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }
  function cancelDelete() { root.deleteConfirmOpen = false; editor.focusEditor() }
  function confirmDelete() {
    root.deleteConfirmOpen = false
    var path = root.deletePath, p = providerOf(path)
    root.deletePath = ""
    if (!path || !p) return
    var wasCurrent = path === root.currentPath, mi = rowIndexOf(path)
    if (wasCurrent) { saveTimer.stop(); root.dirty = false } else root.flushSave()
    var next = ""
    if (wasCurrent) {
      for (var k = Math.max(mi, 0); k >= 0 && k < root.rows.length; k--)
        if (root.rows[k].kind === "note" && root.rows[k].path !== path) { next = root.rows[k].path; break }
      if (!next) for (var j = 0; j < root.rows.length; j++)
        if (root.rows[j].kind === "note" && root.rows[j].path !== path) { next = root.rows[j].path; break }
      root.currentPath = ""
    }
    p.remove(path, function(r) { if (r.error) showStatus(p.name + ": " + r.error) })
    if (wasCurrent) { selectPath(next); editor.focusEditor() }
  }

  // ── keys ────────────────────────────────────────────────────────────
  function handleShortcut(event) {
    if (root.deleteConfirmOpen) return deleteConfirm.handleKey(event)
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { root.goBack(); return true }
    if (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_L)) { searchField.forceActiveFocus(); searchField.selectAll(); return true }
    if (ctrl && event.key === Qt.Key_N) { if (event.modifiers & Qt.ShiftModifier) root.startNewNotebook(); else root.newNote(); return true }
    if (ctrl && event.key === Qt.Key_D) { root.requestDelete(root.currentPath); return true }
    if (ctrl && (event.key === Qt.Key_Down || event.key === Qt.Key_J)) { root.moveSelection(1); return true }
    if (ctrl && event.key === Qt.Key_Up) { root.moveSelection(-1); return true }
    // Ctrl+Tab walks the binder, the way Ctrl+up/down walks the notes in it.
    // Shift+Tab arrives as Key_Backtab on some layouts and as Key_Tab on others.
    if (ctrl && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
      root.cycleSection((event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)) ? -1 : 1)
      return true
    }
    if (ctrl && editor.bodyFocused && !editor.plain && !editor.readOnly) {
      if (event.key === Qt.Key_B) { editor.toggleFormat("bold"); return true }
      if (event.key === Qt.Key_I) { editor.toggleFormat("italic"); return true }
      if (event.key === Qt.Key_U) { editor.toggleFormat("underline"); return true }
      if (event.key === Qt.Key_S) { editor.toggleFormat("strikeout"); return true }
      if (event.key === Qt.Key_H && (event.modifiers & Qt.ShiftModifier)) { editor.highlightSelection(); return true }
      // The editor decides whether this paste is a picture or text.
      if (event.key === Qt.Key_V && !(event.modifiers & Qt.ShiftModifier)) { editor.paste(); return true }
    }
    return false
  }

  // ── autosave ────────────────────────────────────────────────────────
  function onEdited() {
    if (root.loadingNote || !root.currentPath) return
    root.dirty = true
    var p = providerOf(root.currentPath)
    saveTimer.interval = (p && p.id === "local") ? 500 : 1500
    saveTimer.restart()
  }
  Timer { id: saveTimer; interval: 500; onTriggered: root.flushSave() }

  // One save in flight at a time; a save requested meanwhile runs afterwards
  // with whatever the note says by then. Transient backend errors retry.
  property bool saving: false
  property bool saveAgain: false
  property int saveRetries: 0
  Timer { id: saveRetryTimer; interval: 2500; onTriggered: { root.dirty = true; root.flushSave() } }

  function flushSave() {
    if (!root.dirty || !root.currentPath) return
    var p = providerOf(root.currentPath)
    if (!p) return
    if (editor.readOnly) { root.dirty = false; return }
    if (root.saving) { root.saveAgain = true; return }
    saveTimer.stop()
    var path = root.currentPath, title = editor.title
    root.dirty = false
    root.saving = true
    root.loadedVersion = ""
    // The document is rich text; the note is Markdown. Asking for it is
    // asynchronous, so the save proper lives in sendSave().
    editor.requestMarkdown(function(body) { root.sendSave(p, path, title, body) })
  }

  function sendSave(p, path, title, body) {
    p.save(path, title, body, function(r) {
      root.saving = false
      if (r.error) {
        if (/transient|timed? ?out|try again|too many requests|429|503/i.test(r.error) && root.saveRetries < 3) {
          root.saveRetries++
          showStatus(p.name + ": busy, retrying…")
          saveRetryTimer.restart()
        } else { root.saveRetries = 0; showStatus(p.name + ": " + r.error) }
      } else {
        root.saveRetries = 0
        if (r.warning) showStatus(p.name + ": " + r.warning)
      }
      if (root.saveAgain) { root.saveAgain = false; root.dirty = true; Qt.callLater(root.flushSave) }
    })
  }

  // ── state ───────────────────────────────────────────────────────────
  function saveState() {
    var ps = {}
    for (var i = 0; i < root.providers.length; i++) ps[root.providers[i].id] = root.providers[i].saveState()
    // version 3: the open tab, where 2 kept two lists of folded sections. An
    // older file simply has no `active`, and the first local notebook opens.
    stateFile.setText(JSON.stringify({ version: 3, detached: root.detached, active: root.activeSection, providers: ps }, null, 2) + "\n")
  }
  function loadState(raw) {
    try {
      var s = JSON.parse(raw || "{}")
      if (s.detached === true) root.detached = true
      if (typeof s.active === "string") root.activeSection = s.active
      if (s.providers) root.providerState = s.providers
    } catch (e) { /* a corrupt state file costs nothing */ }
    scanProviders.running = true
  }
  // The state file is the host's only input from disk; it holds a few flags
  // and ids. It is read exactly once, at most maxStateBytes+1 bytes, and
  // those bytes are what gets parsed — no size check followed by a reopen.
  readonly property int maxStateBytes: 1024 * 1024
  Process {
    id: stateRead
    command: ["sh", "-c", 'head -c "$2" -- "$1" 2>/dev/null; true', "sh", root.statePath, String(root.maxStateBytes + 1)]
    stdout: StdioCollector {
      onStreamFinished: {
        if (this.text.length > root.maxStateBytes) { console.warn("note-note: state file too large, ignoring"); root.loadState(""); return }
        root.loadState(this.text)
      }
    }
  }
  Component.onCompleted: stateRead.running = true
  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
  }

  // ── content: lives in the overlay card or the detached window ───────
  Item {
    id: content
    parent: root.detached ? floatingHost : cardHost
    anchors.fill: parent

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { if (root.handleShortcut(event)) event.accepted = true }

    Column {
      anchors.fill: parent
      spacing: Style.spacing.md

      // ---- header
      Item {
        width: parent.width
        height: Math.max(searchField.height, titleText.implicitHeight)

        Text {
          id: titleText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(150)
          text: "Note Note"
          color: root.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
        }

        TextField {
          id: searchField
          anchors.left: titleText.right
          anchors.leftMargin: Style.spacing.md
          width: Style.space(280)
          placeholderText: "Search notes…"
          foreground: root.foreground
          accent: root.accent
          font.family: Style.font.menuFamily
          verticalPadding: Style.spacing.xxs
          onTextEdited: root.setFilter(text)
          rightPadding: root.filterText.length > 0
            ? clearSearchButton.width + Style.spacing.xs : horizontalPadding

          Button {
            id: clearSearchButton
            visible: root.filterText.length > 0
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.xxs
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅖"
            tooltipText: "Clear the search (esc)"
            foreground: root.foreground
            accent: root.accent
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.spacing.xs
            verticalPadding: Style.spacing.xxs
            onClicked: root.clearSearch()
          }

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                     || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ControlModifier))) { editor.focusEditor(); event.accepted = true }
            else if (root.handleShortcut(event)) event.accepted = true
          }
        }

        Button {
          id: shapeButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.detached ? "Overlay" : "Detach"
          iconText: root.detached ? "󰨟" : "󰏌"
          tooltipText: root.detached ? "Back to the overlay: summoned over your work, gone on Escape"
                                     : "Detach into an ordinary window you can keep open beside your work"
          bordered: true
          selected: root.detached
          foreground: root.foreground
          accent: root.accent
          iconSize: Style.font.iconSmall
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.xxs
          onClicked: root.setDetached(!root.detached)
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: searchField.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: shapeButton.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          text: root.statusText.length > 0 ? root.statusText : "ctrl+k search · ctrl+↑↓ note · ctrl+tab notebook · ctrl+n new · esc back"
          color: root.statusText.length > 0 ? root.accent : Qt.darker(root.foreground, 1.55)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignRight
        }
      }

      // ---- body
      Row {
        width: parent.width
        height: parent.height - y
        spacing: Style.spacing.lg

        NoteList {
          id: list
          width: Style.space(215) + list.railWidth
          height: parent.height
          model: root.rows
          currentPath: root.currentPath
          filtering: root.filterText.length > 0
          sections: root.tabs
          activeKey: root.revision < 0 ? "" : root.activeKey()
          canCreateNotebook: root.revision < 0 ? false : root.canCreateNotebook()
          foreground: root.foreground
          accent: root.accent
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          titleFor: root.displayTitle
          onActivated: function(path) { root.selectPath(path); editor.focusEditor() }
          onNewRequested: function(target) {
            for (var i = 0; i < root.rows.length; i++)
              if (root.rows[i].kind === "new" && root.rows[i].path === target) { root.newNote(root.rows[i].provider, target); return }
            root.newNote()
          }
          onNewNotebookRequested: function(name) { root.newNotebook(name) }
          onActionRequested: function(id) { root.runAction(id) }
          onTreeToggled: function(id) { root.treeToggle(id) }
          onSectionActivated: function(key) { root.setActiveSection(key) }
          onDeleteRequested: function(path) { root.requestDelete(path) }
          onMoveRequested: function(from, to) {
            var mf = root.rowIndexOf(from), mt = root.rowIndexOf(to)
            if (mf < 0 || mt < 0 || root.rows[mf].notebook !== root.rows[mt].notebook) return
            var rr = root.rows.slice(), it = rr.splice(mf, 1)[0]
            rr.splice(mt, 0, it)
            root.rows = rr
          }
          onReorderFinished: function(key) {
            var paths = root.rows.filter(function(r) { return r.kind === "note" && r.notebook === key }).map(function(r) { return r.path })
            var p = paths.length ? root.providerOf(paths[0]) : null
            if (p && p.canReorder) p.setOrder(key.substring(p.id.length + 1), paths)
          }
        }

        NoteEditor {
          id: editor
          width: parent.width - list.width - Style.spacing.lg
          height: parent.height
          markdown: markdownService
          clipboard: clipboardService
          canImages: { var p = root.providerOf(root.currentPath); return p ? p.canImages === true : false }
          hasNote: root.currentPath !== ""
          plain: { var p = root.providerOf(root.currentPath); return p ? !p.markdown : false }
          hasTitle: { var p = root.providerOf(root.currentPath); return p ? p.hasTitle : true }
          enabledTools: { var p = root.providerOf(root.currentPath); return (p && p.tools !== undefined) ? p.tools : null }
          notebookName: root.currentCrumb
          fileName: {
            if (!root.currentPath) return ""
            if (root.loadingPath === root.currentPath) return "loading…"
            if (editor.readOnly) return "read-only here"
            var p = root.providerOf(root.currentPath)
            return p && p.id === "local" ? root.currentPath.substring(root.currentPath.lastIndexOf("/") + 1) : "synced online"
          }
          placeholder: root.loadingPath && root.loadingPath === root.currentPath ? "Loading…"
            : (root.rows.length === 0 && !root.filterText ? "No notes yet — press ctrl+n to create one." : "")
          foreground: root.foreground
          accent: root.accent
          shortcutHandler: root.handleShortcut
          onEdited: root.onEdited()
          onStatusRequestedTextChanged: if (statusRequestedText) { root.showStatus(statusRequestedText); statusRequestedText = "" }
        }
      }
    }

    ConfirmDialog {
      id: deleteConfirm
      anchors.fill: parent
      opened: root.deleteConfirmOpen
      z: 10
      message: "Delete this note?"
      confirmText: "Delete"
      background: root.background
      foreground: root.foreground
      scrim: root.scrim
      selectedBackground: root.selectedBackground
      selectedText: root.selectedText
      fontFamily: Style.font.menuFamily
      cornerRadius: Style.cornerRadius
      onCanceled: root.cancelDelete()
      onConfirmed: root.confirmDelete()
    }
  }

  // ── overlay ─────────────────────────────────────────────────────────
  PanelWindow {
    id: panel
    visible: root.opened && !root.detached
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-note-note"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Math.max(Style.space(900), Math.round(panel.width * 0.72)), panel.width - Style.gapsOut * 2)
      height: Math.min(Math.max(Style.space(600), Math.round(panel.height * 0.82)), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: cardHost
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
      }
    }
  }

  // ── detached window ─────────────────────────────────────────────────
  FloatingWindow {
    id: floating
    visible: root.opened && root.detached
    title: "Note Note"
    color: root.background
    implicitWidth: Style.space(1120)
    implicitHeight: Style.space(760)
    minimumSize: Qt.size(Style.space(760), Style.space(480))
    onVisibleChanged: { if (!visible && root.opened && root.detached) root.dismiss() }

    FocusScope {
      anchors.fill: parent
      focus: true
      Item {
        id: floatingHost
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
      }
    }
  }
}
