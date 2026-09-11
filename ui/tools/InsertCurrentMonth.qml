import QtQuick
import "../editing"
import "../editing/Calendar.js" as Calendar

Tool {
  toolId: "currentMonth"
  label: "Insert current month"
  icon: "󰃭"
  capability: "table"

  function execute() {
    // Read the local date at insertion time, even if the app stayed open
    // across midnight or a month boundary.
    var today = new Date()
    editor.insertTable(Calendar.markdown(today.getFullYear(), today.getMonth(), Qt.locale()))
  }
}
