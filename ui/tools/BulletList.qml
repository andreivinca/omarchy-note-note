import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "ul"
  label: "Bullet list"
  icon: "󰉹"

  function execute() {
    editor.transformBlocks(function(line) {
      return line.indent + (/^[-*+][ \t](?!\[)/.test(line.prefix) ? "" : "- ") + line.content
    }, { list: true })
  }
}
