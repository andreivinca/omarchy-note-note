import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "addCol"
  label: "Add a column"
  icon: "󰓬"
  capability: "table"
  available: editor.inTable

  function execute() {
    var cell = editor.tableContext()
    if (cell) {
      editor.changeTable("insertColumns", cell.columns, 1)
      return
    }
    editor.transformTable(function(rows) {
      for (var i = 0; i < rows.length; i++) {
        rows[i].push(i === 1 ? "---" : "")
      }
    })
  }
}
