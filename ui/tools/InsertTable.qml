import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "table"
  label: "Insert a table"
  icon: "󰓫"

  function execute() {
    editor.insertTable("|  |  |\n|---|---|\n|  |  |")
  }
}
