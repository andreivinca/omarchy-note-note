import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "h1"
  label: "Heading 1"
  icon: "H1"
  available: !editor.inList
  previewScale: 2.0
  previewBold: true

  function execute() {
    editor.transformBlocks(function(line) {
      return "# " + line.content
    })
  }
}
