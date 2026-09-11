import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "delRow"
  label: "Delete this row"
  icon: "󰓵"
  capability: "table"
  available: editor.inTable

  function execute() {
    var cell = editor.tableContext()
    if (cell) {
      if (cell.row === 0) {
        editor.report("The header row stays")
        return
      }
      editor.changeTable("removeRows", cell.row, 1)
      return
    }
    editor.transformTable(function(rows, row) {
      if (row <= 1) {
        editor.report("The header row stays")
        return false
      }
      rows.splice(row, 1)
    })
  }
}
