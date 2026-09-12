import QtQuick

// One instance belongs to one editor. A tool supplies metadata, its action,
// and optionally a panel; the registry supplies editor and dispatches actions.
QtObject {
  id: tool
  readonly property int apiVersion: 1
  required property var editor
  property string toolId: ""
  property string label: ""
  property string icon: ""
  property bool toolbarLabelVisible: true
  property string capability: toolId
  property bool available: true
  property bool checked: false
  property int shortcutKey: 0
  property int shortcutModifiers: Qt.NoModifier
  property string shortcutLabel: ""
  readonly property string tooltip: label + (shortcutLabel ? " (" + shortcutLabel + ")" : "")

  // A tool can own a fixed set of choices. Other menus take their members
  // and order from toolbar settings.
  property list<Tool> options
  property bool isMenu: options.length > 0
  property real previewScale: 1.0
  property bool previewBold: false

  property bool panelPopup: false
  property Component panel: null
  property bool panelOpen: false
  property var panelContext: null
  onPanelOpenChanged: {
    if (!panelOpen) {
      panelContext = null
    }
  }

  function openPanel() {
    if (!panel || !available || !editor.writable || !editor.supports(capability)) {
      return false
    }
    panelContext = editor.capture()
    panelOpen = true
    return true
  }

  function cancelPanel() {
    panelOpen = false
    editor.focus()
  }

  function submitPanel(apply) {
    var accepted = panelOpen && available && editor.supports(capability)
      && editor.current(panelContext)
    panelOpen = false
    if (!accepted) {
      return false
    }
    apply()
    editor.focus()
    return true
  }

  function execute() {
  }
}
