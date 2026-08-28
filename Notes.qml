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
  // Note-note's own settings — deliberately its own directory, not the
  // omarchy/note-note.json above (that one stays the Microsoft clientId
  // override). A raw JSON file the settings page reads and writes verbatim.
  readonly property string configDir: Quickshell.env("HOME") + "/.config/notenote"
  readonly property string configPath: root.configDir + "/config.json"

  property bool opened: false
  property bool detached: false
  // The sidebar width the user dragged the splitter to, in pixels, kept
  // across runs. 0 means they never did, and the default width stands.
  property real listWidth: 0
  property bool deleteConfirmOpen: false
  property bool settingsOpen: false
  property string filterText: ""
  property string statusText: ""

  // The header titles the provider whose tab is open — the provider's own
  // `name`, its logo when it ships one, in the open tab's ink. Set in
  // rebuildRows beside the tabs themselves, so the header and the rail
  // cannot disagree about which tab that is. Before any provider has
  // listed, the app's own name stands in.
  property string headerName: "Note Note"
  property url headerLogo: ""
  property color headerBase: "transparent"
  readonly property color headerInk: headerBase.a > 0
    ? Qt.tint(foreground, Util.alpha(headerBase, TabColors.inkAlpha())) : foreground

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

  // The frame hugs the notes: the app keeps a hair of padding inside its
  // border, so the notebook rail, the list and the note itself run out to
  // the edge. Only the header is held back — it takes the inset the whole
  // app used to have, minus the hair, and so looks exactly as it did.
  readonly property real appPadding: Math.max(1, Style.space(2))
  readonly property real headerPadding: Math.max(0, Style.spacing.panelPadding - appPadding)
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText

  // ── shell contract ──────────────────────────────────────────────────
  function open(payloadJson) {
    root.opened = true
    root.deleteConfirmOpen = false
    root.settingsOpen = false
    // Not while a sign-in is under way: entering its device code means
    // switching to a browser, which can hide and reopen this overlay — that
    // must not wipe the very code the user is about to type in.
    if (!root.accounts.some(function(a) { return a.loggingIn })) editor.clearNotice()
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
  function copyText(s) { Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", s]) }
  function createMicrosoftAccount(owner, scopes) {
    var acc = accountComponent.createObject(root, { owner: owner, scopes: ["offline_access", "User.Read"].concat(scopes || []).join(" ") })
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

  // Markdown on disk, rich text in the editor: everything the note pane shows
  // or saves passes through here (services/markdown/Markdown.qml).
  Markdown.Markdown {
    id: markdownService
    link: root.linkColour
    quoteInk: root.quoteInkColour
    codeBackground: root.codeBackgroundColour
  }

  // Pasting a picture into a note; only providers that can store one take it.
  Clipboard.Clipboard { id: clipboardService }
  readonly property var services: ({ microsoft: { create: function(owner, scopes) { return root.createMicrosoftAccount(owner, scopes) } } })

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

  function addProvider(url, extraProps) {
    var comp = Qt.createComponent(url)
    if (comp.status === Component.Error) { console.warn("note-note: provider failed:", url, comp.errorString()); return null }
    var props = { host: root, services: root.services }
    if (extraProps) for (var k in extraProps) props[k] = extraProps[k]
    var p = comp.createObject(root, props)
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
        root.addProvider(root.providerUrls[ids[u]], ids[u] === "local" ? { notesDir: root.localNotesDir() } : null)
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
      providers: {
        local: { enabled: true, notesDir: Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes") },
        sticky: { enabled: true },
        onenote: { enabled: true },
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
  // "~" and "~/…" expand against $HOME — this value reaches processes as a
  // literal argv entry, never through a shell, so nothing else would expand it.
  function expandHome(p) { return (p && p.charAt(0) === "~") ? Quickshell.env("HOME") + p.substring(1) : p }
  function localNotesDir() {
    var p = root.config.providers && root.config.providers.local
    return root.expandHome(p && p.notesDir) || (Quickshell.env("NOTE_NOTE_DIR") || (Quickshell.env("HOME") + "/Notes"))
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
        var extra = id === "local" ? { notesDir: root.localNotesDir() } : null
        var p = root.addProvider(root.providerUrls[id], extra)
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
    root.rows = out
    // The header follows the open tab: its provider's name and logo, and the
    // tab's own colour — read from newTabs, where decollide has just settled
    // the colours the rail will wear.
    var provId = active.split("/")[0], headerProv = null, headerTab = null
    for (var pi = 0; pi < root.providers.length; pi++)
      if (root.providers[pi].id === provId) { headerProv = root.providers[pi]; break }
    for (var ti = 0; ti < newTabs.length; ti++)
      if (newTabs[ti].key === active) { headerTab = newTabs[ti]; break }
    root.headerName = headerProv ? headerProv.name : "Note Note"
    root.headerLogo = headerProv ? (headerProv.logo || "") : ""
    root.headerBase = headerTab ? TabColors.baseFor(headerTab.color || "", headerTab.name || "") : "transparent"
    if (keep > 0) Qt.callLater(function() { list.setScrollOffset(keep) })
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
    return JSON.stringify({ currentPath: root.currentPath, loadingPath: root.loadingPath, loadingNote: root.loadingNote,
                            status: root.statusText, readOnly: editor.readOnly, words: editor.wordCount, notice: editor.noticeTitle, viewFocused: editor.viewHasFocus,
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
  function selectPath(path) {
    // Any real selection — the user's or the first-open pick itself — ends
    // the first-open window (see rebuildRows).
    if (path) root.pickedInitial = true
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
  // provider says it can: the local one, whose notebooks are folders and each
  // its own tab, so a new one opens the moment it exists. The others keep
  // their notebooks inside their single tab and are made where they live.
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
    if (root.settingsOpen) return settingsDialog.handleKey(event)
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
      spacing: Style.spacing.md

      // ---- header
      Item {
        width: parent.width
        height: headerInner.height + root.headerPadding

        // The app pads itself by a hair, so the header carries what is
        // left of the old inset on its own: the masthead, the search
        // field and the hints keep their distance from the frame, while
        // the list and the note below run out to the edge. Vertically the
        // inset is split around the content — the same air above it as
        // below, counting the column gap — so the band reads centered.
        Item {
          id: headerInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Math.max(0, (root.headerPadding + Style.spacing.md - root.appPadding) / 2)
          anchors.leftMargin: root.headerPadding
          anchors.rightMargin: root.headerPadding
          height: Math.max(searchField.height, titleText.implicitHeight)

          // The masthead is the open tab said large: the provider's mark, its
          // name, in the tab's own ink — so the header always answers "whose
          // notes am I looking at". Same reserved width whatever the name, so
          // the search field does not slide when tabs change.
          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(150)
            spacing: Style.spacing.sm

            Image {
              id: titleLogo
              visible: status === Image.Ready
              source: root.headerLogo
              anchors.verticalCenter: parent.verticalCenter
              width: Style.font.title
              height: Style.font.title
              sourceSize.width: Style.font.title * 2
              sourceSize.height: Style.font.title * 2
              fillMode: Image.PreserveAspectFit
              smooth: true
            }

            Text {
              id: titleText
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: titleRow.width - (titleLogo.visible ? titleLogo.width + titleRow.spacing : 0)
              text: root.headerName
              color: root.headerInk
              Behavior on color { ColorAnimation { duration: 150 } }
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
          }

          // The search sits in the middle of the band, the way a command bar
          // does — pushed right only when a narrow window would run it into
          // the masthead. It names its own shortcut: a keycap in the field
          // where the clear button will stand once there is something to
          // clear, so the right edge always says the one thing you can do.
          TextField {
            id: searchField
            x: Math.max(titleRow.width + Style.spacing.lg, (parent.width - width) / 2)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(340)
            placeholderText: "Search notes…"
            foreground: root.foreground
            accent: root.accent
            font.family: Style.font.menuFamily
            verticalPadding: Style.spacing.xs
            onTextEdited: root.setFilter(text)
            rightPadding: root.filterText.length > 0
              ? clearSearchButton.width + Style.spacing.xs
              : searchKeycap.width + Style.spacing.sm + Style.spacing.xs
            leftPadding: searchGlyph.width + Style.spacing.sm + Style.spacing.xs

            Rectangle {
              id: searchKeycap
              visible: root.filterText.length === 0
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              width: searchKeycapText.width + Style.spacing.sm * 2
              height: searchKeycapText.height + Style.spacing.xxs * 2
              // A square theme keeps its corners; a round one is capped where
              // a keycap stops looking like a key.
              radius: Math.min(Style.cornerRadius, height / 3)
              color: Util.alpha(root.foreground, 0.06)
              border.width: 1
              border.color: Util.alpha(root.foreground, 0.22)

              Text {
                id: searchKeycapText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "ctrl+k"
                color: Util.alpha(root.foreground, 0.6)
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }
            }

            // The magnifier says what the field is for, and stays while you
            // type — dimmed the standard way, a fade toward any background.
            Text {
              id: searchGlyph
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: Util.alpha(root.foreground, 0.55)
              font.family: Style.fontFamily
              font.pixelSize: Style.font.iconSmall
            }

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

          Button {
            id: settingsButton
            anchors.right: shapeButton.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰒓"
            tooltipText: "Settings — edit note-note's config as JSON (for now: which providers show up)"
            bordered: true
            selected: root.settingsOpen
            foreground: root.foreground
            accent: root.accent
            iconSize: Style.font.iconSmall
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xxs
            onClicked: root.settingsOpen = true
          }

          // The rest of the shortcuts, worn as keycaps rather than recited as a
          // sentence — search is not among them, because the field carries its
          // own. A status message borrows the whole slot while it shows, and a
          // window too narrow for every chip clips them from the left: the
          // rightmost ones survive, and they are the ones nearest the button
          // they explain.
          Item {
            anchors.left: searchField.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.spacing.md
            height: parent.height
            clip: true

            Row {
              visible: root.statusText.length === 0
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.lg

              Repeater {
                model: [{ keys: "ctrl+↑↓", what: "note" },
                        { keys: "ctrl+tab", what: "notebook" },
                        { keys: "ctrl+n", what: "new" },
                        { keys: "esc", what: "back" }]

                delegate: Row {
                  id: hintChip
                  required property var modelData
                  spacing: Style.spacing.xs

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: chipKeys.width + Style.spacing.sm * 2
                    height: chipKeys.height + Style.spacing.xxs * 2
                    radius: Math.min(Style.cornerRadius, height / 3)
                    color: Util.alpha(root.foreground, 0.06)
                    border.width: 1
                    border.color: Util.alpha(root.foreground, 0.22)

                    Text {
                      id: chipKeys
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: hintChip.modelData.keys
                      color: Util.alpha(root.foreground, 0.6)
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: hintChip.modelData.what
                    color: Util.alpha(root.foreground, 0.6)
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.statusText.length > 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.statusText
              color: Qt.tint(root.foreground, Util.alpha(root.accent, 0.6))
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignRight
            }
          }
        }
      }

      // ---- body
      Row {
        id: body
        width: parent.width
        height: parent.height - y
        spacing: 0

        NoteList {
          id: list
          // The user's width when they have dragged the handle, the default
          // otherwise — clamped either way, so neither the list nor the note
          // can be squeezed out of use by a drag or a narrow window.
          width: {
            var w = root.listWidth > 0 ? root.listWidth : Style.space(215) + list.railWidth
            return Math.max(list.railWidth + Style.space(140), Math.min(w, body.width - Style.space(320)))
          }
          height: parent.height
          model: root.rows
          currentPath: root.currentPath
          filtering: root.filterText.length > 0
          searchBusy: root.searchBusy
          sections: root.tabs
          matchCounts: root.tabMatches
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

        // The gap between list and note is also the handle that resizes them:
        // drag it, and the sidebar follows the mouse; double-click, and the
        // default width is back. The bar only shows itself under the cursor —
        // the cursor's own change of shape is the invitation.
        Item {
          id: splitter
          width: Style.spacing.lg
          height: parent.height

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(3)
            height: parent.height
            radius: width / 2
            color: Util.alpha(root.foreground, splitterArea.pressed ? 0.35 : 0.18)
            visible: splitterArea.containsMouse || splitterArea.pressed
          }

          MouseArea {
            id: splitterArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            acceptedButtons: Qt.LeftButton
            // The area moves with the list edge it is dragging, so the mouse
            // is mapped into the body each time rather than trusted locally.
            onPositionChanged: function(mouse) {
              if (!pressed) return
              root.listWidth = splitterArea.mapToItem(body, mouse.x, 0).x - splitter.width / 2
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

    SettingsDialog {
      id: settingsDialog
      anchors.fill: parent
      opened: root.settingsOpen
      z: 10
      initialText: JSON.stringify(root.config, null, 2)
      background: root.background
      foreground: root.foreground
      scrim: root.scrim
      accent: root.accent
      cornerRadius: Style.cornerRadius
      onCanceled: { root.settingsOpen = false; editor.focusEditor() }
      onSaveRequested: function(text) {
        var result = root.applySettingsJson(text)
        if (result.ok) { root.settingsOpen = false; editor.focusEditor() }
        else settingsDialog.showError(result.error)
      }
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
      padding: root.appPadding

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
        anchors.margins: root.appPadding
      }
    }
  }
}
