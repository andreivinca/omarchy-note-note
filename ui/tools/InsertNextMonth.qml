import QtQuick
import "../editing"
import "../editing/Calendar.js" as Calendar

Tool {
  toolId: "nextMonth"
  label: "Insert next month"
  icon: "󰃭"
  capability: "table"

  function execute() {
    var nextMonth = new Date()
    // Start on day one so month-end dates cannot skip a shorter month.
    // Date also carries December forward into January of the next year.
    nextMonth.setMonth(nextMonth.getMonth() + 1, 1)
    editor.insertTable(Calendar.markdown(nextMonth.getFullYear(), nextMonth.getMonth(), Qt.locale()))
  }
}
