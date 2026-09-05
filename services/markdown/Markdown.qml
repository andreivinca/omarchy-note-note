import Quickshell.Io
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
    if (!markdown) { callback("", true); return }
    run(["to-html", "--highlight", root.highlight, "--highlight-ink", root.highlightInk,
         "--link", root.link, "--quote-ink", root.quoteInk,
         "--code-background", root.codeBackground,
         "--code-chip", root.codeChip].concat(base ? ["--base", base] : []),
        markdown, function(answer) {
      if (!answer || typeof answer.html !== "string") { console.warn("note-note: could not render the note"); callback("", false); return }
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
  function toMarkdown(html, callback, base) {
    if (!html) { callback("", { blocks: [], count: 0, ok: true }); return }
    run(["to-markdown"].concat(base ? ["--base", base] : []), html, function(answer) {
      if (!answer || typeof answer.markdown !== "string") { console.warn("note-note: could not read the editor's document"); callback("", { blocks: [], count: 0, ok: false }); return }
      callback(answer.markdown, { blocks: answer.blocks || [], count: answer.count || 0, ok: true })
    })
  }

  // ── running the converter ───────────────────────────────────────────
  // One process per conversion. They are short, they overlap (a save can run
  // while the toolbar converts), and sharing one would mean queueing them.
  //
  // callback(answer) runs exactly once, whatever happens to the process:
  // `answer` is the JSON object the converter wrote, or null when it wrote
  // nothing that parses — because it crashed, exited early, or never started
  // at all. The frame is what makes a failure distinguishable from an empty
  // note, since raw text has no failed answer that could not also be a real
  // one. A caller left without an answer would be a note stuck half-saved,
  // so every way a process can end resolves it: a finished stream, an exit
  // without one, and a start that failed (which Qt reports with neither).
  function run(args, payload, callback) {
    var proc = converter.createObject(root, { command: ["python3", root.script].concat(args), callback: callback })
    if (!proc) { console.warn("note-note: could not start the converter"); callback(null); return }
    proc.stdinEnabled = true                 // stdin must be open before it starts
    proc.running = true
    proc.write(payload)
    proc.stdinEnabled = false                // close stdin: the script reads to EOF
  }
  function parse(text) {
    var answer = null
    try { answer = JSON.parse(text) } catch (error) { answer = null }
    return (answer && typeof answer === "object") ? answer : null
  }

  Component {
    id: converter
    Process {
      id: proc
      // The note itself goes over stdin, never argv (docs/security.md rule 2).
      property var callback: null
      property bool launched: false
      // The one place a run ends. Whichever event gets here first answers;
      // the others find no callback left.
      function finish(text) {
        var done = proc.callback
        proc.callback = null
        if (done) done(root.parse(text))
        Qt.callLater(function() { proc.destroy() })
      }
      onStarted: proc.launched = true
      stdout: StdioCollector { onStreamFinished: proc.finish(this.text) }
      onExited: function(code) {
        if (code !== 0) console.warn("note-note: qthtml exited with", code)
        proc.finish("")
      }
      // A process that could not be started (no python3 on the shell's PATH)
      // goes running -> not running without ever having started, and Qt
      // emits neither an exit nor a stream end for it.
      onRunningChanged: if (!proc.running && !proc.launched) { console.warn("note-note: could not start the converter"); proc.finish("") }
    }
  }
}
