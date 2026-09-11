import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "ol"
  label: "Numbered list"
  icon: "󰉻"

  function execute() {
    editor.transformBlocks(function(line) {
      return line.indent + (/^\d+[.)][ \t]/.test(line.prefix) ? "" : "1. ") + line.content
    }, { list: true })
  }
}
