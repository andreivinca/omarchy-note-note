import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "table"
  label: "Insert a table"
  icon: "󰓫"

  function execute() {
    editor.insertTable("| Column 1 | Column 2 |\n|---|---|\n|  |  |")
  }
}
