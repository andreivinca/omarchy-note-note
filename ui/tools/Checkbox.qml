import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "todo"
  label: "Checkbox"
  icon: "󰄵"

  function execute() {
    editor.transformBlocks(function(line) {
      return line.indent + (/\[[ xX]\]/.test(line.prefix) ? "" : "- [ ] ") + (line.content || "\u00a0")
    }, { list: true })
  }
}
