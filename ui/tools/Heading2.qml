import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "h2"
  label: "Heading 2"
  icon: "H2"
  available: !editor.inList
  previewScale: 1.5
  previewBold: true

  function execute() {
    editor.transformBlocks(function(line) {
      return "## " + line.content
    })
  }
}
