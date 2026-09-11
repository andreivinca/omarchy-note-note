import QtQuick
import "../editing"
import "../Dialect.js" as Dialect

Tool {
  id: tool
  toolId: "code"
  label: "Inline code"
  icon: "󰅴"

  function execute() {
    if (!editor.acceptsInline() || editor.markedInCode(Dialect.INLINE_MARKERS.code)) {
      return
    }
    var range = editor.selection()
    if (range.from === range.to) {
      return
    }
    var mono = /font-family:[^;"]*mono/i.test(range.html)
    var html = mono ? editor.withoutChip(range.html.replace(/font-family:[^;"]*mono[^;"]*;?/gi, ""))
                    : "<span style=\"font-family:'monospace'; background-color:"
                      + editor.codeChipColour + ';">' + range.html + "</span>"
    editor.replaceInline(html, true)
  }
}
