.pragma library

// The document vocabulary shared by QML readers and editing tools.
// tests/test_regressions.py checks agreement with the Python and native adapters.
var QUOTE_PX = 40
var CODE_PAD_PX = 14
var MAX_IMAGE_DISPLAY = 640
var LINE_HEIGHT_PCT = 130

// The inline tools' Markdown, by tool id — what a tool types inside a code
// block, where the fence holds the characters literally (NoteEditor,
// typeMarker). Mirrors reader.INLINE_MARKERS in
// services/markdown/qthtml/reader.py, plus the code span's backtick
// (services/markdown/mdtext.py, code_span).
var INLINE_MARKERS = { bold: "**", italic: "*", underline: "_", strikeout: "~~", highlight: "==", code: "`" }


function documentHtml(html) {
  return html.replace(/<!--(Start|End)Fragment-->/g, "")
    .replace(/<a\b([^>]*)>/gi, function(tag, attributes) {
      if (/\bstyle\s*=/i.test(attributes)) {
        return tag
      }
      return '<a' + attributes + ' style="-qt-foreground:none;">'
    })
}
