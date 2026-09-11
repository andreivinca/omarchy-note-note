import QtQuick
import "../editing"
import "../Dialect.js" as Dialect

Tool {
  id: tool
  toolId: "highlight"
  label: "Highlight"
  icon: "󰙒"
  shortcutKey: Qt.Key_H
  shortcutModifiers: Qt.ControlModifier | Qt.ShiftModifier
  shortcutLabel: "ctrl+shift+h"

  function execute() {
    if (!editor.acceptsInline() || editor.markedInCode(Dialect.INLINE_MARKERS.highlight)) {
      return
    }
    var range = editor.selection()
    if (range.from === range.to) {
      return
    }
    var lit = editor.withoutChip(range.html).indexOf("background-color") >= 0
    var html = lit ? unhighlight(range.html)
                   : '<span style="background-color:' + editor.highlightColour + ';">' + range.html + "</span>"
    editor.replaceInline(html, true)
  }

  // Remove only the marker background; text keeps its color and code its chip.
  function unhighlight(fragment) {
    var chip = String(editor.codeChipColour).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    return fragment.replace(new RegExp('background-color\\s*:(?!\\s*' + chip + '\\s*[;"])[^;"]*;?', "gi"), "")
  }
}
