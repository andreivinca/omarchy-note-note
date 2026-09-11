import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "rule"
  label: "Horizontal rule"
  icon: "󰍴"

  function execute() {
    editor.insertSnippet("---")
  }
}
