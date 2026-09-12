import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ui"
import "ui/TabColors.js" as TabColors
import "ui/KeyBindings.js" as KeyBindings
import "ui/editing/ToolbarSettings.js" as ToolbarSettings
import "services/clipboard" as Clipboard
import "services/markdown" as Markdown
import "services/microsoft" as Microsoft
import "services/requests" as Requests
import "services/notes" as NoteServices
import "services/notes/sidebar.js" as Sidebar
import "services/providers" as ProviderServices
import "services/files" as Files

// Note Note — notes for the Omarchy shell, laid out the way a desktop IDE
// is: a title bar in a browser's shape (the binder's tabs from the left, the
// search and the window actions at the right), a workspace row (the sidebar
// and the note itself, always editable), and a view bar along the bottom
// (whose notes, where they live, the save state, the word count). Summoned
// as an overlay, or detached into an ordinary window.
//
// The host owns state and wiring; the chrome is components (ui/TitleBar.qml,
// ui/TabStrip.qml, ui/ViewBar.qml, ui/NoteList.qml, ui/NoteEditor.qml), each
// presentation only, fed by bindings and answering with signals.
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
  // Note-note's own settings — deliberately its own directory, not the
  // omarchy/ ones (layout state above; ~/.config/omarchy/note-note.json stays
  // the per-provider Microsoft registration override). A raw JSON file the
  // settings page reads and writes verbatim.
  readonly property string configDir: Quickshell.env("HOME") + "/.config/notenote"
  readonly property string configPath: root.configDir + "/config.json"

  property bool opened: false
  property bool detached: false
  // The sidebar width the user dragged the splitter to, in pixels, kept
  // across runs. 0 means they never did, and the default width stands.
  property real listWidth: 0
  property double listDate: Date.now()
  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: {
      var now = Date.now()
      if (new Date(now).toDateString() !== new Date(root.listDate).toDateString()) {
        root.listDate = now
        root.rebuildRows()
      }
    }
  }
  // The sidebar folded away behind the view bar's toggle, kept across runs.
  property bool listCollapsed: false
  property bool deleteConfirmOpen: false
  // Which page stands in for the workspace, by name — "" while the notes
  // themselves are on screen. A name rather than a flag each, so two pages
  // cannot both believe they are the one being looked at.
  property string page: ""
  readonly property bool pageOpen: root.page !== ""
  property string filterText: ""
  property string statusText: ""

  // The status bar's provider badge follows the active notebook.
  property string sourceName: "Note Note"
  property url sourceLogo: ""
  property color sourceBase: "transparent"
  readonly property color sourceInk: sourceBase.a > 0
    ? Qt.tint(foreground, Util.alpha(sourceBase, TabColors.inkAlpha())) : foreground

  // Current note. `loadingNote` guards against editor change signals firing
  // a save while a note is being swapped in.
  property alias currentPath: session.currentPath
  property alias loadingNote: session.loadingNote
  // The open note's load ended in an error and the pane is showing nothing.
  // Retried on the next open() — a queued read is dropped when the window
  // hides, so this is the ordinary way a hidden window ends a load.
  property alias loadFailed: session.loadFailed
  property alias dirty: session.dirty
  readonly property string currentCrumb: root.revision >= 0 ? crumbOf(root.currentPath) : ""
  property alias loadingPath: session.loadingPath
  // Shares the [menu] surface tokens, so a theme that styles the launcher
  // styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  // The overlay card paints its rounded background and border under the
  // content, and clips nothing: chrome that sits flush in a corner would
  // square it off. So the flush pieces round their own corners to nest
  // inside the border's arc — the card's radius minus the border they are
  // inset by. Zero when detached: there the window is square and the
  // compositor does the rounding.
  readonly property real chromeRadius: detached ? 0 : Math.max(0, Style.cornerRadius - Math.max(1, Style.space(2)))

  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  // The document and chrome share a bundled sans-serif family in four faces.
  readonly property string noteFont: nimbusSans.name
  readonly property string interfaceFont: nimbusSans.name
  // The type scale, hung off the shell's base size so it follows the
  // theme. Three steps: the note's text stands a step above the chrome
  // around it (sidebar, tabs), and the view bar's captions a step below,
  // so the eye lands on the note first.
  readonly property int noteFontSize: Math.round(Style.font.baseSize * 1.25)
  readonly property int chromeFontSize: Style.font.subtitle
  readonly property int captionFontSize: Style.font.bodySmall

  FontLoader {
    id: nimbusSans
    source: "assets/fonts/nimbus-sans/NimbusSans-Regular.otf"
  }
  FontLoader {
    source: "assets/fonts/nimbus-sans/NimbusSans-Bold.otf"
  }
  FontLoader {
    source: "assets/fonts/nimbus-sans/NimbusSans-Italic.otf"
  }
  FontLoader {
    source: "assets/fonts/nimbus-sans/NimbusSans-BoldItalic.otf"
  }

  // ── shell contract ──────────────────────────────────────────────────
  function open(payloadJson) {
    root.opened = true
    root.listDate = Date.now()
    root.deleteConfirmOpen = false
    root.page = ""
    root.pauseQueues(false)
    // A save that failed while nobody was looking is reported now, once.
    if (root.missedSaveNotice) {
      root.showStatus(root.missedSaveNotice)
      root.missedSaveNotice = ""
    }
    // A note whose load never landed — the window closed over it, or the
    // backend was busy — would otherwise sit blank and read-only until the
    // user picked something else and came back. Ask again.
    if (root.currentPath && root.loadFailed) {
      root.reloadCurrent()
    }
    // Not while a sign-in is under way: entering its device code means
    // switching to a browser, which can hide and reopen this overlay — that
    // must not wipe the very code the user is about to type in.
    if (!root.accounts.some(function(a) { return a.loggingIn })) {
      editor.clearNotice()
    }
    for (var a = 0; a < root.accounts.length; a++) {
      root.accounts[a].refresh()
    }
    for (var i = 0; i < root.providers.length; i++) {
      root.providers[i].refresh()
      if (typeof root.providers[i].watch === "function") {
        root.providers[i].watch(true)
      }
    }
    Qt.callLater(function() { editor.focusEditor() })
  }
  function stopWatching() {
    for (var i = 0; i < root.providers.length; i++) {
      if (typeof root.providers[i].watch === "function") {
        root.providers[i].watch(false)
      }
    }
  }
  function close() { root.flushSave(); root.opened = false; stopWatching(); root.pauseQueues(true) }
  function dismiss() {
    root.flushSave()
    root.opened = false
    stopWatching()
    root.pauseQueues(true)
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide(root.pluginId)
    }
  }
  function toggle() {
    if (root.opened) {
      root.dismiss()
    } else {
      root.open("{}")
    }
  }

  function setDetached(value) {
    var next = value === true || value === "true"
    if (next === root.detached) {
      return
    }
    root.detached = next
    saveState()
    root.statusText = next ? "Detached — an ordinary window now, so move, resize and tile it as usual" : "Back to the summoned overlay"
    statusTimer.restart()
  }

  // A page stands in for the workspace, so it is not dismissed the way a
  // dialog is: what closes it is asking to see notes again — its own ✕,
  // Escape, or a notebook tab in the bar above it. Opening one while another
  // is up simply swaps them; there is only ever the one.
  function openPage(name) { root.page = name }
  function closePage() {
    if (!root.pageOpen) {
      return
    }
    root.page = ""
    // The editor is only just visible again; let the frame that reveals it
    // finish before handing it the keyboard.
    Qt.callLater(function() { editor.focusEditor() })
  }
  // The page on screen, or null for the notes. One place to ask, so another
  // page is a row in the menu and a line here rather than a flag threaded
  // through the layout.
  function currentPage() {
    if (root.page === "settings") {
      return settingsPage
    }
    if (root.page === "keys") {
      return keysPage
    }
    return null
  }

  function goBack() {
    if (titleBar.searchFocused) {
      if (root.filterText.length > 0) {
        root.clearSearch()
      } else if (!root.detached) {
        root.dismiss()
      }
      return
    }
    if (root.detached) {
      titleBar.focusSearch()
    } else {
      root.dismiss()
    }
  }

  function showStatus(text) {
    root.statusText = text
    if (text) {
      statusTimer.restart()
    }
  }

  // While the app is visible, ask each provider every 20 s whether something
  // changed behind our back. Providers decide what is cheap (see poll()).
  Timer {
    id: pollTimer
    interval: 20000
    repeat: true
    running: root.opened && root.providersLoaded && !lifecycle.busy
    onTriggered: {
      for (var i = 0; i < root.providers.length; i++) {
        if (typeof root.providers[i].poll === "function") {
          root.providers[i].poll(root.currentPath)
        }
      }
    }
  }
  Timer { id: statusTimer; interval: 3500; onTriggered: root.statusText = "" }

  // ── services & providers ────────────────────────────────────────────
  // Providers get their own Microsoft sign-in (own registration, own token,
  // own scopes) from the shared service code:
  // services.microsoft.create(providerId, scopes, clientId).
  property var accounts: []
  function copyText(s) { Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", s]) }
  function createMicrosoftAccount(owner, scopes, clientId) {
    // A provider recreated on a settings change asks for its account again;
    // the one its old instance left behind would otherwise stay in the list,
    // costing a status process on every open for nobody.
    root.accounts = root.accounts.filter(function(a) {
      if (a.owner !== owner) {
        return true
      }
      a.destroy()
      return false
    })
    var acc = accountComponent.createObject(root, { owner: owner, clientId: clientId || "",
                                                    scopes: ["offline_access", "User.Read"].concat(scopes || []).join(" ") })
    acc.codeReceived.connect(function(code, uri) {
      editor.showNotice("Sign in to Microsoft for " + owner,
        "Open " + uri + " in a browser, enter this code, and sign in with your Microsoft account. This screen updates by itself once you are done.", code,
        [{ label: "Copy code", icon: "󰆏", action: function() { root.copyText(code) } },
         { label: "Copy link", icon: "󰌹", action: function() { root.copyText(uri) } },
         { label: "Open sign-in page", icon: "󰖟", action: function() { Quickshell.execDetached(["xdg-open", uri]) } }])
    })
    acc.loginSucceeded.connect(function() { editor.showNotice("Signed in", "Fetching your notes…", "", []) })
    acc.loginFailed.connect(function(error) {
      editor.showNotice("Sign-in failed", error, "", [{ label: "Try again", icon: "󰑐", action: function() { acc.login() } }])
    })
    acc.updated.connect(function() {
      if (acc.signedIn && editor.noticeTitle === "Signed in") {
        editor.clearNotice()
      }
      root.rebuildRows()
    })
    root.accounts = root.accounts.concat([acc])
    // An account knows its own status from birth, not from the next open():
    // a provider made while the window is already open (a settings change)
    // would otherwise sit at "not signed in" until the overlay is summoned
    // again, since open() is the only other thing that asks.
    acc.refresh()
    return acc
  }
  Component { id: accountComponent; Microsoft.Account {} }

  // Links use the theme accent blended with its text color for readable ink.
  readonly property string linkColour: Qt.tint(root.foreground, Util.alpha(root.accent, 0.65)).toString()

  // A quote keeps the theme's own ink at reduced strength; the editor draws
  // the classic bar beside it and the rounded slab behind a code block
  // (NoteEditor, block decorations). The document's own code background is
  // only the dialect's marker for "this block is code", so it is passed
  // fully transparent — presence is all anything reads back, and Qt Quick
  // paints even a faint one unevenly (first block only, measured on 6.11).
  readonly property string quoteInkColour: Qt.tint(root.background, Util.alpha(root.foreground, 0.8)).toString()
  readonly property string codeBackgroundColour: "transparent"

  // Inline code wears a chip the editor cannot draw itself — a span has no
  // block's geometry to hang a decoration on — so this one colour does live
  // in the document (never the note: the reader reads a mono span as code
  // before it looks at any background). The slab's own recipe, made opaque
  // because Qt's HTML writer keeps a colour but drops its alpha.
  readonly property string codeChipColour: Qt.darker(root.background, 1.16).toString()

  // Markdown on disk, rich text in the editor: everything the note pane shows
  // or saves passes through here (services/markdown/Markdown.qml).
  Markdown.Markdown {
    id: markdownService
    link: root.linkColour
    quoteInk: root.quoteInkColour
    codeBackground: root.codeBackgroundColour
    codeChip: root.codeChipColour
  }

  // Pasting a picture into a note; only providers that can store one take it.
  Clipboard.Clipboard { id: clipboardService }
  readonly property var services: ({
    microsoft: { create: function(owner, scopes, clientId) { return root.createMicrosoftAccount(owner, scopes, clientId) } },
    requests: { queueFor: function(key, provider) { return root.queueFor(key, provider) },
                cancelOwner: function(owner) { root.cancelQueuedFor(owner) } }
  })

  // ── request queues ──────────────────────────────────────────────────
  // One lane per rate key, made on demand and owned by the host rather than
  // by the provider that asked for it. That is deliberate: a provider is
  // destroyed and rebuilt whenever its settings change, and a backend's
  // cooldown has to outlive that — the service is throttling the account, not
  // the QML object. See services/requests/RequestQueue.qml.
  property var queues: ({})
  property var queueList: []
  property var queueNames: ({})
  property int queueRevision: 0
  Component { id: queueComponent; Requests.RequestQueue {} }

  function queueFor(key, provider) {
    if (provider && provider.name) {
      root.queueNames[key] = provider.name
    }
    if (root.queues[key]) {
      return root.queues[key]
    }
    var q = queueComponent.createObject(root, { domain: key, paused: !root.opened })
    if (!q) {
      console.warn("note-note: could not create a request queue for", key)
      return null
    }
    root.queues[key] = q
    root.queueList = root.queueList.concat([q])
    q.updated.connect(function() { root.queueRevision++ })
    return q
  }
  function cancelQueuedFor(owner) {
    for (var i = 0; i < root.queueList.length; i++) {
      root.queueList[i].cancelOwner(owner)
    }
  }
  // Hidden: ordinary reads and polls stop. Writes keep draining, and explicit
  // background work such as the search index can continue in the same lane.
  function pauseQueues(paused) {
    for (var i = 0; i < root.queueList.length; i++) {
      root.queueList[i].paused = paused
    }
  }
  // Of the parked lanes, the one with the longest still to wait — or null.
  // Bound through queueRevision because a plain JS object is invisible to a
  // binding.
  function coolingQueue() {
    var worst = null
    for (var i = 0; i < root.queueList.length; i++) {
      var q = root.queueList[i]
      if (q.cooling && (worst === null || q.cooldownRemaining > worst.cooldownRemaining)) {
        worst = q
      }
    }
    return worst
  }
  readonly property bool anyCooling: root.queueRevision >= 0 ? (root.coolingQueue() !== null) : false

  // A backend saying "not now" is worth saying out loud, with the number:
  // "later" on its own is not information, and the queue does know when.
  Timer {
    id: cooldownStatus
    interval: 1000
    repeat: true
    running: root.opened && root.anyCooling
    triggeredOnStart: true
    onTriggered: {
      var q = root.coolingQueue()
      if (!q) {
        return
      }
      var lead = (root.queueNames[q.domain] || q.domain) + " is rate-limited"
      // Something else is being said — a save's error, "Section created". Let
      // it have its few seconds; the countdown picks up when it clears.
      if (root.statusText && root.statusText.indexOf(lead) !== 0) {
        return
      }
      root.showStatus(lead + " — retrying in " + Math.ceil(q.cooldownRemaining) + "s"
                      + (q.depth > 0 ? " (" + q.depth + " queued)" : ""))
    }
  }

  property var providers: []
  property var providerState: ({})
  property bool providersLoaded: false
  // id -> Provider.qml url, built-ins and externals alike, populated once by
  // loadProviders() regardless of enabled state — so re-enabling a provider
  // later never needs a re-scan.
  property var providerUrls: ({})

  function providerOf(path) {
    if (!path) {
      return null
    }
    var pid = path.substring(0, path.indexOf(":"))
    for (var i = 0; i < root.providers.length; i++) {
      if (root.providers[i].id === pid) {
        return root.providers[i]
      }
    }
    return null
  }
  function providerById(id) { return providerOf(id + ":") }
  // The provider of the open tab. Section keys start with the provider's id.
  function activeProvider() { var k = activeKey(); return k ? providerOfKey(k) : null }
  // A provider's entry in config.providers is the host's file, but most of
  // its keys are the provider's own settings — local's notesDir, a
  // notebookTabs flag. Every key that names a property the provider declares
  // is assigned right after creation; `enabled` never is (whether the
  // instance exists is what it means), a key the provider does not declare
  // is not its business, and a read-only property keeps its value — so a
  // hand-edited config cannot break a provider, only miss it.
  function applyProviderSettings(p) {
    var entry = (root.config.providers || {})[p.id]
    for (var k in entry) {
      if (k === "enabled" || !(k in p)) {
        continue
      }
      try { p[k] = entry[k] } catch (e) { console.warn("note-note: provider", p.id, "setting", k, "was not taken:", e.message) }
    }
  }
  function addProvider(url) {
    var comp = Qt.createComponent(url)
    if (comp.status === Component.Error) {
      console.warn("note-note: provider failed:", url, comp.errorString())
      return null
    }
    var p = comp.createObject(root, { host: root, services: root.services })
    if (!p || !p.id) {
      console.warn("note-note: provider has no id:", url)
      return null
    }
    root.applyProviderSettings(p)
    p.updated.connect(function() { root.rebuildRows() })
    if (p.searchChanged) {
      p.searchChanged.connect(function() { root.invalidateContentSearch(p) })
    }
    p.statusRequested.connect(function(t) { root.showStatus(t) })
    p.noticeRequested.connect(function(title, text, code, actions) { editor.showNotice(title, text, code, actions) })
    p.noticeCleared.connect(function() { editor.clearNotice() })
    p.viewRequested.connect(function(title, component, props) { editor.showNotice(title, " ", "", []); editor.showView(component, props) })
    p.viewCleared.connect(function() { editor.clearNotice() })
    p.persistRequested.connect(function() { root.saveState() })
    // The provider asking for the write it was told about. Answered for the
    // open note only, since the text to be written is the editor's — and it
    // costs nothing when the note has already gone: a switch and a close
    // flush it, a delete drops its edits with it, so flushSave finds nothing
    // dirty either way. That is what lets a provider's schedule fire late
    // without the host having to reach back and cancel it.
    if (p.saveRequested) {
      p.saveRequested.connect(function(path) {
        if (path === root.currentPath) {
          root.flushSave()
        }
      })
    }
    if (p.noteChanged) {
      p.noteChanged.connect(function(path) {
        if (path === root.currentPath && !root.dirty && !root.saveInFlight(path) && !root.loadingNote) {
          root.reloadCurrent()
        }
      })
    }
    if (root.providerState[p.id]) {
      p.restoreState(root.providerState[p.id])
    }
    root.providers = root.providers.concat([p])
    return p
  }

  readonly property var builtinProviders: [
    { id: "local", url: Qt.resolvedUrl("providers/local/Provider.qml") },
    { id: "sticky", url: Qt.resolvedUrl("providers/sticky/Provider.qml") },
    { id: "onenote", url: Qt.resolvedUrl("providers/onenote/Provider.qml") },
    { id: "notion", url: Qt.resolvedUrl("providers/notion/Provider.qml") }
  ]

  // Every provider's id equals its directory's basename (built-in or
  // external alike), so which ids exist — and their urls — is known before
  // any of them is instantiated. A disabled provider is simply never
  // created, not created-then-destroyed.
  // Tabs follow root.providers' order (eachSection walks it start to end).
  // An id named in config.providers keeps that key's position — JSON.parse
  // preserves the order string keys were written in — so reordering the
  // config reorders the tabs; an id absent from config.providers (enabled by
  // default, order never asked for) just keeps its natural discovery order,
  // appended after every id the user did name.
  function orderProviderIds(ids, cfg) {
    var known = (cfg && cfg.providers) || {}, order = Object.keys(known), rank = {}
    for (var i = 0; i < order.length; i++) {
      rank[order[i]] = i
    }
    var ranked = [], rest = []
    for (var j = 0; j < ids.length; j++) {
      (rank.hasOwnProperty(ids[j]) ? ranked : rest).push(ids[j])
    }
    ranked.sort(function(a, b) { return rank[a] - rank[b] })
    return ranked.concat(rest)
  }

  function loadProviders(externalDirs) {
    var entries = root.builtinProviders.slice()
    for (var i = 0; i < externalDirs.length; i++) {
      var dir = externalDirs[i]
      entries.push({ id: dir.substring(dir.lastIndexOf("/") + 1), url: "file://" + dir + "/Provider.qml" })
    }
    var urls = {}
    for (var e = 0; e < entries.length; e++) {
      urls[entries[e].id] = entries[e].url
    }
    root.providerUrls = urls
    var ids = root.orderProviderIds(entries.map(function(x) { return x.id }), root.config)
    for (var u = 0; u < ids.length; u++) {
      if (root.providerEnabledIn(root.config, ids[u])) {
        root.addProvider(root.providerUrls[ids[u]])
      }
    }
    root.providersLoaded = true
    if (root.opened) {
      root.open("{}")
    }
  }

  Process {
    id: scanProviders
    command: ["sh", "-c", 'for d in "$1"/*/; do [ -f "$d/Provider.qml" ] && printf "%s\\n" "${d%/}"; done; true', "sh", root.externalProvidersDir]
    stdout: StdioCollector {
      onStreamFinished: {
        root.pendingExternalDirs = this.text.split("\n").filter(function(l) { return l.length > 0 })
        root.maybeLoadProviders()
      }
    }
  }

  // ── settings (~/.config/notenote/config.json) ────────────────────────
  // Runs alongside the state read, not chained after it — a different
  // concern, a different directory. loadProviders() must not run until both
  // this and the external-provider scan have landed, or a disabled provider
  // would flash on screen for a moment before disappearing.
  property var config: root.defaultConfig()
  property bool configReady: false
  property var pendingExternalDirs: null   // null = scan not finished yet

  function maybeLoadProviders() {
    if (root.pendingExternalDirs === null || !root.configReady) {
      return
    }
    root.loadProviders(root.pendingExternalDirs)
  }

  function defaultConfig() {
    return {
      editor: ToolbarSettings.editorDefaults(),
      // notebookTabs: one binder tab per notebook (the local folders'
      // historic shape) instead of one tab holding them as fold-out trees.
      // Only sources that have notebooks offer it; sticky and notion are a
      // single flat list either way, and a setting that changes nothing is
      // not listed.
      providers: {
        local: { enabled: true, notebookTabs: true, notesDir: Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes") },
        sticky: { enabled: true },
        onenote: { enabled: true, notebookTabs: false },
        notion: { enabled: true }
      }
    }
  }
  // Fills in anything the default config has that this one doesn't — a whole
  // provider missing (older file, or one a user trimmed by hand) or just one
  // key within it (an old file with `enabled` but no `notesDir` yet, say) —
  // so nothing here ever needs a migration; unknown keys, top-level or
  // per-provider, pass through untouched.
  function mergeConfigDefaults(parsed) {
    var toolbarError = ToolbarSettings.validateConfig(parsed)
    if (toolbarError) {
      // Save rejects this before merging. At startup a malformed toolbar
      // falls back on its own, preserving valid provider settings and disk.
      console.warn("note-note: " + toolbarError + "; using the default toolbar for this session")
    }
    var d = root.defaultConfig(), out = {}
    for (var k in parsed) {
      out[k] = parsed[k]
    }
    var mergedProviders = {}
    var src = (parsed && typeof parsed.providers === "object" && parsed.providers) || {}
    for (var id in src) {
      mergedProviders[id] = src[id]
    }
    for (var did in d.providers) {
      var entry = mergedProviders[did] || {}, filled = {}
      for (var ek in entry) {
        filled[ek] = entry[ek]
      }
      for (var dk in d.providers[did]) {
        if (!(dk in filled)) {
          filled[dk] = d.providers[did][dk]
        }
      }
      mergedProviders[did] = filled
    }
    out.providers = mergedProviders
    out.editor = ToolbarSettings.editorDefaults(parsed.editor)
    return out
  }
  function providerEnabledIn(cfg, id) {
    var p = cfg && cfg.providers, e = p && p[id]
    return !(e && e.enabled === false)   // absent or malformed => enabled
  }
  function loadConfig(raw) {
    var trimmed = (raw || "").replace(/^\s+|\s+$/g, "")
    if (trimmed.length === 0) {
      // Only a missing or successfully read empty file reaches here.
      // Write the defaults now, so the file is
      // self-documenting (every known setting, with its default) from the
      // moment it exists.
      root.config = root.defaultConfig()
      root.writeConfig(root.config)
    } else {
      try {
        root.config = root.mergeConfigDefaults(JSON.parse(trimmed))
      } catch (e) {
        // Corrupt, not missing — maybe mid hand-edit elsewhere. Run this
        // session on defaults, but never overwrite what's on disk except
        // through an explicit Save: healing on read would be a surprise
        // write the user never asked for, and could clobber real work.
        console.warn("note-note: config file is invalid, using defaults for this session:", e.message)
        root.config = root.defaultConfig()
      }
    }
    root.configReady = true
    root.maybeLoadProviders()
  }
  Files.FileStore {
    id: files
    onFailed: function(message) { root.reportSave(message) }
  }
  ProviderServices.ProviderLifecycle {
    id: lifecycle
    host: root
    session: session
    editor: editor
    files: files
  }
  readonly property int maxConfigBytes: 1024 * 1024
  function writeConfig(cfg, callback) {
    files.write(root.configPath, JSON.stringify(cfg, null, 2) + "\n", callback)
  }
  function applySettingsJson(text, callback) {
    lifecycle.apply(text, callback)
  }
  function providerBusy(provider) {
    if (provider.busy === true) {
      return true
    }
    return root.queueList.some(function(queue) { return queue.pendingFor(provider, true) > 0 })
  }
  function retireProvider(provider) {
    root.cancelQueuedFor(provider)
    root.providers = root.providers.filter(function(p) { return p !== provider })
    var waiting = Object.assign({}, root.searchWaiting)
    delete waiting[provider.id]
    root.searchWaiting = waiting
    delete root.invalidSearchProviders[provider.id]
    provider.destroy()
  }
  function reorderProviders() {
    var byId = {}
    for (var i = 0; i < root.providers.length; i++) {
      byId[root.providers[i].id] = root.providers[i]
    }
    var ids = root.orderProviderIds(Object.keys(byId), root.config)
    root.providers = ids.map(function(id) { return byId[id] })
  }

  // ── sidebar rows ────────────────────────────────────────────────────
  property var rows: []
  property var footerActions: []
  property int revision: 0
  // Assignments to `rows`, each of which destroys and rebuilds every delegate.
  // Read beside `revision` (rebuildRows calls) it says how many rebuilds
  // produced a list that was already on screen — which should be most of
  // them (docs/testing.md).
  property int rowWrites: 0
  // The one place `rows` is written, so the count means what it says.
  function setRows(out) { root.rows = out; root.rowWrites++ }
  // ── what a tab opens with ───────────────────────────────────────────
  // A tab opens on the note you last had open in it. That is a fact about
  // where the user was rather than about any backend — OneNote's API has no
  // opinion about which page this app showed last — so the host keeps it,
  // once, for every provider including the ones not written yet.
  //
  // A provider with a better answer says so with `defaultNote(sectionKey)`
  // and is believed instead. OneNote keeps its own, per *notebook*, because
  // its notebookTabs setting turns one tab holding every notebook into a tab
  // each and back: keys the host has never seen, about notebooks the user has
  // been reading all along.
  property var lastNotes: ({})       // section key -> the note last open there
  // True while the tab on screen is still owed its opening note: set at
  // startup and on every switch, cleared as soon as it is given one or the
  // user picks something themselves. It stays set while a provider is still
  // listing — OneNote answers a second or two after the window is up — so the
  // note is opened when its row arrives rather than lost to the race, and it
  // costs nothing left set for a note that never comes back.
  property bool defaultOwed: true

  // The user chose this note: it is what its tab opens with next time. Told
  // to the note's own provider, and kept here for the tab it was chosen in —
  // two different questions, and a search landing in another tab is where
  // they come apart. A provider that answers `defaultNote` itself keeps its
  // own memory and is not remembered here as well: the entry would never be
  // read. Entries for providers no longer loaded go with the next write.
  function rememberOpened(path) {
    var owner = providerOf(path)
    if (owner && typeof owner.noteOpened === "function") {
      owner.noteOpened(path)
    }
    if (owner && typeof owner.defaultNote === "function") {
      return
    }
    var key = activeKey()
    if (!key || root.lastNotes[key] === path) {
      return
    }
    // Replaced wholesale, never mutated, like contentHits (below): a binding
    // sees the reassignment and nothing else.
    var next = {}
    for (var k in root.lastNotes) {
      if (providerOfKey(k)) {
        next[k] = root.lastNotes[k]
      }
    }
    next[key] = path
    root.lastNotes = next
    saveState()
  }

  // Empty means open nothing: a tab you have not been in, or one whose note
  // is gone, opens empty rather than opening something you did not ask for.
  // A provider is asked with the section's own key, the one it gave the
  // section, as setOrder is.
  function defaultNoteFor(key) {
    var p = providerOfKey(key)
    if (p && typeof p.defaultNote === "function") {
      return p.defaultNote(ownKey(key)) || ""
    }
    return root.lastNotes[key] || ""
  }

  function openDefaultNote() {
    // The tab on screen while a provider is still listing may be a stand-in:
    // activeKey() falls back to the first section that exists, and the tab
    // the user actually left open — activeSection, which is deliberately not
    // resolved against the live list so that a slow provider cannot cost them
    // their tab — may be a OneNote one that arrives a second later. Answering
    // the stand-in would open a note from a tab they are about to stop
    // looking at, and spend what the real tab is owed doing it. A tab that
    // never arrives at all (signed out of its provider since) leaves the
    // note owed, which costs a comparison per rebuild and opens nothing,
    // until the user names a tab by clicking one. No intent at all — a fresh
    // state file, a user who has never switched — means the first tab is the
    // tab, and it is owed its note like any other.
    var key = activeKey()
    if (root.activeSection && key !== root.activeSection) {
      return
    }
    var path = defaultNoteFor(key)
    // Not yet, rather than not at all: a provider still listing has no row to
    // find the note in, and the next rebuild asks again.
    if (!path || !noteExists(path)) {
      return
    }
    choosePath(path)
    // Deferred: revealPath rebuilds the provider's rows, and this is being
    // called from inside a rebuild.
    Qt.callLater(function() { root.revealCurrent() })
  }
  // The tab the sidebar is open at, persisted verbatim. It is deliberately not
  // resolved against the live sections here: a provider that has not listed yet
  // (OneNote is async) must not cost the user their tab.
  property string activeSection: ""
  property var tabs: []
  // Per-tab search hit counts, keyed by tab key — beside `tabs`, not inside
  // them: the counts move on every keystroke, and a Repeater over a plain
  // array rebuilds every delegate when its model changes, so the rail's tabs
  // stay a stable model and only these numbers change under them.
  property var tabMatches: ({})
  property bool switchingTab: false
  // A tab's key is the provider's id and the section's own key, and these two
  // are the only places that spelling is known: everything else goes through
  // them, in one direction or the other.
  function sectionKey(p, s) { return p.id + "/" + s.key }
  function providerOfKey(key) { return providerById(key.substring(0, key.indexOf("/"))) }
  function ownKey(key) { return key.substring(key.indexOf("/") + 1) }
  function sectionKeys() { var out = []; eachSection(function(p, s, k) { out.push(k) }); return out }
  // What the rail actually opens: the stored tab while it exists, else the
  // first section listed. Providers are registered local-first (loadProviders),
  // so a missing or stale tab lands on the user's own files without the host
  // naming any provider here.
  function activeKey() {
    var keys = sectionKeys()
    if (keys.indexOf(root.activeSection) >= 0) {
      return root.activeSection
    }
    return keys.length ? keys[0] : ""
  }
  function eachSection(fn) {
    for (var p = 0; p < root.providers.length; p++) {
      var prov = root.providers[p], secs = prov.sections || []
      for (var s = 0; s < secs.length; s++) {
        fn(prov, secs[s], sectionKey(prov, secs[s]))
      }
    }
  }
  // `persist: false` is for switches the user did not ask for (a search
  // hopping to the tab that has hits): they are not worth a state-file write
  // per keystroke, and not the tab to come back to next run.
  function setActiveSection(key, persist) {
    if (session.locked) {
      return
    }
    if (!key || key === root.activeSection) {
      return
    }
    // The tab already on screen, standing in for one that is not listed or
    // for no intent at all: naming it makes it the tab, and there is nothing
    // to put away — the note in the editor is this tab's own.
    if (key === activeKey()) {
      root.activeSection = key
      rebuildRows()
      if (persist !== false) {
        saveState()
      }
      return
    }
    // The tab being opened is owed the note it opens with — the one last
    // chosen in it, or its provider's own answer — and nothing at all when
    // nothing is remembered (docs/decisions.md).
    root.defaultOwed = true
    // Opening another notebook puts the one you were reading away: a note from
    // a tab you have left is not what the panel beside it is showing. Unsaved
    // edits are flushed on the way out.
    selectPath("")
    showSection(key)
    if (persist !== false) {
      saveState()
    }
  }
  // Puts a tab on screen, and only that: for a caller that brings its own
  // note (newNote, whose note may have been filed in another provider's tab)
  // and so has nothing to be owed and nothing to put away.
  function showSection(key) {
    root.activeSection = key
    root.switchingTab = true
    rebuildRows()
  }
  function cycleSection(delta) {
    var keys = sectionKeys()
    if (keys.length < 2) {
      return
    }
    setActiveSection(keys[(keys.indexOf(activeKey()) + delta + keys.length) % keys.length])
  }
  // Two notebooks whose names happen to hash to the same pastel are told apart
  // by walking the second one along the palette. Only the host can do this: it
  // is the only thing that sees every tab at once. A provider that named its
  // own colour keeps it — a brand is not ours to move.
  function decollide(tabs) {
    var taken = {}, i, j, c
    for (i = 0; i < tabs.length; i++) {
      if (tabs[i].color) {
        taken[TabColors.pastelize(tabs[i].color)] = true
      }
    }
    for (i = 0; i < tabs.length; i++) {
      if (tabs[i].color) {
        continue
      }
      var from = TabColors.indexFor(tabs[i].name)
      for (j = 0; j < TabColors.PALETTE.length; j++) {
        c = TabColors.PALETTE[(from + j) % TabColors.PALETTE.length]
        if (!taken[TabColors.pastelize(c)]) {
          break
        }
      }
      taken[TabColors.pastelize(c)] = true
      tabs[i].color = c
    }
    return tabs
  }

  // ── content search ────────────────────────────────────────────────────
  // Titles and previews are matched right here, on every keystroke — that is
  // matchesQuery, and it is instant because the rows are already in memory.
  // Note *bodies* are not: they live with the providers, so once the typing
  // pauses, every provider that offers the optional `search(query, cb)` is
  // asked, and the paths it answers with join the same match set the moment
  // they arrive. Hits are kept per provider — a slow OneNote answer must not
  // wipe the local hits already showing — and every answer names the query
  // generation it was asked for, so a reply to text no longer in the field
  // changes nothing.
  property var contentHits: ({})    // provider id -> { path: true }
  // Providers asked and not yet answered, provider id -> true. Replaced
  // wholesale, never mutated, like contentHits — reassignment is what lets
  // searchBusy recompute.
  property var searchWaiting: ({})
  property int searchSeq: 0
  property int searchRevision: 0
  property int searchRequestSeq: 0
  property var searchRequests: ({})
  property var invalidSearchProviders: ({})
  // Whether note bodies are searched at all. When false the providers are
  // simply never asked — the decision is the host's alone, made by calling
  // or not calling. True until a setting owns it.
  readonly property bool searchContent: true
  // Is a content answer still owed? True from the keystroke on: the debounce
  // window counts — the ask is coming, just not sent yet — and then each
  // provider's searchWaiting entry until its reply lands. Derived, never set:
  // the search panel reads it to say "searching…" instead of a premature
  // "No match".
  readonly property bool searchBusy: root.filterText.length >= 2 && root.searchContent
    && (contentSearchTimer.running || Object.keys(root.searchWaiting).length > 0)
  Timer { id: contentSearchTimer; interval: 350; onTriggered: root.runContentSearch() }
  Timer { id: cachedSearchTimer; interval: 300; onTriggered: root.refreshCachedSearch() }

  function invalidateContentSearch(provider) {
    root.searchRevision++
    if (root.filterText.length < 2 || !root.searchContent || contentSearchTimer.running) {
      return
    }
    var pending = Object.assign({}, root.invalidSearchProviders)
    pending[provider.id] = provider
    root.invalidSearchProviders = pending
    // Repeated indexing progress cannot keep postponing the same query.
    if (!cachedSearchTimer.running) {
      cachedSearchTimer.start()
    }
  }

  function refreshCachedSearch() {
    var pending = root.invalidSearchProviders
    root.invalidSearchProviders = ({})
    if (root.filterText.length < 2 || !root.searchContent || contentSearchTimer.running) {
      return
    }
    var waiting = Object.assign({}, root.searchWaiting)
    for (var id in pending) {
      if (root.providers.indexOf(pending[id]) >= 0) {
        waiting[id] = true
      }
    }
    root.searchWaiting = waiting
    for (var key in pending) {
      if (root.providers.indexOf(pending[key]) >= 0) {
        askProvider(pending[key], root.filterText, root.searchSeq)
      }
    }
  }

  function activeSearchStatus() {
    var provider = root.activeProvider(), key = root.activeKey()
    return provider && typeof provider.searchStatus === "function"
      ? provider.searchStatus(key.substring(key.indexOf("/") + 1)) : ""
  }
  function runContentSearch() {
    // One character is not a content query: title matching already answers
    // it, and a body holding some letter is every body there is.
    var q = root.filterText
    if (q.length < 2 || !root.searchContent) {
      return
    }
    root.searchSeq++
    // Everyone about to be asked is owed from before the first ask goes out:
    // a provider that answers within its own call (sticky) then clears its
    // entry mid-loop, which is just an answer arriving early.
    var waiting = {}
    for (var i = 0; i < root.providers.length; i++) {
      if (typeof root.providers[i].search === "function") {
        waiting[root.providers[i].id] = true
      }
    }
    root.searchWaiting = waiting
    for (var j = 0; j < root.providers.length; j++) {
      askProvider(root.providers[j], q, root.searchSeq)
    }
  }
  function askProvider(p, q, seq) {
    if (typeof p.search !== "function") {
      return
    }
    var request = ++root.searchRequestSeq
    root.searchRequests[p.id] = request
    p.search(q, function(r) {
      if (seq !== root.searchSeq || root.searchRequests[p.id] !== request || !root.filterText
          || root.providers.indexOf(p) < 0) {
        return
      }
      var waiting = {}
      for (var w in root.searchWaiting) {
        if (w !== p.id) {
          waiting[w] = root.searchWaiting[w]
        }
      }
      root.searchWaiting = waiting
      var set = {}, paths = (r && r.paths) || []
      for (var j = 0; j < paths.length; j++) {
        set[paths[j]] = true
      }
      var hits = {}
      for (var k in root.contentHits) {
        hits[k] = root.contentHits[k]
      }
      hits[p.id] = set
      root.contentHits = hits
      rebuildRows()
      searchLanding()
    })
  }
  function displayTitle(title, preview) {
    if (title) {
      return title
    }
    if (!preview) {
      return "Untitled"
    }
    // A checkbox line reads as a box, not as its Markdown.
    var text = preview.replace(/^\[[xX]\]\s*/, "☑ ").replace(/^\[\s?\]\s*/, "☐ ").replace(/\u00a0/g, " ").trim()
    if (!text) {
      return "Untitled"
    }
    var words = text.split(/\s+/).slice(0, 5).join(" ")
    return words.length < text.length ? words + "…" : words
  }
  function rebuildRows() {
    root.revision++
    // Opening another tab starts at the top; a refresh of the one already open
    // keeps its place.
    var keep = root.switchingTab ? 0 : list.scrollOffset(), active = activeKey()
    root.switchingTab = false
    var model = Sidebar.build(root.providers, active, root.filterText, root.contentHits)
    var sourceProv = active ? providerOfKey(active) : null
    var out = root.filterText ? model.rows
      : Sidebar.organize(model.rows, root.listDate, model.groupByDate)
    var tabs = model.tabs, hits = model.hits
    // The tabs themselves change rarely (a notebook made, a colour given); the
    // hit counts change per keystroke. Keeping the model still while only the
    // counts move is what keeps the rail from rebuilding its delegates.
    var newTabs = decollide(tabs)
    if (JSON.stringify(newTabs) !== JSON.stringify(root.tabs)) {
      root.tabs = newTabs
    }
    root.tabMatches = hits
    if (JSON.stringify(model.footerActions) !== JSON.stringify(root.footerActions)) {
      root.footerActions = model.footerActions
    }
    // The same rule as the tabs above, and for a stronger reason: `rows` is a
    // plain JS array handed to the view as a value, so assigning one is not
    // an update to a list but a different list, and every delegate is
    // destroyed and built again — with or without the DelegateModel in
    // ui/NoteList.qml, which is there for the drag. This function runs once
    // per provider refresh, per OneNote listing and per account refresh, and
    // nearly every run reproduces the rows already on screen; a list that
    // differs in nothing the list shows is not handed over. That is what
    // the sidebar builder carrying only what the list shows buys: a field the delegates
    // never read would make equal lists unequal.
    var rowsChanged = JSON.stringify(out) !== JSON.stringify(root.rows)
    if (rowsChanged) {
      setRows(out)
    }
    var sourceTab = newTabs.find(function(tab) {
      return tab.key === active
    })
    root.sourceName = sourceProv ? sourceProv.name : "Note Note"
    root.sourceLogo = sourceProv ? (sourceProv.logo || "") : ""
    root.sourceBase = sourceTab ? TabColors.baseFor(sourceTab.color || "", sourceTab.name || "") : "transparent"
    // Only worth restoring when the list was actually rebuilt: a model that
    // never moved has kept its place already, and putting a remembered offset
    // back over it is one more jump for nothing — which is why this was worst
    // on a list scrolled down to a note in an open tree.
    if (rowsChanged && keep > 0) {
      Qt.callLater(function() { list.setScrollOffset(keep) })
    }
    // Selection/reload runs after model publication, outside provider signals.
    Qt.callLater(root.reconcileNote)
  }

  function reconcileNote() {
    if (session.locked) {
      return
    }
    if (root.defaultOwed && !root.filterText) {
      openDefaultNote()
    }
    session.reconcile(root.filterText !== "" || noteExists(root.currentPath), versionOf(root.currentPath))
  }
  function versionOf(path) {
    var v = ""
    eachSection(function(prov, s, key) {
      (s.rows || []).forEach(function(r) {
        if (r.kind === "note" && r.path === path && r.version) {
          v = r.version
        }
      })
    })
    return v
  }
  function reloadCurrent() { session.reloadCurrent() }

  // A note is "in" its provider while a section shows its row — or holds it
  // in `notes`, the section's searchable whole: a folded tree hides the row
  // without the note going anywhere (PROVIDERS.md).
  function noteExists(path) {
    var found = false
    eachSection(function(prov, s, key) {
      if (found) {
        return
      }
      if ((s.rows || []).some(function(r) { return r.kind === "note" && r.path === path })) {
        found = true
        return
      }
      if ((s.notes || []).some(function(n) { return n.path === path })) {
        found = true
      }
    })
    return found
  }
  function rowIndexOf(path) {
    if (!path) {
      return -1
    }
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].kind === "note" && root.rows[i].path === path) {
        return i
      }
    }
    return -1
  }
  // Ends a search and puts the field back. The open note is deliberately left
  // alone: it is the one you found, and it is what you want to be looking at
  // once the full list comes back.
  function clearSearch() {
    titleBar.setSearchText("")
    setFilter("")
    titleBar.focusSearch()
  }
  // The view bar's toggle, and ctrl+e: fold the sidebar away, or bring it
  // back.
  function toggleList() {
    root.listCollapsed = !root.listCollapsed
    root.saveState()
  }
  function setFilter(text) {
    var searchEnded = root.filterText.length > 0 && text.length === 0
    root.filterText = text
    // The results stand where the sidebar stands; a search while it is
    // folded away would answer out of sight, so the search opens it.
    if (text.length > 0 && root.listCollapsed) {
      root.listCollapsed = false
      root.saveState()
    }
    // Content answers belong to the text they were asked for: a keystroke
    // makes them stale, so they go, and any reply still in flight with them
    // (searchSeq). The pause that follows the typing asks again.
    root.searchSeq++
    root.contentHits = ({})
    root.searchWaiting = ({})
    root.invalidSearchProviders = ({})
    cachedSearchTimer.stop()
    if (text.length > 0) {
      contentSearchTimer.restart()
    } else {
      contentSearchTimer.stop()
    }
    rebuildRows()
    searchLanding()
    // However the search ended — esc, the clear button, the text backspaced
    // away — the note it landed on should be in sight on the list that returns.
    if (searchEnded) {
      revealCurrent()
    }
  }
  // Where a search puts you, applied when the matches change — a keystroke,
  // or a provider's content answer arriving. Searching still spans every
  // tab: when the open one has nothing, move to the first that does, so a
  // keystroke always lands on something — without persisting the hop as the
  // user's chosen tab.
  function searchLanding() {
    if (!root.filterText) {
      return
    }
    if (root.rows.length === 0) {
      for (var t = 0; t < root.tabs.length; t++) {
        if ((root.tabMatches[root.tabs[t].key] || 0) > 0) {
          setActiveSection(root.tabs[t].key, false)
          break
        }
      }
    }
    if (rowIndexOf(root.currentPath) < 0) {
      for (var i = 0; i < root.rows.length; i++) {
        if (root.rows[i].kind === "note") {
          selectPath(root.rows[i].path)
          break
        }
      }
    }
  }
  // Puts the open note's row on screen. A provider whose tree can fold rows
  // away (OneNote) is first asked to unfold whatever hides it — revealPath is
  // optional in the provider contract — and its rebuild has already gone
  // through rebuildRows by the time it returns. The scroll waits a beat so the
  // list is laid out with the rows the reveal just added.
  function revealCurrent() {
    var p = providerOf(root.currentPath)
    if (!p) {
      return
    }
    if (typeof p.revealPath === "function") {
      p.revealPath(root.currentPath)
    }
    Qt.callLater(function() {
      var i = rowIndexOf(root.currentPath)
      if (i >= 0) {
        list.positionViewAtIndex(i, ListView.Contain)
      }
    })
  }
  function crumbOf(path) { var p = providerOf(path); return p ? p.crumb(path) : "" }

  // IPC helpers (omarchy-shell shell call <id> scrollList 400).
  function activateSection(key) { setActiveSection(String(key)); return root.activeSection }
  function tabsInfo(x) {
    return JSON.stringify(root.tabs.map(function(t) { return Object.assign({ matches: root.tabMatches[t.key] || 0 }, t) }))
  }
  function scrollList(y) { list.setScrollOffset(Number(y)); return list.scrollOffset() }
  function listOffset() { return list.scrollOffset() }
  function debugState() {
    var lanes = []
    for (var q = 0; q < root.queueList.length; q++) {
      lanes.push({ key: root.queueList[q].domain, depth: root.queueList[q].depth,
                   paused: root.queueList[q].paused,
                   cooling: root.queueList[q].cooling,
                   cooldown: Math.round(root.queueList[q].cooldownRemaining) })
    }
    var searches = {}
    for (var i = 0; i < root.providers.length; i++) {
      var provider = root.providers[i]
      if (typeof provider.searchDiagnostics === "function") {
        searches[provider.id] = provider.searchDiagnostics()
      }
    }
    return JSON.stringify({ opened: root.opened, search: searches,
                            currentPath: root.currentPath, loadingPath: root.loadingPath, loadingNote: root.loadingNote,
                            status: root.statusText, readOnly: editor.readOnly, words: editor.wordCount, notice: editor.noticeTitle, viewFocused: editor.viewHasFocus,
                            dirty: root.dirty, saving: root.saveInFlight(root.currentPath),
                            defaultOwed: root.defaultOwed,
                            rows: root.rows.length, revision: root.revision, rowWrites: root.rowWrites,
                            offset: Math.round(list.scrollOffset()),
                            loadFailed: root.loadFailed, queues: lanes,
                            providers: root.providers.map(function(p) { return p.id }) })
  }
  // The provider whose section holds a row or footer action with this id. The open
  // tab's answers first: row ids are bare strings ("logout", "refresh") that
  // several providers use, and a click always lands on the open tab — load
  // order must never pick a same-named row of another provider. Rows of
  // closed tabs still resolve, so IPC can drive any tab.
  function providerWithRow(kind, id) {
    var active = activeKey(), onActive = null, anywhere = null
    eachSection(function(prov, s, key) {
      var matchesRow = (s.rows || []).some(function(r) { return r.kind === kind && r.path === id })
      var matchesFooter = kind === "action" && (s.footerActions || []).some(function(action) { return action.path === id })
      if (!matchesRow && !matchesFooter) {
        return
      }
      if (key === active && !onActive) {
        onActive = prov
      }
      if (!anywhere) {
        anywhere = prov
      }
    })
    return onActive || anywhere
  }
  function runAction(id) {
    var footer = root.footerActions.find(function(action) {
      return action.path === id
    })
    if (footer) {
      return list.activateFooterAction(footer.provider, footer.path)
    }
    var p = providerWithRow("action", id)
    if (p) {
      p.action(id)
    }
    return !!p
  }
  function runFooterAction(action, value) {
    var current = root.footerActions.find(function(item) {
      return item.provider === action.provider && item.section === action.section && item.path === action.path
    })
    var p = current ? providerById(current.provider) : null
    if (!p || session.locked) {
      return false
    }
    p.action(current.path, value, current.section)
    return true
  }
  function activateFooterShortcut(shortcut) {
    var action = root.footerActions.find(function(item) {
      return item.shortcut === shortcut
    })
    if (!action) {
      return false
    }
    if (action.inputPlaceholder) {
      root.listCollapsed = false
    }
    return list.activateFooterAction(action.provider, action.path)
  }
  function rowsOf(providerId) {
    return JSON.stringify(root.rows.filter(function(r) { return r.provider === providerId }).map(function(r) { return r.kind + ":" + r.path.substring(0, 24) }))
  }
  function sectionsOf(providerId) { var p = providerById(providerId); return p ? JSON.stringify(p.sections.map(function(s) { return s.key + "(" + s.rows.length + ")" })) : "no provider" }
  function editorTool(id) {
    return editor.tool(id)
  }
  function editorPaste(x) { editor.paste(); return true }
  function editorUndo(n) {
    for (var i = 0; i < Number(n || 1); i++) {
      editor.undo()
    }
    return editor.wordCount
  }
  function editorCursor(pos) { editor.setCursorPosition(Number(pos)); editor.updateInTable(); return editor.cursorPosition() + (editor.inTable ? " in-table" : " outside") }
  function treeToggle(id) {
    var p = providerWithRow("tree", id)
    if (p) {
      p.toggleTree(id)
    }
    return !!p
  }

  // ── selection ───────────────────────────────────────────────────────
  // The user chose this note — a click, the keyboard, a note they just made,
  // or the tab being given the one it was owed. That settles what the tab
  // opens with next time and ends what it is owed; before selectPath's early
  // return, because re-picking the note already open is still a choice.
  // Everything else that puts a note on screen — a search landing on its
  // first hit, the neighbour picked after a delete, a tab switch putting the
  // note away — is selectPath alone: shown, not chosen.
  function choosePath(path) {
    if (path) {
      root.defaultOwed = false
      root.rememberOpened(path)
    }
    selectPath(path)
  }

  function selectPath(path) {
    root.treeCursor = ""
    session.selectPath(path)
  }

  // The list's keyboard cursor. Usually it is the open note; Ctrl+up/down
  // stepping onto a section row (kind "tree") parks it there instead — the
  // note stays open in the editor, only the highlight travels. Any real
  // selection pulls the cursor back to the note (selectPath).
  property string treeCursor: ""

  function moveSelection(delta) {
    var idx = [], cur = -1
    for (var i = 0; i < root.rows.length; i++) {
      var r = root.rows[i]
      if (r.kind !== "note" && r.kind !== "tree") {
        continue
      }
      if (atCursor(r)) {
        cur = idx.length
      }
      idx.push(i)
    }
    if (idx.length === 0) {
      return
    }
    var next = (cur + delta + idx.length) % idx.length
    if (cur < 0) {
      next = delta < 0 ? idx.length - 1 : 0
    }
    var row = root.rows[idx[next]]
    if (row.kind === "tree") {
      root.treeCursor = row.path
    } else {
      choosePath(row.path)
    }
    list.positionViewAtIndex(idx[next], ListView.Contain)
  }
  function atCursor(r) {
    if (root.treeCursor) {
      return r.kind === "tree" && r.path === root.treeCursor
    }
    return r.kind === "note" && r.path === root.currentPath
  }
  function treeCursorIndex() {
    if (!root.treeCursor) {
      return -1
    }
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].kind === "tree" && root.rows[i].path === root.treeCursor) {
        return i
      }
    }
    return -1
  }
  // Ctrl+Right opens the section under the cursor. Only that: with the
  // cursor on a note the key stays the editor's (jump a word right).
  function openTreeCursor() {
    var i = treeCursorIndex()
    if (i < 0) {
      return false
    }
    if (!root.rows[i].expanded) {
      treeToggle(root.rows[i].path)
    }
    return true
  }
  // Ctrl+Left walks up the tree: an open section closes, a closed one
  // yields to its parent, and from a note the cursor jumps to the section
  // that holds it. A note with no section above it leaves the key to the
  // editor.
  function closeTreeCursor() {
    var i = treeCursorIndex()
    if (i >= 0) {
      if (root.rows[i].expanded) {
        treeToggle(root.rows[i].path)
      } else {
        cursorToParent(i)
      }
      return true
    }
    var n = rowIndexOf(root.currentPath)
    return n >= 0 && cursorToParent(n)
  }
  // The parent of rows[i]: the nearest section row above it a level up.
  function cursorToParent(i) {
    var level = root.rows[i].level || 0
    for (var j = i - 1; j >= 0; j--) {
      var r = root.rows[j]
      if (r.kind === "tree" && (r.level || 0) < level) {
        root.treeCursor = r.path
        list.positionViewAtIndex(j, ListView.Contain)
        return true
      }
    }
    return false
  }

  // ── create / delete ─────────────────────────────────────────────────
  function newNote(providerId, target) {
    if (session.locked) {
      return
    }
    if (!providerId && root.activateFooterShortcut("newNote")) {
      return
    }
    root.flushSave()
    if (root.filterText) {
      titleBar.setSearchText("")
      setFilter("")
    }
    var p = providerId ? providerById(providerId) : activeProvider()
    if (p && target === undefined) {
      target = p.createTargetFor(root.currentPath)
    }
    if (!providerId && (!p || !target)) {
      p = root.providers.find(function(candidate) {
        return candidate.canCreate && candidate.createTargetFor("")
      })
      target = p ? p.createTargetFor("") : ""
    }
    if (!p || !target) {
      root.startNewNotebook()
      return
    }
    if (!p.canCreate) {
      return
    }
    p.create(target, function(r) {
      if (r.error) {
        showStatus(p.name + ": " + r.error)
        return
      }
      // The fallback above may have filed the note in another provider's tab
      // (ctrl+n on a tab with no create target): open that tab, or the note
      // sits in the editor with no row anywhere on screen.
      var home = sectionKeyOf(r.path)
      if (home && home !== activeKey()) {
        showSection(home)
      }
      choosePath(r.path)
      var mi = rowIndexOf(r.path)
      Qt.callLater(function() {
        if (mi >= 0) {
          list.positionViewAtIndex(mi, ListView.Contain)
        }
      })
      if (p.hasTitle) {
        editor.focusTitle()
      } else {
        editor.focusEditor()
      }
    })
  }
  // The tab a note's row is on.
  function sectionKeyOf(path) {
    var found = ""
    eachSection(function(prov, s, key) {
      if (!found && (s.rows || []).some(function(r) { return r.kind === "note" && r.path === path })) {
        found = key
      }
    })
    return found
  }

  // "New notebook…" makes one inside the tab you are on, and only where the
  // provider says it can (canCreateSection — the local folders today). Which
  // tab the new notebook opens as is the provider's answer, not assumed here:
  // a tab of its own when the provider spreads notebooks into tabs, the one
  // tab that holds them all when it folds them (createSection's cb).
  function newNotebook(name, providerId) {
    if (session.locked) {
      return
    }
    var p = providerId ? providerById(providerId) : activeProvider()
    if (!p || !p.canCreateSection) {
      return
    }
    p.createSection(name, function(r) {
      if (r.error) {
        showStatus(p.name + ": " + r.error)
        return
      }
      setActiveSection(p.id + "/" + r.key)
      // Where a note in the new section goes is the provider's to say.
      if (r.target) {
        root.newNote(p.id, r.target)
      }
    })
  }
  function startNewNotebook() {
    // The name field lives on the full list, not the search panel — and a
    // field inside a hidden panel would still steal the keyboard.
    if (root.filterText) {
      clearSearch()
    }
    var p = activeProvider()
    if (root.activateFooterShortcut("newNotebook")) {
      return
    }
    showStatus((p ? p.name : "This tab") + ": notebooks are made where they live, not here")
  }

  property string deletePath: ""
  function requestDelete(path) {
    if (session.locked) {
      return
    }
    var target = path || root.currentPath, p = providerOf(target)
    if (!target || !p || !p.canDelete) {
      return
    }
    root.deletePath = target
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }
  function cancelDelete() { root.deleteConfirmOpen = false; editor.focusEditor() }
  function confirmDelete() {
    root.deleteConfirmOpen = false
    var path = root.deletePath, p = providerOf(path)
    root.deletePath = ""
    if (!path || !p) {
      return
    }
    var wasCurrent = path === root.currentPath, mi = rowIndexOf(path)
    var next = ""
    if (wasCurrent) {
      for (var k = Math.max(mi, 0); k >= 0 && k < root.rows.length; k--) {
        if (root.rows[k].kind === "note" && root.rows[k].path !== path) {
          next = root.rows[k].path
          break
        }
      }
      if (!next) {
        for (var j = 0; j < root.rows.length; j++) {
          if (root.rows[j].kind === "note" && root.rows[j].path !== path) {
            next = root.rows[j].path
            break
          }
        }
      }
    }
    session.remove(path, function(result) {
      if (result.error) {
        showStatus(p.name + ": " + result.error)
        return
      }
      if (wasCurrent) {
        selectPath(next)
        editor.focusEditor()
      }
    })
  }

  // ── keys ────────────────────────────────────────────────────────────
  function handleShortcut(event) {
    if (root.deleteConfirmOpen) {
      return deleteConfirm.handleKey(event)
    }
    // A page owns the keyboard while it is up: its own Escape and action
    // shortcut come first, and nothing below reaches a workspace that is not
    // on screen. KeyBindings.js writes the navigation and note keys below out
    // for the user, and says there which of them it leaves unlisted.
    var openPage = root.currentPage()
    if (openPage) {
      return openPage.handleKey(event)
    }
    var context = editor.bodyFocused && !editor.plain && !editor.readOnly ? "editor" : "workspace"
    if (context === "editor" && editor.handleToolShortcut(event)) {
      return true
    }
    var action = KeyBindings.match(event, context)
    var handlers = {
      back: root.goBack,
      search: titleBar.focusSearch,
      newNote: root.newNote,
      newNotebook: root.startNewNotebook,
      deleteNote: function() { root.requestDelete(root.currentPath) },
      nextNote: function() { root.moveSelection(1) },
      previousNote: function() { root.moveSelection(-1) },
      openTree: root.openTreeCursor,
      closeTree: root.closeTreeCursor,
      nextTab: function() { root.cycleSection(1) },
      previousTab: function() { root.cycleSection(-1) },
      toggleList: root.toggleList,
      paste: editor.paste,
      pastePlain: editor.pastePlain
    }
    return action && handlers[action] ? handlers[action]() !== false : false
  }

  NoteServices.NoteSession {
    id: session
    editor: editor
    providerFor: root.providerOf
    versionFor: root.versionOf
    report: root.reportSave
  }
  property alias saveRevision: session.saveRevision
  property string missedSaveNotice: ""
  function onEdited() { session.onEdited() }
  function flushSave() { session.flushSave() }
  function saveInFlight(path) { return session.saveInFlight(path) }

  // Said now if anyone is looking, on the next open() otherwise.
  function reportSave(message) {
    if (root.opened) {
      showStatus(message)
    } else {
      root.missedSaveNotice = message
    }
  }

  // ── state ───────────────────────────────────────────────────────────
  // Asked for by anyone whose state moved — a provider through
  // persistRequested, the host itself — and written once per turn of the
  // event loop, however many asked: one selection can move the host's memory
  // and a provider's in the same breath, and that is one write, not two.
  property bool stateWriteDue: false
  function saveState() {
    root.providerState = providerSnapshot()
    if (root.stateWriteDue) {
      return
    }
    root.stateWriteDue = true
    Qt.callLater(root.writeState)
  }
  // Kept live, not only on disk: a provider recreated on a settings change
  // (ProviderLifecycle) is restored from providerState, which would otherwise
  // still hold the startup snapshot — and lose the fold state made since.
  function providerSnapshot() {
    var ps = {}
    for (var i = 0; i < root.providers.length; i++) {
      ps[root.providers[i].id] = root.providers[i].saveState()
    }
    return ps
  }
  function writeState() {
    root.stateWriteDue = false
    root.providerState = providerSnapshot()
    // version 4: what each tab opens with, where 3 added the open tab itself
    // and 2 kept two lists of folded sections. An older file simply has no
    // `lastNotes`, and every tab opens empty until it has been used once.
    var st = { version: 4, detached: root.detached, active: root.activeSection,
               lastNotes: root.lastNotes, providers: root.providerState }
    if (root.listWidth > 0) {
      st.listWidth = Math.round(root.listWidth)
    }
    if (root.listCollapsed) {
      st.listCollapsed = true
    }
    files.write(root.statePath, JSON.stringify(st, null, 2) + "\n")
  }
  function loadState(raw) {
    try {
      var s = JSON.parse(raw || "{}")
      if (s.detached === true) {
        root.detached = true
      }
      if (typeof s.active === "string") {
        root.activeSection = s.active
      }
      // The stored width is trusted only as a number; the list's own binding
      // clamps it against whatever window it wakes up in.
      if (typeof s.listWidth === "number" && isFinite(s.listWidth) && s.listWidth > 0) {
        root.listWidth = s.listWidth
      }
      if (s.listCollapsed === true) {
        root.listCollapsed = true
      }
      // Trusted entry by entry, as a map of strings and nothing else — the
      // way the two fields above are trusted only as their type.
      if (s.lastNotes && typeof s.lastNotes === "object") {
        var remembered = {}
        for (var key in s.lastNotes) {
          if (typeof s.lastNotes[key] === "string") {
            remembered[key] = s.lastNotes[key]
          }
        }
        root.lastNotes = remembered
      }
      if (s.providers) {
        root.providerState = s.providers
      }
    } catch (e) { /* a corrupt state file costs nothing */ }
    scanProviders.running = true
  }
  readonly property int maxStateBytes: 1024 * 1024
  Component.onCompleted: {
    files.read(root.statePath, root.maxStateBytes, function(result) {
      if (result.error && result.kind !== "missing") {
        console.warn("note-note: could not read state:", result.error)
      }
      root.loadState(result.text || "")
    })
    files.read(root.configPath, root.maxConfigBytes, function(result) {
      if (result.error && result.kind !== "missing") {
        console.warn("note-note: could not read config:", result.error)
        root.config = root.defaultConfig()
        root.configReady = true
        root.maybeLoadProviders()
        return
      }
      root.loadConfig(result.text || "")
    })
  }

  // ── content: lives in the overlay card or the detached window ───────
  Item {
    id: content
    parent: root.detached ? floatingHost : cardHost
    anchors.fill: parent

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (root.handleShortcut(event)) {
        event.accepted = true
      }
    }

    Column {
      anchors.fill: parent
      spacing: 0

      // ---- title bar
      TitleBar {
        id: titleBar
        width: parent.width
        filterText: root.filterText
        sections: root.tabs
        matchCounts: root.tabMatches
        activeKey: root.revision < 0 ? "" : root.activeKey()
        detached: root.detached
        pageOpen: root.pageOpen
        cornerRadius: root.chromeRadius
        background: root.background
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.interfaceFont
        tabFontSize: root.chromeFontSize
        shortcutHandler: root.handleShortcut
        onFilterEdited: function(text) { root.setFilter(text) }
        onClearRequested: root.clearSearch()
        onMoveRequested: function(delta) { root.moveSelection(delta) }
        onAcceptRequested: editor.focusEditor()
        onSectionActivated: function(key) { root.closePage(); root.setActiveSection(key) }
        onSettingsRequested: root.openPage("settings")
        onKeysRequested: root.openPage("keys")
        onDetachToggled: root.setDetached(!root.detached)
      }


      // ---- workspace: the binder rail and sidebar, the splitter, the note
      Row {
        id: body
        visible: !root.pageOpen
        width: parent.width
        height: parent.height - titleBar.height
        spacing: 0

        NoteList {
          id: list
          visible: !root.listCollapsed
          // The user's width when they have dragged the handle, the default
          // otherwise — clamped either way, so neither the list nor the note
          // can be squeezed out of use by a drag or a narrow window.
          width: {
            var w = root.listWidth > 0 ? root.listWidth : Style.space(300)
            return Math.max(Style.space(220), Math.min(w, body.width - Style.space(320)))
          }
          height: parent.height
          model: root.rows
          footerActions: root.footerActions
          currentPath: root.currentPath
          treeCursor: root.treeCursor
          filtering: root.filterText.length > 0
          searchBusy: root.searchBusy
          searchStatus: root.searchRevision >= 0 && root.revision >= 0 ? root.activeSearchStatus() : ""
          sections: root.tabs
          activeKey: root.revision < 0 ? "" : root.activeKey()
          headerHeight: editor.toolbarHeight
          headerContentHeight: editor.toolbarRowHeight
          background: root.background
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.interfaceFont
          noteFontSize: root.chromeFontSize
          titleFor: root.displayTitle
          onActivated: function(path) { root.choosePath(path); editor.focusEditor() }
          onNewRequested: function(target) {
            for (var i = 0; i < root.rows.length; i++) {
              if (root.rows[i].kind === "new" && root.rows[i].path === target) {
                root.newNote(root.rows[i].provider, target)
                return
              }
            }
            root.newNote()
          }
          onFooterActionRequested: function(action, value) { root.runFooterAction(action, value) }
          onActionRequested: function(id) { root.runAction(id) }
          onTreeToggled: function(id) { root.treeToggle(id) }
          onDeleteRequested: function(path) { root.requestDelete(path) }
          onReorderFinished: function(key, paths) {
            // The drag reordered delegates, not rows (see the list's
            // visualModel): mirror the on-screen order into the model, then
            // hand the provider the list to persist. The notebook's note rows
            // keep their slots; only which note sits in which slot changes.
            if (!paths.length) {
              return
            }
            var rr = root.rows.slice(), slots = [], byPath = {}
            for (var i = 0; i < rr.length; i++) {
              if (rr[i].kind === "note" && rr[i].notebook === key) {
                slots.push(i)
                byPath[rr[i].path] = rr[i]
              }
            }
            if (slots.length !== paths.length) {
              return
            }
            for (var j = 0; j < slots.length; j++) {
              var r = byPath[paths[j]]
              if (!r) {
                return
              }
              rr[slots[j]] = r
            }
            root.setRows(rr)
            var p = root.providerOf(paths[0])
            if (p && p.canReorder) {
              p.setOrder(root.ownKey(key), paths)
            }
          }
        }

        // The seam between list and note is also the handle that resizes them:
        // drag it, and the sidebar follows the mouse; double-click, and the
        // default width is back. The bar only shows itself under the cursor —
        // the cursor's own change of shape is the invitation.
        //
        // The seam takes no width beyond the line itself, so the sidebar's
        // wash on one side and the note's toolbar on the other both run into
        // it and no strip of the card is left showing between them. The width
        // belongs to the grab area instead, which is centred on the line and
        // overhangs both panes — hence the z, which lifts it over the note
        // pane laid out after it.
        Item {
          id: splitter
          visible: !root.listCollapsed
          width: Style.spacing.hairline
          height: parent.height
          z: 1

          Rectangle {
            anchors.fill: parent
            color: Util.alpha(root.foreground,
                              splitterArea.pressed ? 0.35 : (splitterArea.containsMouse ? 0.22 : 0.08))
            Behavior on color { ColorAnimation { duration: 120 } }
          }

          MouseArea {
            id: splitterArea
            width: Style.space(8)
            x: (parent.width - width) / 2
            height: parent.height
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            acceptedButtons: Qt.LeftButton
            // Where in the handle the drag was started, measured from the list
            // edge it moves: the width follows the mouse by that offset, so a
            // press anywhere on the handle takes hold of the edge where it is
            // instead of snapping it under the cursor.
            property real grabOffset: 0
            onPressed: function(mouse) {
              grabOffset = splitterArea.mapToItem(body, mouse.x, 0).x - list.width
            }
            // The area moves with the list edge it is dragging, so the mouse
            // is mapped into the body each time rather than trusted locally.
            onPositionChanged: function(mouse) {
              if (!pressed) {
                return
              }
              root.listWidth = splitterArea.mapToItem(body, mouse.x, 0).x - grabOffset
            }
            onReleased: root.saveState()
            onDoubleClicked: { root.listWidth = 0; root.saveState() }
          }
        }

        // The note and, along its bottom, the view bar. The bar belongs to
        // the note pane rather than the window, so the sidebar and its
        // splitter run the full height beside both; with the sidebar
        // folded away the pane is the whole width.
        Column {
          id: notePane
          width: parent.width - (list.visible ? list.width + splitter.width : 0)
          height: parent.height
          spacing: 0

          NoteEditor {
            id: editor
            width: parent.width
            height: parent.height - viewBar.height
            markdown: markdownService
            clipboard: clipboardService
            canImages: { var p = root.providerOf(root.currentPath); return p ? p.canImages === true : false }
            hasNote: root.currentPath !== ""
            plain: { var p = root.providerOf(root.currentPath); return p ? !p.markdown : false }
            hasTitle: { var p = root.providerOf(root.currentPath); return p ? p.hasTitle : true }
            enabledTools: { var p = root.providerOf(root.currentPath); return (p && p.tools !== undefined) ? p.tools : null }
            toolbarLayout: root.config.editor.toolbar
            modifiedText: {
              for (var i = 0; i < root.rows.length; i++) {
                var row = root.rows[i]
                if (row.kind === "note" && row.path === root.currentPath) {
                  var time = Sidebar.timestamp(row.modified)
                  return time ? Qt.formatDateTime(new Date(time), "d MMMM yyyy 'at' HH:mm") : ""
                }
              }
              return ""
            }
            placeholder: root.loadingPath && root.loadingPath === root.currentPath ? "Loading…"
              : (root.rows.length === 0 && !root.filterText ? "No notes yet — press ctrl+n to create one." : "")
            foreground: root.foreground
            accent: root.accent
            background: root.background
            fontFamily: root.interfaceFont
            noteFontFamily: root.noteFont
            bodyFontSize: root.noteFontSize
            shortcutHandler: root.handleShortcut
            onEdited: root.onEdited()
            onLinkOpenRequested: function(url) {
              if (!Qt.openUrlExternally(url)) {
                root.showStatus("Could not open link")
              }
            }
            onStatusRequestedTextChanged: if (statusRequestedText) {
              root.showStatus(statusRequestedText)
              statusRequestedText = ""
            }
          }

          // ---- view bar
          ViewBar {
            id: viewBar
            width: parent.width
            // The outer corner is the card's; the inner one, against the
            // sidebar, is square — unless the sidebar is folded away and the
            // bar runs the whole width.
            leftRadius: root.listCollapsed ? root.chromeRadius : 0
            rightRadius: root.chromeRadius
            listCollapsed: root.listCollapsed
            onListToggled: root.toggleList()
            sourceName: root.sourceName
            sourceLogo: root.sourceLogo
            sourceInk: root.sourceInk
            sourceBase: root.sourceBase
            crumb: root.currentCrumb
            // Providers describe storage; the host supplies transient states.
            storage: {
              if (!root.currentPath) {
                return ""
              }
              if (root.loadingPath === root.currentPath) {
                return "loading…"
              }
              if (editor.readOnly) {
                return "read-only here"
              }
              var p = root.providerOf(root.currentPath)
              return p && typeof p.storageLabel === "function" ? p.storageLabel(root.currentPath) : ""
            }
            unsaved: root.dirty || (root.saveRevision >= 0 && root.saveInFlight(root.currentPath))
            statusText: root.statusText
            hoveredLink: editor.hoveredLink
            wordCount: editor.wordCount
            countVisible: root.currentPath !== "" && !editor.showingNotice
            background: root.background
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.interfaceFont
            fontSize: root.captionFontSize
          }
        }
      }

      // ---- the pages, in the workspace's place: everything under the title
      // bar, so the bar itself stays live and its tabs stay reachable. Only
      // one is ever opened (root.page), and each is laid out as if it were
      // the only one, since the other takes no space while it is not.
      TextPage {
        id: settingsPage
        width: parent.width
        height: parent.height - titleBar.height
        opened: root.page === "settings"
        title: "Settings"
        subtitle: root.configPath
        bodyText: JSON.stringify(root.config, null, 2)
        actionText: "Save"
        actionTooltip: "Write this to the config file (ctrl+s). The page stays open"
        cornerRadius: root.chromeRadius
        background: root.background
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.interfaceFont
        onCloseRequested: root.closePage()
        // Saving does not close the page: the config is a file you edit,
        // not a question you answer, and a bad key is easiest to fix while
        // the text that holds it is still in front of you.
        onActionRequested: function(text) {
          settingsPage.showNotice("Saving…", false)
          root.applySettingsJson(text, function(result) {
            settingsPage.showNotice(result.error || "Saved.", !!result.error)
          })
        }
      }

      // The key bindings have only something to show, so the page locks its
      // text and carries no action — and the foot goes with it, giving the
      // height back to the listing.
      TextPage {
        id: keysPage
        width: parent.width
        height: parent.height - titleBar.height
        opened: root.page === "keys"
        title: "Key bindings"
        subtitle: "Getting around your notes without reaching for the mouse"
        bodyText: KeyBindings.text(editor.tools.shortcutActions)
        readOnly: true
        cornerRadius: root.chromeRadius
        background: root.background
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.interfaceFont
        onCloseRequested: root.closePage()
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
      fontFamily: root.interfaceFont
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
      width: Math.min(Math.max(Style.space(900), Math.round(panel.width * 0.90)), panel.width - Style.gapsOut * 2)
      height: Math.min(Math.max(Style.space(600), Math.round(panel.height * 0.90)), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec

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
    onVisibleChanged: {
      if (!visible && root.opened && root.detached) {
        root.dismiss()
      }
    }

    FocusScope {
      anchors.fill: parent
      focus: true
      Item {
        id: floatingHost
        anchors.fill: parent
      }
    }
  }
}
