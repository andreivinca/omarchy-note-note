import QtQuick
import "../editing"

Tool {
  id: heading
  toolId: "heading"
  label: "Heading"
  icon: "󰉿"
  toolbarLabelVisible: false
  available: !editor.inList

  function apply(level) {
    editor.transformBlocks(function(line) {
      return "#".repeat(level) + (level ? " " : "") + line.content
    })
  }

  options: [
    Tool {
      editor: heading.editor
      toolId: "h1"
      label: "Heading 1"
      available: heading.available
      previewScale: 2.0
      previewBold: true
      function execute() {
        heading.apply(1)
      }
    },
    Tool {
      editor: heading.editor
      toolId: "h2"
      label: "Heading 2"
      available: heading.available
      previewScale: 1.5
      previewBold: true
      function execute() {
        heading.apply(2)
      }
    },
    Tool {
      editor: heading.editor
      toolId: "h3"
      label: "Heading 3"
      available: heading.available
      previewScale: 1.17
      previewBold: true
      function execute() {
        heading.apply(3)
      }
    },
    Tool {
      editor: heading.editor
      toolId: "p"
      label: "Normal"
      available: heading.available
      function execute() {
        heading.apply(0)
      }
    }
  ]
}
