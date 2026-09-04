import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ui"
import "ui/TabColors.js" as TabColors
import "ui/KeyBindings.js" as KeyBindings
import "services/clipboard" as Clipboard
import "services/markdown" as Markdown
import "services/microsoft" as Microsoft
import "services/requests" as Requests

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
  property bool deleteConfirmOpen: false
  // Which page stands in for the workspace, by name — "" while the notes
  // themselves are on screen. A name rather than a flag each, so two pages
  // cannot both believe they are the one being looked at.
  property string page: ""
  readonly property bool pageOpen: root.page !== ""
  property string filterText: ""
  property string statusText: ""

  // The view bar's source chip names the provider whose tab is open — the
  // provider's own `name`, its logo when it ships one, in the open tab's
  // ink. Set in rebuildRows beside the tabs themselves, so the chip and the
  // rail cannot disagree about which tab that is. Before any provider has
  // listed, the app's own name stands in.
  property string sourceName: "Note Note"
  property url sourceLogo: ""
  property color sourceBase: "transparent"
  readonly property color sourceInk: sourceBase.a > 0
    ? Qt.tint(foreground, Util.alpha(sourceBase, TabColors.inkAlpha())) : foreground

  // Current note. `loadingNote` guards against editor change signals firing
  // a save while a note is being swapped in.
  property string currentPath: ""
  property bool loadingNote: false
  // The open note's load ended in an error and the pane is showing nothing.
  // Retried on the next open() — a queued read is dropped when the window
  // hides, so this is the ordinary way a hidden window ends a load.
  property bool loadFailed: false
  property bool dirty: false
  property string currentCrumb: ""
  property string loadingPath: ""
  // The pending load's cancel handle — null when there is none, or when the
  // provider answered without one (a cache hit, a sync provider). Cancelling
  // withdraws only a read still queued in the provider's lane; one already in
  // flight lands anyway, and the path guard on its callback drops it.
  property var loadHandle: null

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
  readonly property string interfaceFont: "sans-serif"

  // ── shell contract ──────────────────────────────────────────────────
  function open(payloadJson) {
    root.opened = true
    root.deleteConfirmOpen = false
    root.page = ""
    root.pauseQueues(false)
    // A save that failed while nobody was looking is reported now, once.
    if (root.missedSaveNotice) { root.showStatus(root.missedSaveNotice); root.missedSaveNotice = "" }
    // A note whose load never landed — the window closed over it, or the
    // backend was busy — would otherwise sit blank and read-only until the
    // user picked something else and came back. Ask again.
    if (root.currentPath && root.loadFailed) root.reloadCurrent()
    // Not while a sign-in is under way: entering its device code means
    // switching to a browser, which can hide and reopen this overlay — that
    // must not wipe the very code the user is about to type in.
    if (!root.accounts.some(function(a) { return a.loggingIn })) editor.clearNotice()
    for (var a = 0; a < root.accounts.length; a++) root.accounts[a].refresh()
    for (var i = 0; i < root.providers.length; i++) { root.providers[i].refresh(); if (typeof root.providers[i].watch === "function") root.providers[i].watch(true) }
    Qt.callLater(function() { editor.focusEditor() })
  }
  function stopWatching() { for (var i = 0; i < root.providers.length; i++) if (typeof root.providers[i].watch === "function") root.providers[i].watch(false) }
  function close() { root.flushSave(); root.opened = false; stopWatching(); root.pauseQueues(true) }
  function dismiss() {
    root.flushSave()
    root.opened = false
    stopWatching()
    root.pauseQueues(true)
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

  // A page stands in for the workspace, so it is not dismissed the way a
  // dialog is: what closes it is asking to see notes again — its own ✕,
  // Escape, or a notebook tab in the bar above it. Opening one while another
  // is up simply swaps them; there is only ever the one.
  function openPage(name) { root.page = name }
  function closePage() {
    if (!root.pageOpen) return
    root.page = ""
    // The editor is only just visible again; let the frame that reveals it
    // finish before handing it the keyboard.
    Qt.callLater(function() { editor.focusEditor() })
  }
  // The page on screen, or null for the notes. One place to ask, so another
  // page is a row in the menu and a line here rather than a flag threaded
  // through the layout.
  function currentPage() {
    if (root.page === "settings") return settingsPage
    if (root.page === "keys") return keysPage
    return null
  }

  function goBack() {
    if (titleBar.searchFocused) {
      if (root.filterText.length > 0) { root.clearSearch() }
      else if (!root.detached) root.dismiss()
      return
    }
    if (root.detached) titleBar.focusSearch()
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
  // Providers get their own Microsoft sign-in (own registration, own token,
  // own scopes) from the shared service code:
  // services.microsoft.create(providerId, scopes, clientId).
  property var accounts: []
  function copyText(s) { Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", s]) }
  function createMicrosoftAccount(owner, scopes, clientId) {
    // A provider recreated on a settings change asks for its account again;
    // the one its old instance left behind would otherwise stay in the list,
    // costing a status process on every open for nobody.
    root.accounts = root.accounts.filter(function(a) { if (a.owner !== owner) return true; a.destroy(); return false })
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
    acc.updated.connect(function() { if (acc.signedIn && editor.noticeTitle === "Signed in") editor.clearNotice(); root.rebuildRows() })
    root.accounts = root.accounts.concat([acc])
    // An account knows its own status from birth, not from the next open():
    // a provider made while the window is already open (a settings change)
    // would otherwise sit at "not signed in" until the overlay is summoned
    // again, since open() is the only other thing that asks.
    acc.refresh()
    return acc
  }
  Component { id: accountComponent; Microsoft.Account {} }

  // A link is blue, the one colour convention every reader already knows —
  // but no single blue is readable on both a light and a dark theme: the
  // best one manages 3.7:1 against white and black alike, short of the 4.5
  // body text wants. So the hue is fixed and the lightness is not. The
  // theme's own text colour, leaned four-fifths of the way to blue, reads as
  // blue on any theme and brings the foreground's contrast with it — the
  // same rule as a tab's ink, and no question asked about which theme is on.
  readonly property string linkColour: Qt.tint(root.foreground, Util.alpha("#4282d7", 0.8)).toString()

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
  readonly property string codeChipColour: Qt.tint(root.background, Util.alpha(root.foreground, 0.07)).toString()

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
    if (provider && provider.name) root.queueNames[key] = provider.name
    if (root.queues[key]) return root.queues[key]
    var q = queueComponent.createObject(root, { domain: key, paused: !root.opened })
    if (!q) { console.warn("note-note: could not create a request queue for", key); return null }
    root.queues[key] = q
    root.queueList = root.queueList.concat([q])
    q.updated.connect(function() { root.queueRevision++ })
    return q
  }
  function cancelQueuedFor(owner) {
    for (var i = 0; i < root.queueList.length; i++) root.queueList[i].cancelOwner(owner)
  }
  // Hidden: reads and polls stop, as they always have. Queued *writes* keep
  // draining — a save this app already accepted is finished, or fails out
  // loud, even if the window closed meanwhile (docs/business-requirements.md).
  function pauseQueues(paused) {
    for (var i = 0; i < root.queueList.length; i++) root.queueList[i].paused = paused
  }
  // Of the parked lanes, the one with the longest still to wait — or null.
  // Bound through queueRevision because a plain JS object is invisible to a
  // binding.
  function coolingQueue() {
    var worst = null
    for (var i = 0; i < root.queueList.length; i++) {
      var q = root.queueList[i]
      if (q.cooling && (worst === null || q.cooldownRemaining > worst.cooldownRemaining)) worst = q
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
      if (!q) return
      var lead = (root.queueNames[q.domain] || q.domain) + " is rate-limited"
      // Something else is being said — a save's error, "Section created". Let
      // it have its few seconds; the countdown picks up when it clears.
      if (root.statusText && root.statusText.indexOf(lead) !== 0) return
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
    if (!path) return null
    var pid = path.substring(0, path.indexOf(":"))
    for (var i = 0; i < root.providers.length; i++) if (root.providers[i].id === pid) return root.providers[i]
    return null
  }
  function providerById(id) { return providerOf(id + ":") }
  // The provider of the open tab. Section keys start with the provider's id.
  function activeProvider() { var k = activeKey(); return k ? providerById(k.substring(0, k.indexOf("/"))) : null }
  // The provider a "New notebook…" would go to: the open tab's — or, when it
  // cannot and the local provider has no notebook at all yet (a fresh
  // ~/Notes), the local one. Without that a fresh install has no tab that can
  // create, so no path to the first notebook.
  function notebookMaker() {
    var p = activeProvider()
    if (p && p.canCreateSection === true) return p
    var local = providerById("local")
    return local && local.canCreateSection === true && local.sections.length === 0 ? local : null
  }
  function canCreateNotebook() { return notebookMaker() !== null }

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
      if (k === "enabled" || !(k in p)) continue
      try { p[k] = entry[k] } catch (e) { console.warn("note-note: provider", p.id, "setting", k, "was not taken:", e.message) }
    }
  }
  function addProvider(url) {
    var comp = Qt.createComponent(url)
    if (comp.status === Component.Error) { console.warn("note-note: provider failed:", url, comp.errorString()); return null }
    var p = comp.createObject(root, { host: root, services: root.services })
    if (!p || !p.id) { console.warn("note-note: provider has no id:", url); return null }
    root.applyProviderSettings(p)
    p.updated.connect(function() { root.rebuildRows() })
    p.statusRequested.connect(function(t) { root.showStatus(t) })
    p.noticeRequested.connect(function(title, text, code, actions) { editor.showNotice(title, text, code, actions) })
    p.noticeCleared.connect(function() { editor.clearNotice() })
    p.viewRequested.connect(function(title, component, props) { editor.showNotice(title, " ", "", []); editor.showView(component, props) })
    p.viewCleared.connect(function() { editor.clearNotice() })
    p.persistRequested.connect(function() { root.saveState() })
    // The provider asking for the write it was told about. Answered for the
    // open note only, since the text to be written is the editor's — and it
    // costs nothing when the note has already gone (a switch, a close, a
    // delete all flush it), because flushSave has nothing to do for a note
    // that is not dirty. That is what lets a provider's schedule fire late
    // without the host having to reach back and cancel it.
    if (p.saveRequested) p.saveRequested.connect(function(path) {
      if (path === root.currentPath) root.flushSave()
    })
    if (p.noteChanged) p.noteChanged.connect(function(path) {
      if (path === root.currentPath && !root.dirty && !root.saveInFlight(path) && !root.loadingNote) root.reloadCurrent()
    })
    if (root.providerState[p.id]) p.restoreState(root.providerState[p.id])
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
    for (var i = 0; i < order.length; i++) rank[order[i]] = i
    var ranked = [], rest = []
    for (var j = 0; j < ids.length; j++) (rank.hasOwnProperty(ids[j]) ? ranked : rest).push(ids[j])
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
    for (var e = 0; e < entries.length; e++) urls[entries[e].id] = entries[e].url
    root.providerUrls = urls
    var ids = root.orderProviderIds(entries.map(function(x) { return x.id }), root.config)
    for (var u = 0; u < ids.length; u++)
      if (root.providerEnabledIn(root.config, ids[u]))
        root.addProvider(root.providerUrls[ids[u]])
    root.providersLoaded = true
    if (root.opened) root.open("{}")
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
    if (root.pendingExternalDirs === null || !root.configReady) return
    root.loadProviders(root.pendingExternalDirs)
  }

  function defaultConfig() {
    return {
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
    var d = root.defaultConfig(), out = {}
    for (var k in parsed) out[k] = parsed[k]
    var mergedProviders = {}
    var src = (parsed && typeof parsed.providers === "object" && parsed.providers) || {}
    for (var id in src) mergedProviders[id] = src[id]
    for (var did in d.providers) {
      var entry = mergedProviders[did] || {}, filled = {}
      for (var ek in entry) filled[ek] = entry[ek]
      for (var dk in d.providers[did]) if (!(dk in filled)) filled[dk] = d.providers[did][dk]
      mergedProviders[did] = filled
    }
    out.providers = mergedProviders
    return out
  }
  function providerEnabledIn(cfg, id) {
    var p = cfg && cfg.providers, e = p && p[id]
    return !(e && e.enabled === false)   // absent or malformed => enabled
  }
  function loadConfig(raw) {
    var trimmed = (raw || "").replace(/^\s+|\s+$/g, "")
    if (trimmed.length === 0) {
      // readfile.py prints "" for both "missing" and "genuinely empty" —
      // both mean first run: write the defaults now, so the file is
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
        console.warn("note-note: config file is invalid JSON, using defaults for this session:", e.message)
        root.config = root.defaultConfig()
      }
    }
    root.configReady = true
    root.maybeLoadProviders()
  }
  // ~/.config/notenote/ is this plugin's own, brand-new directory — unlike
  // ~/.local/state/omarchy/ it won't exist on a fresh install, and FileView
  // does not create parents — so every write mkdir -p's first, the same
  // shape as providers/local/Provider.qml's mkdirProc before a new notebook.
  property string pendingConfigWrite: ""
  function writeConfig(cfg) {
    root.pendingConfigWrite = JSON.stringify(cfg, null, 2) + "\n"
    configDirProc.command = ["mkdir", "-p", "--", root.configDir]
    configDirProc.running = true
  }
  Process {
    id: configDirProc
    onExited: { configFile.setText(root.pendingConfigWrite); root.pendingConfigWrite = "" }
  }
  FileView { id: configFile; path: root.configPath; atomicWrites: true; printErrors: false }

  readonly property int maxConfigBytes: 1024 * 1024
  Process {
    id: configRead
    command: ["python3", root.readScript, root.configPath, String(root.maxConfigBytes + 1)]
    stdout: StdioCollector {
      onStreamFinished: {
        if (this.text.length > root.maxConfigBytes) { console.warn("note-note: config file too large, using defaults"); root.loadConfig(""); return }
        root.loadConfig(this.text)
      }
    }
  }

  // The settings dialog's one entry point: validate, write exactly what was
  // typed (so what's on disk is honestly what was saved — no silent key
  // revival), then bring live providers in line with the new enabled set.
  function applySettingsJson(text) {
    var parsed
    try { parsed = JSON.parse(text) } catch (e) { return { ok: false, error: "Invalid JSON: " + e.message } }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
      return { ok: false, error: "Invalid JSON: the top level must be an object" }
    var oldConfig = root.config
    var merged = root.mergeConfigDefaults(parsed)
    root.config = merged
    root.writeConfig(parsed)
    root.applyProviderDiff(oldConfig, merged)
    return { ok: true }
  }
  function applyProviderDiff(oldConfig, newConfig) {
    for (var id in root.providerUrls) {
      var was = root.providerEnabledIn(oldConfig, id)
      var now = root.providerEnabledIn(newConfig, id)
      // A provider that stayed enabled but whose own settings changed (a new
      // notesDir, say) is recreated too — nothing here hot-patches a live
      // provider's directory, watcher and already-loaded notebooks, so a
      // fresh instance is the simplest correct way to make that take.
      var settingsChanged = was && now &&
        JSON.stringify((oldConfig.providers || {})[id]) !== JSON.stringify((newConfig.providers || {})[id])
      if (was === now && !settingsChanged) continue
      if (was && root.providerById(id)) root.disableProviderInstance(id)
      if (now) {
        // addProvider() alone leaves a provider empty: at startup, listing
        // is what open()'s own loop over root.providers triggers, but the
        // overlay is already open by the time Settings can be reached, so
        // that loop has already run and won't run again on its own.
        var p = root.addProvider(root.providerUrls[id])
        if (p) { p.refresh(); if (typeof p.watch === "function") p.watch(true) }
      }
    }
    // Reorders the tabs of providers that were already loaded too, not only
    // ones just added/removed — moving a name in the config moves its tab.
    var byId = {}
    for (var i = 0; i < root.providers.length; i++) byId[root.providers[i].id] = root.providers[i]
    var ids = root.orderProviderIds(root.providers.map(function(x) { return x.id }), newConfig)
    root.providers = ids.map(function(pid) { return byId[pid] })
    root.rebuildRows()
    root.saveState()
  }
  function disableProviderInstance(id) {
    var kept = [], target = null
    for (var i = 0; i < root.providers.length; i++) {
      if (root.providers[i].id === id) target = root.providers[i]
      else kept.push(root.providers[i])
    }
    if (!target) return
    var cur = root.providerOf(root.currentPath)
    if (cur && cur.id === id) root.selectPath("")
    root.providers = kept
    target.destroy()
  }

  // ── sidebar rows ────────────────────────────────────────────────────
  property var rows: []
  property int revision: 0
  // How many times the list has actually been handed a new model, as against
  // how many times rebuildRows ran (`revision`). The two used to be the same
  // number and should not be: every write here throws away every delegate.
  property int rowWrites: 0
  property bool pickedInitial: false
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
  function sectionKey(p, s) { return p.id + "/" + s.key }
  function sectionKeys() { var out = []; eachSection(function(p, s, k) { out.push(k) }); return out }
  // What the rail actually opens: the stored tab while it exists, else the
  // first section listed. Providers are registered local-first (loadProviders),
  // so a missing or stale tab lands on the user's own files without the host
  // naming any provider here.
  function activeKey() {
    var keys = sectionKeys()
    if (keys.indexOf(root.activeSection) >= 0) return root.activeSection
    return keys.length ? keys[0] : ""
  }
  function eachSection(fn) {
    for (var p = 0; p < root.providers.length; p++) {
      var prov = root.providers[p], secs = prov.sections || []
      for (var s = 0; s < secs.length; s++) fn(prov, secs[s], sectionKey(prov, secs[s]))
    }
  }
  // `persist: false` is for switches the user did not ask for (a search
  // hopping to the tab that has hits): they are not worth a state-file write
  // per keystroke, and not the tab to come back to next run.
  function setActiveSection(key, persist) {
    if (!key || key === activeKey()) return
    // Switching tabs is engagement: from here on no note is picked unasked.
    root.pickedInitial = true
    // Opening another notebook puts the one you were reading away: a note from
    // a tab you have left is not what the panel beside it is showing. Unsaved
    // edits are flushed on the way out.
    selectPath("")
    root.activeSection = key
    root.switchingTab = true
    rebuildRows()
    if (persist !== false) saveState()
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
  function matchesQuery(r, q) {
    return (r.title || "").toLowerCase().indexOf(q) >= 0 || (r.preview || "").toLowerCase().indexOf(q) >= 0
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
  function runContentSearch() {
    // One character is not a content query: title matching already answers
    // it, and a body holding some letter is every body there is.
    var q = root.filterText
    if (q.length < 2 || !root.searchContent) return
    root.searchSeq++
    // Everyone about to be asked is owed from before the first ask goes out:
    // a provider that answers within its own call (sticky) then clears its
    // entry mid-loop, which is just an answer arriving early.
    var waiting = {}
    for (var i = 0; i < root.providers.length; i++)
      if (typeof root.providers[i].search === "function") waiting[root.providers[i].id] = true
    root.searchWaiting = waiting
    for (var j = 0; j < root.providers.length; j++) askProvider(root.providers[j], q, root.searchSeq)
  }
  function askProvider(p, q, seq) {
    if (typeof p.search !== "function") return
    p.search(q, function(r) {
      if (seq !== root.searchSeq || !root.filterText) return
      var waiting = {}
      for (var w in root.searchWaiting) if (w !== p.id) waiting[w] = root.searchWaiting[w]
      root.searchWaiting = waiting
      var set = {}, paths = (r && r.paths) || []
      for (var j = 0; j < paths.length; j++) set[paths[j]] = true
      var hits = {}
      for (var k in root.contentHits) hits[k] = root.contentHits[k]
      hits[p.id] = set
      root.contentHits = hits
      rebuildRows()
      searchLanding()
    })
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
    var keep = root.switchingTab ? 0 : list.scrollOffset(), out = [], tabs = [], hits = {}, active = activeKey()
    var q = root.filterText.toLowerCase()
    root.switchingTab = false
    // The providers' content answers, flattened once for the whole pass.
    var contentSet = {}
    for (var ph in root.contentHits) { var pm = root.contentHits[ph]; for (var cp in pm) contentSet[cp] = true }
    eachSection(function(prov, s, key) {
      var all = s.rows || []
      // Every tab counts its own hits, the closed ones included — that is what
      // the number on a tab says while a search is running. A search reads
      // every note the section holds, not only the rows its tree is showing:
      // a provider whose rows fold away (OneNote) lists them all in s.notes,
      // for the rest the note rows already are all of them.
      var notes = q ? s.notes || all.filter(function(r) { return r.kind === "note" }) : all
      var found = q ? notes.filter(function(r) { return matchesQuery(r, q) || contentSet[r.path] === true }) : []
      tabs.push({ key: key, name: s.name, color: s.color || "", logo: prov.logo || "",
                  count: s.count !== undefined ? s.count : all.filter(function(r) { return r.kind === "note" }).length })
      hits[key] = found.length
      if (key !== active) return
      if (q) {
        for (var i = 0; i < found.length; i++) out.push(row(prov, key, found[i]))
        return
      }
      for (var j = 0; j < all.length; j++) out.push(row(prov, key, all[j]))
    })
    // The tabs themselves change rarely (a notebook made, a colour given); the
    // hit counts change per keystroke. Keeping the model still while only the
    // counts move is what keeps the rail from rebuilding its delegates.
    var newTabs = decollide(tabs)
    if (JSON.stringify(newTabs) !== JSON.stringify(root.tabs)) root.tabs = newTabs
    root.tabMatches = hits
    // The same rule as the tabs above, and for a stronger reason: the rows sit
    // behind a DelegateModel, so assigning one is not an update to a list but
    // a different list — every delegate is destroyed and built again (see
    // ui/NoteList.qml, which says the same thing about a write mid-drag).
    // This function runs six times over a single open, as each provider's
    // refresh, OneNote's cached read and then its listing, and the account's
    // own refresh each land, and all six almost always produce exactly the
    // rows already on screen. Six identical models handed to the list, six
    // sets of delegates thrown away and remade, is what the flicker was.
    var rowsChanged = JSON.stringify(out) !== JSON.stringify(root.rows)
    if (rowsChanged) { root.rows = out; root.rowWrites++ }
    // The view bar's source chip follows the open tab: its provider's name
    // and logo, and the tab's own colour — read from newTabs, where decollide
    // has just settled the colours the rail will wear.
    var provId = active.split("/")[0], sourceProv = null, sourceTab = null
    for (var pi = 0; pi < root.providers.length; pi++)
      if (root.providers[pi].id === provId) { sourceProv = root.providers[pi]; break }
    for (var ti = 0; ti < newTabs.length; ti++)
      if (newTabs[ti].key === active) { sourceTab = newTabs[ti]; break }
    root.sourceName = sourceProv ? sourceProv.name : "Note Note"
    root.sourceLogo = sourceProv ? (sourceProv.logo || "") : ""
    root.sourceBase = sourceTab ? TabColors.baseFor(sourceTab.color || "", sourceTab.name || "") : "transparent"
    // Only worth restoring when the list was actually rebuilt: a model that
    // never moved has kept its place already, and putting a remembered offset
    // back over it is one more jump for nothing — which is why this was worst
    // on a list scrolled down to a note in an open tree.
    if (rowsChanged && keep > 0) Qt.callLater(function() { list.setScrollOffset(keep) })
    // First open: land on the most recent note of the tab that opened —
    // whichever provider's tab that is. A tab whose notes have not listed yet
    // (OneNote is async) leaves the chance open for the rebuild that brings
    // them; the first tab switch or selection closes it (pickedInitial), so a
    // tab the user emptied on purpose is not refilled behind their back.
    if (!root.currentPath && !root.filterText && !root.pickedInitial) {
      for (var n = out.length - 1; n >= 0; n--) if (out[n].kind === "note") { selectPath(out[n].path); break }
    }
    // A note that vanished from its provider (deleted elsewhere, signed out)
    // is deselected; one merely sitting in another tab is kept.
    if (root.currentPath && !root.filterText && !noteExists(root.currentPath)) { selectPath(""); return }
    // The open note changed elsewhere (its version moved): reload it, unless
    // there are unsaved edits here.
    var v = versionOf(root.currentPath)
    if (root.currentPath && v && root.loadedVersion !== "" && v !== root.loadedVersion && !root.dirty && !root.saveInFlight(root.currentPath) && !root.loadingNote) reloadCurrent()
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
    root.noteLoadSeq++
    root.loadedVersion = versionOf(path)
    root.loadHandle = p.load(path, function(r) {
      if (root.currentPath !== path) return
      if (r.error) { root.loadingNote = false; root.loadFailed = true; return }
      root.loadFailed = false
      var pos = editor.cursorPosition()
      editor.documentBase = r.base || ""
      editor.setNote(r.title || "", r.body || "")
      editor.setCursorPosition(pos)
      editor.readOnly = r.editable === false
      root.loadingNote = false
      root.dirty = false
      showStatus(p.name + ": reloaded, changed elsewhere")
    }) || null
  }
  // A note is "in" its provider while a section shows its row — or holds it
  // in `notes`, the section's searchable whole: a folded tree hides the row
  // without the note going anywhere (PROVIDERS.md).
  function noteExists(path) {
    var found = false
    eachSection(function(prov, s, key) {
      if (found) return
      if ((s.rows || []).some(function(r) { return r.kind === "note" && r.path === path })) { found = true; return }
      if ((s.notes || []).some(function(n) { return n.path === path })) found = true
    })
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
    titleBar.setSearchText("")
    setFilter("")
    titleBar.focusSearch()
  }
  function setFilter(text) {
    var searchEnded = root.filterText.length > 0 && text.length === 0
    root.filterText = text
    // Content answers belong to the text they were asked for: a keystroke
    // makes them stale, so they go, and any reply still in flight with them
    // (searchSeq). The pause that follows the typing asks again.
    root.searchSeq++
    root.contentHits = ({})
    root.searchWaiting = ({})
    if (text.length > 0) contentSearchTimer.restart()
    else contentSearchTimer.stop()
    rebuildRows()
    searchLanding()
    // However the search ended — esc, the clear button, the text backspaced
    // away — the note it landed on should be in sight on the list that returns.
    if (searchEnded) revealCurrent()
  }
  // Where a search puts you, applied when the matches change — a keystroke,
  // or a provider's content answer arriving. Searching still spans every
  // tab: when the open one has nothing, move to the first that does, so a
  // keystroke always lands on something — without persisting the hop as the
  // user's chosen tab.
  function searchLanding() {
    if (!root.filterText) return
    if (root.rows.length === 0)
      for (var t = 0; t < root.tabs.length; t++)
        if ((root.tabMatches[root.tabs[t].key] || 0) > 0) { setActiveSection(root.tabs[t].key, false); break }
    if (rowIndexOf(root.currentPath) < 0)
      for (var i = 0; i < root.rows.length; i++) if (root.rows[i].kind === "note") { selectPath(root.rows[i].path); break }
  }
  // Puts the open note's row on screen. A provider whose tree can fold rows
  // away (OneNote) is first asked to unfold whatever hides it — revealPath is
  // optional in the provider contract — and its rebuild has already gone
  // through rebuildRows by the time it returns. The scroll waits a beat so the
  // list is laid out with the rows the reveal just added.
  function revealCurrent() {
    var p = providerOf(root.currentPath)
    if (!p) return
    if (typeof p.revealPath === "function") p.revealPath(root.currentPath)
    Qt.callLater(function() {
      var i = rowIndexOf(root.currentPath)
      if (i >= 0) list.positionViewAtIndex(i, ListView.Contain)
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
    for (var q = 0; q < root.queueList.length; q++)
      lanes.push({ key: root.queueList[q].domain, depth: root.queueList[q].depth,
                   cooling: root.queueList[q].cooling,
                   cooldown: Math.round(root.queueList[q].cooldownRemaining) })
    return JSON.stringify({ currentPath: root.currentPath, loadingPath: root.loadingPath, loadingNote: root.loadingNote,
                            status: root.statusText, readOnly: editor.readOnly, words: editor.wordCount, notice: editor.noticeTitle, viewFocused: editor.viewHasFocus,
                            dirty: root.dirty, saving: root.saveInFlight(root.currentPath), loadSeq: root.noteLoadSeq,
                            rows: root.rows.length, revision: root.revision, rowWrites: root.rowWrites,
                            offset: Math.round(list.scrollOffset()),
                            loadFailed: root.loadFailed, queues: lanes,
                            providers: root.providers.map(function(p) { return p.id }) })
  }
  // The provider whose section holds a row of this kind and id. The open
  // tab's answers first: row ids are bare strings ("logout", "refresh") that
  // several providers use, and a click always lands on the open tab — load
  // order must never pick a same-named row of another provider. Rows of
  // closed tabs still resolve, so IPC can drive any tab.
  function providerWithRow(kind, id) {
    var active = activeKey(), onActive = null, anywhere = null
    eachSection(function(prov, s, key) {
      if (!(s.rows || []).some(function(r) { return r.kind === kind && r.path === id })) return
      if (key === active && !onActive) onActive = prov
      if (!anywhere) anywhere = prov
    })
    return onActive || anywhere
  }
  function runAction(id) {
    var p = providerWithRow("action", id)
    if (p) p.action(id)
    return !!p
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
    var p = providerWithRow("tree", id)
    if (p) p.toggleTree(id)
    return !!p
  }

  // ── selection ───────────────────────────────────────────────────────
  // Withdraws the load the editor is waiting on, for when its answer no
  // longer matters: the user has stepped to another note, and a read the
  // queue still holds for the old one would only make the new one wait its
  // turn. Cancelling a load that already answered is a no-op by the queue's
  // design, so a stale handle is harmless.
  function cancelLoad() {
    var h = root.loadHandle
    root.loadHandle = null
    if (h) {
      h.cancel()
    }
  }

  function selectPath(path) {
    // Any selection pulls the list's keyboard cursor back to the note —
    // a click, a search landing, a tab switch putting the note away.
    root.treeCursor = ""
    // Any real selection — the user's or the first-open pick itself — ends
    // the first-open window (see rebuildRows).
    if (path) root.pickedInitial = true
    if (path === root.currentPath) return
    var p = providerOf(path)
    if (path && !p) return
    root.flushSave()
    editor.clearNotice()
    root.loadingNote = true
    root.noteLoadSeq++
    root.currentPath = path
    // Cancelled only now, after currentPath moved on: the cancelled answer —
    // or an in-flight read landing late — hits the path guard below and is
    // dropped, instead of reading as a failure of the note being opened.
    root.cancelLoad()
    root.currentCrumb = crumbOf(path)
    editor.readOnly = false
    editor.documentBase = ""
    if (!path) { editor.setNote("", ""); root.loadingNote = false; return }
    root.loadingPath = path
    editor.setNote("", "")
    editor.readOnly = true
    root.loadedVersion = ""
    root.loadHandle = p.load(path, function(r) {
      if (root.currentPath !== path) return
      root.loadingPath = ""
      if (r.error) { root.loadingNote = false; root.loadFailed = true; showStatus(p.name + ": " + r.error); return }
      root.loadFailed = false
      root.loadedVersion = r.version || versionOf(path)
      editor.documentBase = r.base || ""
      editor.setNote(r.title || "", r.body || "")
      editor.readOnly = r.editable === false
      root.loadingNote = false
      root.dirty = false
    }) || null
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
      if (r.kind !== "note" && r.kind !== "tree") { continue }
      if (atCursor(r)) { cur = idx.length }
      idx.push(i)
    }
    if (idx.length === 0) { return }
    var next = (cur + delta + idx.length) % idx.length
    if (cur < 0) { next = delta < 0 ? idx.length - 1 : 0 }
    var row = root.rows[idx[next]]
    if (row.kind === "tree") { root.treeCursor = row.path }
    else { selectPath(row.path) }
    list.positionViewAtIndex(idx[next], ListView.Contain)
  }
  function atCursor(r) {
    if (root.treeCursor) { return r.kind === "tree" && r.path === root.treeCursor }
    return r.kind === "note" && r.path === root.currentPath
  }
  function treeCursorIndex() {
    if (!root.treeCursor) { return -1 }
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].kind === "tree" && root.rows[i].path === root.treeCursor) { return i }
    }
    return -1
  }
  // Ctrl+Right opens the section under the cursor. Only that: with the
  // cursor on a note the key stays the editor's (jump a word right).
  function openTreeCursor() {
    var i = treeCursorIndex()
    if (i < 0) { return false }
    if (!root.rows[i].expanded) { treeToggle(root.rows[i].path) }
    return true
  }
  // Ctrl+Left walks up the tree: an open section closes, a closed one
  // yields to its parent, and from a note the cursor jumps to the section
  // that holds it. A note with no section above it leaves the key to the
  // editor.
  function closeTreeCursor() {
    var i = treeCursorIndex()
    if (i >= 0) {
      if (root.rows[i].expanded) { treeToggle(root.rows[i].path) }
      else { cursorToParent(i) }
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
    root.flushSave()
    if (root.filterText) { titleBar.setSearchText(""); setFilter("") }
    var p = providerId ? providerById(providerId) : providerOf(root.currentPath)
    if (p && target === undefined) target = p.createTargetFor(root.currentPath)
    if (!p || !target) { p = providerById("local"); target = p ? p.createTargetFor("") : "" }
    if (!p || !target) { root.startNewNotebook(); return }
    if (!p.canCreate) return
    p.create(target, function(r) {
      if (r.error) { showStatus(p.name + ": " + r.error); return }
      root.currentPath = ""
      // The fallback above may have filed the note in another provider's tab
      // (ctrl+n on a tab with no create target): open that tab, or the note
      // sits in the editor with no row anywhere on screen.
      var home = sectionKeyOf(r.path)
      if (home && home !== activeKey()) setActiveSection(home)
      selectPath(r.path)
      var mi = rowIndexOf(r.path)
      Qt.callLater(function() { if (mi >= 0) list.positionViewAtIndex(mi, ListView.Contain) })
      if (p.hasTitle) editor.focusTitle(); else editor.focusEditor()
    })
  }
  // The tab a note's row is on.
  function sectionKeyOf(path) {
    var found = ""
    eachSection(function(prov, s, key) {
      if (!found && (s.rows || []).some(function(r) { return r.kind === "note" && r.path === path })) found = key
    })
    return found
  }

  // "New notebook…" makes one inside the tab you are on, and only where the
  // provider says it can (canCreateSection — the local folders today). Which
  // tab the new notebook opens as is the provider's answer, not assumed here:
  // a tab of its own when the provider spreads notebooks into tabs, the one
  // tab that holds them all when it folds them (createSection's cb).
  function newNotebook(name) {
    var p = notebookMaker()
    if (!p) return
    p.createSection(name, function(r) {
      if (r.error) { showStatus(p.name + ": " + r.error); return }
      setActiveSection(p.id + "/" + r.key)
      // Where a note in the new section goes is the provider's to say.
      if (r.target) root.newNote(p.id, r.target)
    })
  }
  function startNewNotebook() {
    // The name field lives on the full list, not the search panel — and a
    // field inside a hidden panel would still steal the keyboard.
    if (root.filterText) clearSearch()
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
    root.cancelPendingSave(path)
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
    // A page owns the keyboard while it is up: its own Escape and action
    // shortcut come first, and nothing below reaches a workspace that is not
    // on screen. KeyBindings.js writes the navigation and note keys below out
    // for the user, and says there which of them it leaves unlisted.
    var openPage = root.currentPage()
    if (openPage) return openPage.handleKey(event)
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Escape) { root.goBack(); return true }
    if (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_L)) { titleBar.focusSearch(); return true }
    if (ctrl && event.key === Qt.Key_N) { if (event.modifiers & Qt.ShiftModifier) root.startNewNotebook(); else root.newNote(); return true }
    if (ctrl && event.key === Qt.Key_D) { root.requestDelete(root.currentPath); return true }
    if (ctrl && (event.key === Qt.Key_Down || event.key === Qt.Key_J)) { root.moveSelection(1); return true }
    if (ctrl && event.key === Qt.Key_Up) { root.moveSelection(-1); return true }
    // Ctrl+left/right drive the section tree the cursor is on. Shift and Alt
    // stay out so select-word survives, and a press with nothing to do (a
    // note with no parent) falls through to the editor's word jump.
    if (ctrl && !(event.modifiers & (Qt.ShiftModifier | Qt.AltModifier))) {
      if (event.key === Qt.Key_Right && root.openTreeCursor()) { return true }
      if (event.key === Qt.Key_Left && root.closeTreeCursor()) { return true }
    }
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
      // The editor decides whether this paste is a picture or text; with
      // Shift the source's formatting stays behind.
      if (event.key === Qt.Key_V) {
        if (event.modifiers & Qt.ShiftModifier) editor.pastePlain()
        else editor.paste()
        return true
      }
    }
    return false
  }

  // ── autosave ────────────────────────────────────────────────────────
  // The host says *that* the note changed; the provider says *when* it is
  // written. Only the provider knows what one of its writes costs: a file on
  // this disk can follow the typing closely, a note behind an API spends a
  // request every time and wants the typing to settle first, and a backend
  // with rules of its own may want a schedule neither of those describes —
  // longer while its lane is cooling, say, or none at all until something it
  // is waiting for arrives. So there is no interval here to read and no
  // provider named: `noteEdited` tells the provider, the provider keeps
  // whatever schedule it likes, and `saveRequested` asks for the write.
  //
  // A provider that takes no part — one written before this, one that simply
  // does not care — is written on the host's own default, so the least a
  // provider can be is still a provider that autosaves.
  //
  // What stays here is the handful of moments that are not a schedule at all:
  // the note is flushed when the app is about to lose the ability to save it
  // (a note switch, the window closing, a delete). That is "never lose a
  // note" rather than a cadence, and it is the host's to keep.
  readonly property int defaultSaveDebounce: 1500
  function onEdited() {
    if (root.loadingNote || !root.currentPath) return
    root.dirty = true
    var p = providerOf(root.currentPath)
    if (p && typeof p.noteEdited === "function") { p.noteEdited(root.currentPath); return }
    saveTimer.interval = root.defaultSaveDebounce
    saveTimer.restart()
  }
  Timer { id: saveTimer; interval: root.defaultSaveDebounce; onTriggered: root.flushSave() }

  // Ordering, retrying and coalescing saves is the provider's queue's job now
  // (services/requests/), so what is left here is only what the host knows:
  // which note is being saved, and whether the text it captured is still the
  // newest. There is no `saving` flag and no re-derivation of the body — the
  // payload is captured whole per dispatch, which is what stopped a save
  // requested during another one from writing the *wrong note's* text.
  //
  // A save passes through three states, and the note is unsaved in all of
  // them: the editor holds edits nobody has captured (`dirty`), the document
  // is being turned into Markdown, or the provider has the text and has not
  // answered. `dirty` is the open note's alone and is cleared where the
  // snapshot is taken, so a second flush cannot send the same text twice;
  // the two asynchronous states are counted per path, because a save outlives
  // the note being open. The count covers the conversion as well as the
  // request — a note whose text is inside a converter is not saved, and the
  // gap where it looked saved was both a dot that blinked off mid-save and a
  // window in which a change arriving from elsewhere was free to reload the
  // editor out from under the text about to be sent.
  property var saveEpoch: ({})       // path -> seq: drops a stale or cancelled conversion
  property var savesPending: ({})    // path -> count: converting, or in flight
  // Bumped with every savesPending move: a plain JS object is invisible to a
  // binding, and the view bar's unsaved dot watches saves through this — the
  // queues' queueRevision, said again for saves.
  property int saveRevision: 0
  // A save that failed while the window was hidden, held until it reopens.
  // In memory only: this is not an offline queue (business-requirements.md).
  property string missedSaveNotice: ""
  // Bumped by every load. A save captures it to tell, when its answer comes
  // back, whether the editor still holds the text that save was carrying.
  property int noteLoadSeq: 0

  function saveInFlight(path) { return (root.savesPending[path] || 0) > 0 }

  // Every move of the count goes through here: the count is what the unsaved
  // dot reads, and the revision beside it is what makes a plain object's
  // change visible to a binding at all.
  function markSaving(path, delta) {
    var n = (root.savesPending[path] || 0) + delta
    if (n > 0) root.savesPending[path] = n
    else delete root.savesPending[path]
    root.saveRevision++
  }

  // Nothing may be written back to this note any more — it is being deleted,
  // or its provider is going. Moving the epoch is what a conversion still
  // running will find when it answers, and it releases its own share of the
  // count then. A save already handed to the provider is past recall: it was
  // accepted, and an accepted save finishes (business-requirements.md).
  function cancelPendingSave(path) {
    if (!path) return
    root.saveEpoch[path] = (root.saveEpoch[path] || 0) + 1
  }

  function flushSave() {
    if (!root.dirty || !root.currentPath) return
    var path = root.currentPath, p = providerOf(path)
    if (!p) return
    if (editor.readOnly) { root.dirty = false; return }
    saveTimer.stop()
    var title = editor.title, loadSeq = root.noteLoadSeq
    // Cleared here, where the snapshot is taken: a keystroke after this one
    // marks the note dirty again and earns a save of its own, and a flush
    // arriving before the converter answers finds nothing left to send
    // rather than sending this same text a second time.
    root.dirty = false
    root.loadedVersion = ""
    var seq = (root.saveEpoch[path] || 0) + 1
    root.saveEpoch[path] = seq
    // Taken here and released on whichever of the three ways out this
    // attempt takes: the note is unsaved for the whole of it, and the
    // converter's share of that is not a gap in which it looks saved.
    root.markSaving(path, 1)
    // The document is rich text and the note is Markdown, so the body arrives
    // asynchronously — but requestMarkdown snapshots the document *now*, so
    // this text belongs to `path` even if the user moves to another note
    // before the converter answers.
    editor.requestMarkdown(function(body, ok) {
      // Superseded by a newer snapshot of this note, or cancelled with the
      // note itself: either way this text is not the one to write.
      if (root.saveEpoch[path] !== seq) { root.markSaving(path, -1); return }
      // The converter failed, so `body` is its empty answer and not the note.
      // Sending it would replace the note with nothing, which is the one
      // thing this app promises never to do.
      if (!ok) { root.markSaving(path, -1); root.saveFailed(path, seq, loadSeq, "the note could not be read for saving"); return }
      p.save(path, title, body, function(r) {
        root.markSaving(path, -1)
        // `{}` for a save the provider superseded as well as one that landed
        // (PROVIDERS.md): the newer save carries this one's intent and is
        // counted in its own right, so the note stays marked until it answers.
        if (r && r.error) { root.saveFailed(path, seq, loadSeq, p.name + ": " + r.error); return }
        if (r && r.warning) root.reportSave(p.name + ": " + r.warning)
      })
    })
  }

  // A save that did not land. The note goes back to being unsaved, so the
  // next flush carries it and the dot says so meanwhile — but only while the
  // editor still holds the text this save was carrying: the same note, no
  // reload over it, and no newer attempt that now owns the note's state.
  // Failing any of those there is nothing here left to carry, and marking it
  // would spend a request re-sending text that is gone or already on its way.
  //
  // Nothing reruns on its own: this is one note marked as what it is, not a
  // retry loop and not a queue (business-requirements.md).
  function saveFailed(path, seq, loadSeq, message) {
    if (path === root.currentPath && loadSeq === root.noteLoadSeq
        && root.saveEpoch[path] === seq && !editor.readOnly) root.dirty = true
    root.reportSave(message)
  }

  // Said now if anyone is looking, on the next open() otherwise.
  function reportSave(message) {
    if (root.opened) showStatus(message)
    else root.missedSaveNotice = message
  }

  // ── state ───────────────────────────────────────────────────────────
  function saveState() {
    var ps = {}
    for (var i = 0; i < root.providers.length; i++) ps[root.providers[i].id] = root.providers[i].saveState()
    // Kept live, not only on disk: a provider recreated on a settings change
    // (applyProviderDiff) is restored from providerState, which would
    // otherwise still hold the startup snapshot — and lose the fold state
    // made since.
    root.providerState = ps
    // version 3: the open tab, where 2 kept two lists of folded sections. An
    // older file simply has no `active`, and the first local notebook opens.
    var st = { version: 3, detached: root.detached, active: root.activeSection, providers: ps }
    if (root.listWidth > 0) st.listWidth = Math.round(root.listWidth)
    stateFile.setText(JSON.stringify(st, null, 2) + "\n")
  }
  function loadState(raw) {
    try {
      var s = JSON.parse(raw || "{}")
      if (s.detached === true) root.detached = true
      if (typeof s.active === "string") root.activeSection = s.active
      // The stored width is trusted only as a number; the list's own binding
      // clamps it against whatever window it wakes up in.
      if (typeof s.listWidth === "number" && isFinite(s.listWidth) && s.listWidth > 0) root.listWidth = s.listWidth
      if (s.providers) root.providerState = s.providers
    } catch (e) { /* a corrupt state file costs nothing */ }
    scanProviders.running = true
  }
  // The state file is the host's only input from disk; it holds a few flags
  // and ids. It is read exactly once, through one descriptor
  // (lib/readfile.py): no symlink following, regular files only, at most
  // maxStateBytes+1 bytes against a deadline — and those bytes are what gets
  // parsed. No size check followed by a reopen.
  readonly property int maxStateBytes: 1024 * 1024
  readonly property string readScript: Qt.resolvedUrl("lib/readfile.py").toString().replace(/^file:\/\//, "")
  Process {
    id: stateRead
    command: ["python3", root.readScript, root.statePath, String(root.maxStateBytes + 1)]
    stdout: StdioCollector {
      onStreamFinished: {
        if (this.text.length > root.maxStateBytes) { console.warn("note-note: state file too large, ignoring"); root.loadState(""); return }
        root.loadState(this.text)
      }
    }
  }
  Component.onCompleted: { stateRead.running = true; configRead.running = true }
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
        height: parent.height - titleBar.height - viewBar.height
        spacing: 0

        NoteList {
          id: list
          // The user's width when they have dragged the handle, the default
          // otherwise — clamped either way, so neither the list nor the note
          // can be squeezed out of use by a drag or a narrow window.
          width: {
            var w = root.listWidth > 0 ? root.listWidth : Style.space(230)
            return Math.max(Style.space(150), Math.min(w, body.width - Style.space(320)))
          }
          height: parent.height
          model: root.rows
          currentPath: root.currentPath
          treeCursor: root.treeCursor
          filtering: root.filterText.length > 0
          searchBusy: root.searchBusy
          sections: root.tabs
          activeKey: root.revision < 0 ? "" : root.activeKey()
          canCreateNotebook: root.revision < 0 ? false : root.canCreateNotebook()
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.interfaceFont
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
            root.rows = rr
            var p = root.providerOf(paths[0])
            if (p && p.canReorder) {
              p.setOrder(key.substring(p.id.length + 1), paths)
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
              if (!pressed) return
              root.listWidth = splitterArea.mapToItem(body, mouse.x, 0).x - grabOffset
            }
            onReleased: root.saveState()
            onDoubleClicked: { root.listWidth = 0; root.saveState() }
          }
        }

        NoteEditor {
          id: editor
          width: parent.width - list.width - splitter.width
          height: parent.height
          markdown: markdownService
          clipboard: clipboardService
          canImages: { var p = root.providerOf(root.currentPath); return p ? p.canImages === true : false }
          hasNote: root.currentPath !== ""
          plain: { var p = root.providerOf(root.currentPath); return p ? !p.markdown : false }
          hasTitle: { var p = root.providerOf(root.currentPath); return p ? p.hasTitle : true }
          enabledTools: { var p = root.providerOf(root.currentPath); return (p && p.tools !== undefined) ? p.tools : null }
          placeholder: root.loadingPath && root.loadingPath === root.currentPath ? "Loading…"
            : (root.rows.length === 0 && !root.filterText ? "No notes yet — press ctrl+n to create one." : "")
          foreground: root.foreground
          accent: root.accent
          background: root.background
          fontFamily: root.interfaceFont
          bodyFontFamily: root.interfaceFont
          shortcutHandler: root.handleShortcut
          onEdited: root.onEdited()
          // The note was read but could not be rendered, so the editor is
          // showing nothing of it. Held read-only with the reason said, the
          // way a note that could not be read at all is — an editable blank
          // is what autosave would write back over the note. loadFailed asks
          // for it again on the next open().
          onRenderFailed: {
            root.loadingNote = false
            root.dirty = false
            root.loadFailed = true
            editor.readOnly = true
            root.showStatus("This note could not be displayed — it has not been changed")
          }
          onStatusRequestedTextChanged: if (statusRequestedText) { root.showStatus(statusRequestedText); statusRequestedText = "" }
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
          var result = root.applySettingsJson(text)
          if (result.ok) settingsPage.showNotice("Saved.", false)
          else settingsPage.showNotice(result.error, true)
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
        bodyText: KeyBindings.text()
        readOnly: true
        cornerRadius: root.chromeRadius
        background: root.background
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.interfaceFont
        onCloseRequested: root.closePage()
      }

      // ---- view bar
      ViewBar {
        id: viewBar
        visible: !root.pageOpen
        width: parent.width
        cornerRadius: root.chromeRadius
        sourceName: root.sourceName
        sourceLogo: root.sourceLogo
        sourceInk: root.sourceInk
        sourceBase: root.sourceBase
        crumb: root.currentCrumb
        // The storage word: what the open note is, on the host's authority —
        // a local note is its file, a remote one is "synced online", and the
        // two transient states name themselves.
        storage: {
          if (!root.currentPath) return ""
          if (root.loadingPath === root.currentPath) return "loading…"
          if (editor.readOnly) return "read-only here"
          var p = root.providerOf(root.currentPath)
          return p && p.id === "local" ? root.currentPath.substring(root.currentPath.lastIndexOf("/") + 1) : "synced online"
        }
        unsaved: root.dirty || (root.saveRevision >= 0 && root.saveInFlight(root.currentPath))
        statusText: root.statusText
        wordCount: editor.wordCount
        countVisible: root.currentPath !== "" && !editor.showingNotice
        background: root.background
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.interfaceFont
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
      width: Math.min(Math.max(Style.space(900), Math.round(panel.width * 0.72)), panel.width - Style.gapsOut * 2)
      height: Math.min(Math.max(Style.space(600), Math.round(panel.height * 0.82)), panel.height - Style.gapsOut * 2)
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
    onVisibleChanged: { if (!visible && root.opened && root.detached) root.dismiss() }

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
