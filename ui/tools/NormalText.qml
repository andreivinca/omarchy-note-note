import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "p"
  label: "Normal text"
  icon: "T"
  available: !editor.inList

  function execute() {
    editor.transformBlocks(function(line) {
      return line.content
    })
  }
}
