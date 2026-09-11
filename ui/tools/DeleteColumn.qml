import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "delCol"
  label: "Delete this column"
  icon: "󰓮"
  capability: "table"
  available: editor.inTable

  function execute() {
    var cell = editor.tableContext()
    if (cell) {
      if (cell.columns <= 1) {
        editor.report("A table needs at least one column")
        return
      }
      editor.changeTable("removeColumns", cell.column, 1)
      return
    }
    editor.transformTable(function(rows, row, column) {
      if (rows[0].length <= 1) {
        editor.report("A table needs at least one column")
        return false
      }
      for (var i = 0; i < rows.length; i++) {
        rows[i].splice(column, 1)
      }
    })
  }
}
