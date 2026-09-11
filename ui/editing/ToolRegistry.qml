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
  readonly property var placement: ToolbarSettings.resolve(layout, tools)
  readonly property var topLevelTools: placement.toolbar.map(function(entry) {
    return entry.tool
  })
  readonly property var toolbarTools: topLevelTools.filter(function(tool) {
    return registry.isVisible(tool)
  })
  readonly property var shortcutActions: tools.filter(function(tool) {
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
      if (!tool || tool.apiVersion !== 1 || !tool.toolId || !tool.label
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
      counts[tool.toolId] = (counts[tool.toolId] || 0) + 1
    }
    candidates.sort(function(a, b) {
      return a.toolId.localeCompare(b.toolId)
    })
    var accepted = []
    var shortcuts = Object.create(null)
    for (var j = 0; j < candidates.length; j++) {
      var candidate = candidates[j]
      var reason = ""
      var shortcut = candidate.shortcutKey + ":" + candidate.shortcutModifiers
      if (counts[candidate.toolId] > 1) {
        reason = "duplicate tool id"
      } else if (candidate.shortcutKey && (!candidate.shortcutLabel || candidate.isMenu)) {
        reason = "shortcuts need a label and an executable tool"
      } else if (candidate.shortcutKey && (shortcuts[shortcut] || KeyBindings.ACTIONS.concat(KeyBindings.EDITOR_KEYS).some(function(action) {
        return action.key === candidate.shortcutKey && (action.modifiers || 0) === candidate.shortcutModifiers
      }))) {
        reason = "shortcut already assigned"
      }
      if (reason) {
        diagnostics.push(candidate.toolId + ": " + reason)
        candidate.destroy()
        continue
      }
      if (candidate.shortcutKey) {
        shortcuts[shortcut] = true
      }
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
    for (var i = 0; i < tools.length; i++) {
      if (tools[i].toolId === id) {
        return tools[i]
      }
    }
    return null
  }

  function menuTools(id) {
    return (placement.menus[id] || []).filter(function(tool) {
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
    for (var i = 0; i < tools.length; i++) {
      var tool = tools[i]
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
    for (var i = 0; i < tools.length; i++) {
      if (tools[i] !== except) {
        tools[i].panelOpen = false
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
