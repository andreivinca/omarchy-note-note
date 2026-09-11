import QtQuick
import "../editing"
import "../Dialect.js" as Dialect

Tool {
  id: tool
  toolId: "strikeout"
  label: "Strikethrough"
  icon: "󰊁"
  shortcutKey: Qt.Key_S
  shortcutModifiers: Qt.ControlModifier
  shortcutLabel: "ctrl+s"

  function execute() {
    editor.toggleFont("strikeout", Dialect.INLINE_MARKERS.strikeout)
  }
}
