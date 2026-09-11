import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "outdent"
  label: "Outdent"
  icon: "󰉵"

  function execute() {
    editor.transformBlocks(function(line) {
      if (line.isList) {
        return line.indent.substring(2) + line.prefix + line.content
      }
      var content = line.content.indexOf(editor.nbsp4) === 0 ? line.content.substring(4) : line.content
      return line.indent + line.prefix + content
    })
  }
}
