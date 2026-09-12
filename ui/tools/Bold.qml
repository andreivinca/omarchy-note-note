import QtQuick
import "../editing"
import "../Dialect.js" as Dialect

Tool {
  id: tool
  toolId: "bold"
  checked: editor.bold
  label: "Bold"
  icon: "󰉤"
  shortcutKey: Qt.Key_B
  shortcutModifiers: Qt.ControlModifier
  shortcutLabel: "ctrl+b"

  function execute() {
    editor.toggleFont("bold", Dialect.INLINE_MARKERS.bold)
  }
}
