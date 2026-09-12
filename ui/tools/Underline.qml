import QtQuick
import "../editing"
import "../Dialect.js" as Dialect

Tool {
  id: tool
  toolId: "underline"
  checked: editor.underline
  label: "Underline"
  icon: "󰊇"
  shortcutKey: Qt.Key_U
  shortcutModifiers: Qt.ControlModifier
  shortcutLabel: "ctrl+u"

  function execute() {
    editor.toggleFont("underline", Dialect.INLINE_MARKERS.underline)
  }
}
