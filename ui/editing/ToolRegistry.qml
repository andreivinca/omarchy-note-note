import QtQuick
import Qt.labs.folderlistmodel
import "../KeyBindings.js" as KeyBindings
import "ToolbarSettings.js" as ToolbarSettings

Item {
  id: registry
  required property var editor
  property url directory: Qt.resolvedUrl("../tools")
  property var layout: ToolbarSettings.defaults()
  readonly property alias ready: registryState.ready
  readonly property alias errors: registryState.errors
  readonly property alias tools: registryState.tools
  readonly property var actions: tools.reduce(function(result, tool) {
    return result.concat(registry.definitions(tool))
  }, [])
  readonly property var placement: ToolbarSettings.resolve(layout, tools)
  readonly property var toolbarGroups: {
    var groups = []
    for (var i = 0; i < placement.toolbar.length; i++) {
      var entry = placement.toolbar[i]
      var group = groups[groups.length - 1]
      if (!group || group.id !== entry.group) {
        group = { id: entry.group, tools: [] }
        groups.push(group)
      }
      group.tools.push(entry.tool)
    }
    return groups
  }
  readonly property var topLevelTools: placement.toolbar.map(function(entry) {
    return entry.tool
  })
  readonly property var toolbarTools: topLevelTools.filter(function(tool) {
    return registry.isVisible(tool)
  })
  readonly property var shortcutActions: actions.filter(function(tool) {
    return !!tool.shortcutKey
  }).map(function(tool) {
    return { group: "Editing", label: tool.shortcutLabel, description: tool.label }
  })
  onLayoutChanged: {
    if (ready) {
      closePanels()
    }
  }

  QtObject {
    id: registryState
    property bool ready: false
    property url loadedDirectory: ""
    property var errors: []
    property var tools: []
  }

  FolderListModel {
    id: files
    folder: registry.directory
    nameFilters: ["*.qml"]
    showDirs: false
    showDotAndDotDot: false
    sortField: FolderListModel.Name
    onStatusChanged: {
      if (status === FolderListModel.Ready) {
        reload.restart()
      }
    }
    onCountChanged: reload.restart()
  }

  Timer {
    id: reload
    interval: 0
    onTriggered: {
      if (files.status === FolderListModel.Ready) {
        registry.loadTools()
      }
    }
  }

  function definitions(tool) {
    return [tool].concat(Array.from(tool.options))
  }

  function definitionError(tool, counts, shortcuts) {
    if (tool.apiVersion !== 1 || !tool.toolId || !tool.label || typeof tool.execute !== "function") {
      return "expected an editing Tool with an id and label"
    }
    if (counts[tool.toolId] > 1) {
      return "duplicate tool id"
    }
    if (!tool.shortcutKey) {
      return ""
    }
    if (!tool.shortcutLabel || tool.isMenu) {
      return "shortcuts need a label and an executable tool"
    }
    var shortcut = tool.shortcutKey + ":" + tool.shortcutModifiers
    if (shortcuts[shortcut] || KeyBindings.ACTIONS.concat(KeyBindings.EDITOR_KEYS).some(function(action) {
      return action.key === tool.shortcutKey && (action.modifiers || 0) === tool.shortcutModifiers
    })) {
      return "shortcut already assigned"
    }
    shortcuts[shortcut] = true
    return ""
  }

  function loadTools() {
    // Discover once per directory. Updating source files takes effect on app
    // restart; do not destroy tool instances underneath pending conversions.
    if (registryState.ready && registryState.loadedDirectory === directory) {
      return
    }
    registry.closePanels()
    var previous = registryState.tools
    registryState.tools = []
    registryState.ready = false
    var candidates = []
    var diagnostics = []
    var counts = Object.create(null)
    for (var i = 0; i < files.count; i++) {
      var url = files.get(i, "fileUrl")
      var component = Qt.createComponent(url, Component.PreferSynchronous)
      if (component.status !== Component.Ready) {
        diagnostics.push(String(url) + ": " + component.errorString())
        component.destroy()
        continue
      }
      var tool = component.createObject(registry, { editor: registry.editor })
      if (!tool || tool.apiVersion !== 1 || !tool.toolId || !tool.label || !tool.options
          || typeof tool.execute !== "function") {
        diagnostics.push(String(url) + ": expected an editing Tool with an id and label")
        if (tool) {
          tool.destroy()
        }
        component.destroy()
        continue
      }
      component.destroy()
      candidates.push(tool)
      var entries = definitions(tool)
      for (var e = 0; e < entries.length; e++) {
        counts[entries[e].toolId] = (counts[entries[e].toolId] || 0) + 1
      }
    }
    candidates.sort(function(a, b) {
      return a.toolId.localeCompare(b.toolId)
    })
    var accepted = []
    var shortcuts = Object.create(null)
    for (var j = 0; j < candidates.length; j++) {
      var candidate = candidates[j]
      var reason = ""
      var candidateShortcuts = Object.assign(Object.create(null), shortcuts)
      var candidateEntries = definitions(candidate)
      for (var c = 0; !reason && c < candidateEntries.length; c++) {
        var definition = candidateEntries[c]
        reason = c > 0 && definition.isMenu ? "tool options must be executable"
          : definitionError(definition, counts, candidateShortcuts)
      }
      if (reason) {
        diagnostics.push(candidate.toolId + ": " + reason)
        candidate.destroy()
        continue
      }
      shortcuts = candidateShortcuts
      accepted.push(candidate)
    }
    registryState.errors = diagnostics
    registryState.tools = accepted
    registryState.loadedDirectory = directory
    registryState.ready = true
    for (var k = 0; k < previous.length; k++) {
      previous[k].destroy()
    }
    for (var d = 0; d < diagnostics.length; d++) {
      console.warn("Editing tool skipped: " + diagnostics[d])
    }
  }

  function find(id) {
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].toolId === id) {
        return actions[i]
      }
    }
    return null
  }

  function menuTools(id) {
    var menu = find(id)
    var rows = menu && menu.options.length > 0 ? Array.from(menu.options) : (placement.menus[id] || [])
    return rows.filter(function(tool) {
      return registry.isVisible(tool) && (!tool.isMenu || registry.menuTools(tool.toolId).length > 0)
    })
  }

  function groupFor(id) {
    for (var i = 0; i < placement.toolbar.length; i++) {
      if (placement.toolbar[i].tool.toolId === id) {
        return placement.toolbar[i].group
      }
    }
    return -1
  }

  function isVisible(tool) {
    if (!tool || !tool.available) {
      return false
    }
    if (tool.options.length > 0) {
      return Array.from(tool.options).some(function(option) {
        return registry.isVisible(option)
      })
    }
    return tool.isMenu || editor.supports(tool.capability)
  }

  function canExecute(tool) {
    if (!ready || registryState.loadedDirectory !== directory
        || !tool || tool.isMenu || !editor.writable || !isVisible(tool)) {
      return false
    }
    return true
  }

  function execute(id) {
    var tool = find(id)
    if (!canExecute(tool)) {
      return false
    }
    closePanels(tool)
    tool.execute()
    return true
  }

  function handleShortcut(event) {
    var modifiers = event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)
    for (var i = 0; i < actions.length; i++) {
      var tool = actions[i]
      if (tool.shortcutKey && tool.shortcutKey === event.key && tool.shortcutModifiers === modifiers) {
        execute(tool.toolId)
        // Consume disabled actions too, so TextEdit's native shortcut cannot
        // bypass the provider's capabilities or the document's read-only state.
        return true
      }
    }
    return false
  }

  function closePanels(except) {
    for (var i = 0; i < actions.length; i++) {
      if (actions[i] !== except) {
        actions[i].panelOpen = false
      }
    }
  }

  Connections {
    target: registry.editor
    function onNoteTokenChanged() {
      registry.closePanels()
    }
    function onWritableChanged() {
      if (!registry.editor.writable) {
        registry.closePanels()
        registry.editor.clearPending()
      }
    }
    function onEnabledToolsChanged() {
      registry.closePanels()
      registry.editor.clearPending()
    }
  }
}
