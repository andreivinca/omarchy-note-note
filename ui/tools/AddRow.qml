import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "addRow"
  label: "Add a row below"
  icon: "󰓳"
  capability: "table"
  available: editor.inTable

  function execute() {
    var cell = editor.tableContext()
    if (cell) {
      editor.changeTable("insertRows", cell.row + 1, 1)
      return
    }
    editor.transformTable(function(rows, row) {
      var blank = []
      for (var i = 0; i < rows[0].length; i++) {
        blank.push("")
      }
      rows.splice((row === 0 ? 1 : row) + 1, 0, blank)
    })
  }
}
