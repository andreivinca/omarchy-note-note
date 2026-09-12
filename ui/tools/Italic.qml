import QtQuick
import "../editing"
import "../Dialect.js" as Dialect

Tool {
  id: tool
  toolId: "italic"
  checked: editor.italic
  label: "Italic"
  icon: "󰉷"
  shortcutKey: Qt.Key_I
  shortcutModifiers: Qt.ControlModifier
  shortcutLabel: "ctrl+i"

  function execute() {
    editor.toggleFont("italic", Dialect.INLINE_MARKERS.italic)
  }
}
