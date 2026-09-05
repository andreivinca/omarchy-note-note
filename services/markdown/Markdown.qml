import "../processes"
import QtQuick

// Markdown <-> the HTML the editor's document holds.
//
// The editor works in rich text because Markdown cannot express what it must
// keep — a highlight, an empty paragraph, an indent, a checkbox with no text.
// Notes on disk and the provider contract stay Markdown, so every note passes
// through here twice: once on the way into the editor, once on the way out.
// The conversion itself lives in `qthtml/`, which is testable on its own
// (`python3 services/markdown/qthtml/selftest.py`).
Item {
  id: root

  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: dir + "/qthtml/__main__.py"

  // The colours of ==highlighted== text. Neither reaches disk: the note keeps
  // the markers, the document keeps the colours. The ink is set here because a
  // highlight is a light marker, and the editor's own foreground follows the
  // theme — on a dark theme that would be light text on a light highlight.
  property string highlight: "#f9e2af"
  property string highlightInk: "#1e1e2e"

  // The colour of a link. Set by the host from the theme (Notes.qml,
  // linkColour); this default is only what a caller that names none gets.
  // It does not reach disk either — Markdown has no colour, and `reader`
  // never looks at one.
  property string link: "#4282d7"

  // A quote's ink and the slab behind a code block, both set by the host
  // from the theme (Notes.qml). Neither reaches disk: the quote's meaning is
  // its margins (its bar is drawn by the editor, over the document), the
  // code block's is its monospace runs on *a* block background.
  property string quoteInk: "#9399b2"
  property string codeBackground: "transparent"

  // The chip behind inline code — the tinted patch that makes `code` read as
  // code in prose. Set by the host from the theme (Notes.qml, codeChipColour);
  // it does not reach disk either: the reader answers backticks for any
  // monospace span before it looks at a colour.
  property string codeChip: "transparent"

  // Markdown -> HTML for `TextEdit.text`.  callback(html, ok)
  //
  // `ok` is false when the converter failed, and only then. A caller that
  // cannot tell a failure from an empty note puts the empty one in the
  // editor, and autosave writes it back over the note — so the answer is
  // framed (see run), and an empty note is `{"html": ""}`, not nothing.
  //
  // `base` (optional) is the note's own directory, for notes that name their
  // images by a relative path (local notebooks): it is how the converter
  // finds and measures them. A directory path, never note content, so it may
  // ride on argv.
  function toHtml(markdown, callback, base) {
    if (!markdown) {
      callback("", true)
      return
    }
    run(["to-html", "--highlight", root.highlight, "--highlight-ink", root.highlightInk,
         "--link", root.link, "--quote-ink", root.quoteInk,
         "--code-background", root.codeBackground,
         "--code-chip", root.codeChip].concat(base ? ["--base", base] : []),
        markdown, function(answer) {
      if (!answer || typeof answer.html !== "string") {
        console.warn("note-note: could not render the note")
        callback("", false)
        return
      }
      callback(answer.html, true)
    })
  }

  // HTML from `getFormattedText()` -> Markdown.  callback(markdown, map)
  //
  // `map.blocks[i]` is the document block Markdown line `i` came from, which
  // is how the toolbar finds the line the caret is on; `map.count` is how many
  // blocks the document has. `map.ok` is false when the converter failed, and
  // only then — an empty answer is not a failure: a note holding one blank
  // line converts to no Markdown at all, and that is the truth about it.
  //
  // `asText` (optional) is a document block: the code block holding it is
  // read as the paragraphs its lines would be — the code block tool
  // toggling off (NoteEditor.toggleCodeBlock). A number, never note
  // content, so it may ride on argv.
  function toMarkdown(html, callback, base, asText) {
    if (!html) {
      callback("", { blocks: [], count: 0, ok: true })
      return
    }
    var args = ["to-markdown"].concat(base ? ["--base", base] : [])
    if (asText !== undefined) {
      args = args.concat(["--as-text", String(asText)])
    }
    run(args, html, function(answer) {
      if (!answer || typeof answer.markdown !== "string") {
        console.warn("note-note: could not read the editor's document")
        callback("", { blocks: [], count: 0, ok: false })
        return
      }
      callback(answer.markdown, { blocks: answer.blocks || [], count: answer.count || 0, ok: true })
    })
  }

  ProcessRunner { id: runner }

  function run(args, payload, callback) {
    return runner.run({ command: ["python3", root.script].concat(args), payload: payload }, callback)
  }
}
