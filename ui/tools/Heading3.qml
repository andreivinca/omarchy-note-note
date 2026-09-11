import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "h3"
  label: "Heading 3"
  icon: "H3"
  available: !editor.inList
  previewScale: 1.17
  previewBold: true

  function execute() {
    editor.transformBlocks(function(line) {
      return "### " + line.content
    })
  }
}
