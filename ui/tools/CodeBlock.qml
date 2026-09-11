import QtQuick
import "../editing"

Tool {
  id: tool
  toolId: "codeblock"
  label: "Code block"
  icon: "󰅩"

  function execute() {
    var b = editor.blockInfoAt(editor.cursorPosition())
    if (b && b.kind === "code") {
      unfenceCodeBlock(b.empty)
    } else {
      insertCodeBlock()
    }
  }

  function insertCodeBlock() {
    editor.withMarkdown(function(lines, map) {
      var at = editor.blockEndLine(lines, Math.min(editor.caretLine(map), lines.length - 1))
      var rest = lines.slice(at + 1)
      var atEnd = rest.join("").trim() === ""
      var out = lines.slice(0, at + 1).concat(["", "```", "", "```", ""])
      if (!atEnd) {
        out = out.concat(rest)
      }
      var block = editor.lastBlockThrough(map, at) + 1
      editor.replaceDocument(out.join("\n"), editor.cursorPosition(), function() { editor.selectBlock(block) })
    })
  }

  function unfenceCodeBlock(empty) {
    var block = editor.blockAt(editor.cursorPosition())
    editor.withMarkdown(function(lines) {
      editor.replaceDocument(lines.join("\n"), editor.cursorPosition(), function() {
        if (empty) {
          editor.selectBlock(block)
        }
      })
    }, block)
  }
}
