import QtQuick
import "../ui/editing"

// Copied beside the built-in tools only in the isolated test directory.
// No registry, toolbar or shortcut source knows this tool exists.
Tool {
  toolId: "greeting"
  label: "Insert greeting"
  icon: "+"
  shortcutKey: Qt.Key_G
  shortcutModifiers: Qt.ControlModifier | Qt.ShiftModifier
  shortcutLabel: "ctrl+shift+g"

  function execute() {
    editor.insertHtml("Hello")
  }
}
