import QtQuick
import qs.Commons
import qs.Ui

// The right-hand pane, in the shape of Toolroll's workspace: an editable
// title with a description line beneath, header buttons on the title's line,
// and a labelled, bordered content pane below.
Item {
  id: root

  property bool hasNote: false
  // Plain text for backends that store text (Sticky Notes): every newline
  // counts, and nothing is Markdown.
  property bool plain: false
  // Some backends have no separate title (Sticky Notes).
  property bool hasTitle: true
  // Pages that cannot be written back safely (OneNote pages with images).
  property bool readOnly: false
  // Tool ids the current provider supports (see PROVIDERS.md); null = all.
  property var enabledTools: null
  function toolEnabled(id) { return root.enabledTools === null || root.enabledTools.indexOf(id) >= 0 }
  property string fileName: ""
  property string notebookName: ""
  property string placeholder: ""
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  // The body must NOT be fixed-pitch: Qt's Markdown writer serialises any
  // monospace text as a code span and drops bold/italic/underline.
  property string bodyFontFamily: "sans-serif"
  // The conversion service (services/markdown/Markdown.qml). The document is
  // HTML; every note arrives and leaves as Markdown, and this is the boundary.
  property var markdown: null
  // The clipboard service (services/clipboard/Clipboard.qml), for pasting a
  // picture. Only providers that can store one accept it.
  property var clipboard: null
  property bool canImages: false
  readonly property string highlightColour: root.markdown ? root.markdown.highlight : "#f9e2af"
  readonly property string highlightInk: root.markdown ? root.markdown.highlightInk : "#1e1e2e"
  readonly property string linkColour: root.markdown ? root.markdown.link : "#4282d7"

  readonly property alias title: titleField.text
  readonly property bool bodyFocused: area.activeFocus
  // Plain characters, not a serialisation — for backends that store text.
  function plainText() { return area.getText(0, area.length) }

  // The document as HTML — a range, so that Qt marks the fragment and the
  // reader can strip it. Except when there is no range: a note can hold no
  // characters and still have a block that is a checkbox item (deleting an
  // item's text leaves the box behind), and `getFormattedText(0, 0)` answers
  // with nothing at all — which reads back as a blank note, so the toolbar
  // sees nothing to toggle. `text` is the whole document, live, and it is the
  // only way to see that block.
  function documentHtml() {
    return area.length > 0 ? area.getFormattedText(0, area.length) : area.text
  }

  // The note as it belongs on disk.  callback(markdown)
  function requestMarkdown(callback) {
    if (root.plain || !root.markdown) { callback(plainText()); return }
    root.markdown.toMarkdown(documentHtml(), function(md) { callback(md) })
  }

  // Notice mode: a message with optional buttons shown instead of the note
  // (setup instructions, a device-code prompt, an error).
  property string noticeTitle: ""
  property string noticeText: ""
  property string noticeCode: ""
  // [{ label, icon, action }] — action is a function.
  property var noticeActions: []
  // A provider-supplied view (setup screens, settings) rendered instead of
  // the note; the provider owns what is inside.
  property Component customView: null
  property var customViewProps: ({})
  // The tools and the note sit the same distance from the hairline as the
  // toolbar sits from the title. The two numbers differ because the neighbours
  // do: a toolbar button carries its own padding below its glyph, the first
  // line of the note carries almost none, so equal numbers here would look
  // unequal on screen.
  readonly property real ruleRoomAbove: Style.spacing.lg
  readonly property real ruleRoomBelow: Style.space(17)

  // The title, a step above `heading`. The shell's scale goes 16 then straight
  // to 24, and a note's title wants the size in between.
  readonly property int titleSize: Math.round(Style.font.heading * 1.25)
  readonly property bool showingNotice: noticeText.length > 0 || customView !== null
  function showView(component, props) {
    customView = component; customViewProps = props || ({})
    // Focus the view once it is in the scene (a forceActiveFocus() from the
    // component's own Component.onCompleted runs too early).
    Qt.callLater(function() { if (customLoader.item) customLoader.item.forceActiveFocus() })
  }
  function clearView() { customView = null; customViewProps = ({}) }
  readonly property bool viewHasFocus: customLoader.item ? customLoader.item.activeFocus : false
  function showNotice(title, text, code, actions) {
    noticeTitle = title; noticeText = text; noticeCode = code || ""; noticeActions = actions || []
  }
  function clearNotice() { noticeTitle = ""; noticeText = ""; noticeCode = ""; noticeActions = []; clearView() }

  // (KeyEvent) -> bool. Runs before the inputs' own key handling so app
  // shortcuts win over TextEdit's built-in Ctrl+K / Ctrl+D bindings.
  property var shortcutHandler: null
  function shortcut(event) { if (shortcutHandler && shortcutHandler(event)) event.accepted = true }

  signal edited()
  // A short message for the host's status line.
  property string statusRequestedText: ""

  property bool settingText: false
  // Conversions are asynchronous, so a note that arrives while an earlier one
  // is still being converted must win: only the newest token may assign.
  property int noteToken: 0

  function setNote(t, body) {
    clearPending()
    var token = ++root.noteToken
    settingText = true
    titleField.text = t
    titleField.cursorPosition = 0
    settingText = false
    if (root.plain || !root.markdown || !body) { showBody(body || "", token); return }
    root.markdown.toHtml(body, function(html) { root.showBody(html, token) })
  }

  function showBody(document, token) {
    if (token !== root.noteToken) return          // a newer note won the race
    settingText = true
    area.text = document
    settingText = false
    area.cursorPosition = area.length
  }

  // Highlight is a real background colour in the document, and ==text== in the
  // note: Markdown has no highlight of its own, and the providers already
  // translate the markers into each backend's own.
  function highlightSelection() {
    if (root.readOnly || root.plain) return
    var from = Math.min(area.selectionStart, area.selectionEnd)
    var to = Math.max(area.selectionStart, area.selectionEnd)
    if (from === to) return
    var fragment = inlineFragment(area.getFormattedText(from, to))
    var lit = fragment.indexOf("background-color") >= 0
    area.remove(from, to)
    area.insert(from, lit ? unhighlight(fragment)
                          : '<span style="background-color:' + root.highlightColour
                            + "; color:" + root.highlightInk + ';">' + fragment + "</span>")
    area.select(from, area.cursorPosition)
    root.edited()
  }

  // Qt serialises any range as a whole document whose body holds one
  // paragraph — the block the selection sits in. Inside that paragraph is the
  // inline HTML we actually selected.
  function inlineFragment(html) {
    var body = (html.split("<body>")[1] || "").split("</body>")[0]
    return body.replace(/<!--(Start|End)Fragment-->/g, "").trim()
               .replace(/^<p[^>]*>/, "").replace(/<\/p>\s*$/, "")
  }

  function unhighlight(fragment) {
    return fragment.replace(/background-color\s*:[^;"]*;?/g, "")
  }
  function focusEditor() { area.forceActiveFocus() }

  // ── pasting ─────────────────────────────────────────────────────────
  // Ctrl+V is ours only long enough to ask what the clipboard holds: a
  // picture is inserted as an image, anything else is the editor's own paste.
  function paste() {
    if (root.readOnly) return
    if (!root.clipboard || root.plain) { area.paste(); return }
    if (!root.canImages) {
      // Say so rather than swallowing the paste: a picture that lands nowhere
      // looks like the app is broken.
      root.clipboard.hasImage(function(isImage) {
        if (isImage) root.statusRequestedText = "This notebook cannot store images"
        else area.paste()
      })
      return
    }
    root.clipboard.takeImage(function(image) {
      if (image) root.insertImage(image.path)
      else area.paste()
    })
  }

  function insertImage(path) {
    if (root.readOnly || root.plain) return
    var at = area.cursorPosition
    // On its own line: a picture is a block of its own in every backend, and
    // the save can only leave it untouched if the text is not wrapped around
    // it (providers/onenote/onenote_md.py).
    area.insert(at, '<p><img src="file://' + encodeURI(path).replace(/"/g, "%22") + '" alt="" /></p>')
    guardImageAt(at)
    root.edited()
    root.statusRequestedText = "Image pasted"
  }

  // ── images in list items ────────────────────────────────────────────
  // Qt paints an image that opens a list item about 200px too high (the
  // document is right, the painting is not — docs/engine-notes.md). One
  // non-breaking space in front of it is invisible and enough. The loader
  // does the same on the way in; the converter strips it on the way out.
  readonly property string objectChar: "\ufffc"
  // Mirrors IMAGE_LEAD in services/markdown/qthtml/dialect.py \u2014 the loader,
  // the writer and these live-edit guards must all plant the same character.
  readonly property string imageLead: "\u00a0"
  function inListItem(pos) { return /<li\b/.test(area.getFormattedText(pos, Math.min(pos + 1, area.length))) }
  function atBlockStart(pos) { return pos === 0 || area.getText(pos - 1, pos) === root.sep }
  function guardImageAt(pos) {
    // The image the editor just put in may have landed at the start of an
    // item; scan forward for it from the insertion point.
    var text = area.getText(pos, Math.min(pos + 4, area.length)), i = text.indexOf(root.objectChar)
    if (i < 0) return
    var at = pos + i
    if (atBlockStart(at) && inListItem(at)) { area.insert(at, root.imageLead); area.cursorPosition = at + 2 }
  }
  // Enter with the caret right before an image: the image would open the
  // new item. Put the space in first, with the caret still before it, so
  // Qt's own Enter splits the block ahead of both.
  function beforeReturn() {
    var at = area.cursorPosition
    if (area.selectionStart !== area.selectionEnd) return
    if (area.getText(at, at + 1) !== root.objectChar || !inListItem(at)) return
    area.insert(at, root.imageLead)
    area.cursorPosition = at
  }
  function undo() { if (area.canUndo) { area.undo(); root.edited() } }
  function redo() { if (area.canRedo) { area.redo(); root.edited() } }

  // ── formatting tools ────────────────────────────────────────────────
  // Inline styles use the selection's font. Block styles cannot be set from
  // QML, so they go through the Markdown: a marker is put at the end of each
  // selected paragraph, the note is serialised, the marked lines get their
  // new prefix, and the note is reloaded. Snippets are inserted as Markdown,
  // which the editor parses in place.
  readonly property string marker: "⦃M⦄"
  readonly property string nbsp4: "\u00a0\u00a0\u00a0\u00a0"

  readonly property string sep: "\u2029"
  // ── editing tools ───────────────────────────────────────────────────
  // A block style is not something QML can set on the document, and it is one
  // line of Markdown — so every block tool takes the same trip: read the
  // document as Markdown, rewrite the lines it owns, put it back. The
  // conversion answers with a map from Markdown line to document block, which
  // is how the caret finds its line.
  //
  // Putting it back is remove()+insert(), never `text = …`: both are ordinary
  // edits, so ctrl+z still walks back through toolbar actions.
  function withMarkdown(edit) {
    if (root.readOnly || root.plain || !root.markdown) return
    root.markdown.toMarkdown(documentHtml(), function(md, map) {
      if (!map.ok) return                         // a failed conversion changes nothing
      edit(md.replace(/\n+$/, "").split("\n"), map)
    })
  }

  // The document block a position sits in. Qt separates blocks with U+2029
  // and starts every table cell with U+FDD0 (docs/engine-notes.md).
  function blockAt(pos) {
    var text = area.getText(0, Math.max(0, pos)), count = 0
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code === 0x2029 || code === 0xFDD0) count++
    }
    return count
  }

  // Which Markdown line that block is written on.
  function lineOfBlock(map, block) {
    var blocks = map.blocks || []
    for (var i = 0; i < blocks.length; i++) if (blocks[i] === block) return i
    return Math.max(0, blocks.length - 1)
  }
  function lineAt(map, pos) { return lineOfBlock(map, blockAt(pos)) }
  function caretLine(map) { return lineAt(map, area.cursorPosition) }

  // caret < 0 means "the end of the note". Block styles never change the
  // document's text — a heading is a font size, not a `#` — so the caret's
  // position survives the round trip unchanged.
  function replaceDoc(md, caret) {
    var pos = caret === undefined ? area.cursorPosition : (caret < 0 ? Number.MAX_VALUE : caret)
    root.markdown.toHtml(md, function(html) {
      area.remove(0, area.length)
      area.insert(0, html)
      area.cursorPosition = Math.max(0, Math.min(pos, area.length))
      root.edited()
      focusEditor()
    })
  }

  function setBlockStyle(style) {
    withMarkdown(function(lines, map) {
      var first = lineAt(map, Math.min(area.selectionStart, area.selectionEnd))
      var last = lineAt(map, Math.max(area.selectionStart, area.selectionEnd))
      var caret = area.cursorPosition, changed = false, inFence = false
      for (var i = 0; i < lines.length; i++) {
        if (/^\s*```/.test(lines[i])) { inFence = !inFence; continue }
        if (i < first || i > last) continue
        // table rows and fenced code are never restyled: it would corrupt them
        if (inFence || /^\s*\|/.test(lines[i])) continue
        var next = restyleLine(lines[i], style)
        if (next !== lines[i]) { lines[i] = next; changed = true }
      }
      if (!changed) {
        if (style === "indent") root.statusRequestedText = "A nested list item needs one above it"
        return
      }
      replaceDoc(lines.join("\n"), caret)
    })
  }


  // ── tables: add/remove rows and columns around the caret's cell ──────
  // Qt's plain text separates table cells with U+FDD0 and ends a table with
  // U+FDD1; paragraphs elsewhere end with U+2029. The caret is in a cell when
  // the nearest separator before it is a cell separator and the nearest one
  // after it is a cell or table-end separator — checked in small chunks so
  // long notes stay cheap.
  property bool inTable: false
  readonly property string cellSep: "\uFDD0"
  readonly property string tableEnd: "\uFDD1"
  Timer { id: inTableTimer; interval: 120; onTriggered: root.updateInTable() }
  function scheduleInTable() { inTableTimer.restart() }
  function updateInTable() {
    // getText() ranges are table-granular (a range touching a table returns
    // the whole table), so scan the full text; positions match the caret's.
    if (area.length > 200000) { root.inTable = false; return }
    var t = area.getText(0, area.length), pos = area.cursorPosition
    var seps = [root.sep, root.cellSep, root.tableEnd, "\n"]
    var before = -1, beforeChar = "", after = t.length, afterChar = ""
    for (var i = 0; i < seps.length; i++) {
      var k = t.lastIndexOf(seps[i], pos - 1)
      if (k > before) { before = k; beforeChar = seps[i] }
      var j = t.indexOf(seps[i], pos)
      if (j >= 0 && j < after) { after = j; afterChar = seps[i] }
    }
    root.inTable = beforeChar === root.cellSep && (afterChar === root.cellSep || afterChar === root.tableEnd)
  }

  function restyleLine(line, style) {
    var m = /^([ \t]*)((?:#{1,6}[ \t]+)|(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:\d+[.)][ \t]+)|(?:>[ \t]+))?([\s\S]*)$/.exec(line)
    var indent = m[1] || "", prefix = m[2] || "", content = m[3] || ""
    var isList = /^([-*+]|\d+[.)])[ \t]/.test(prefix)
    switch (style) {
      case "p": return content
      case "h1": return "# " + content
      case "h2": return "## " + content
      case "h3": return "### " + content
      case "ul": return indent + (/^[-*+][ \t](?!\[)/.test(prefix) ? "" : "- ") + content
      case "ol": return indent + (/^\d+[.)][ \t]/.test(prefix) ? "" : "1. ") + content
      // an empty checkbox needs some content or Qt drops the box
      case "todo": return indent + (/\[[ xX]\]/.test(prefix) ? "" : "- [ ] ") + (content || "\u00a0")
      case "quote": return (/^>[ \t]/.test(prefix) ? "" : "> ") + content
      // Lists nest; plain text gets four non-breaking spaces per level, which
      // Markdown keeps and OneNote maps to a real paragraph indent.
      case "indent": return isList ? "  " + indent + prefix + content : indent + prefix + root.nbsp4 + content
      case "outdent": return isList ? indent.substring(2) + prefix + content
                                    : indent + prefix + (content.indexOf(root.nbsp4) === 0 ? content.substring(4) : content)
    }
    return line
  }

  // Where the block holding Markdown line `i` ends (a table, a fenced code
  // block or a single line): snippets go after it, never inside.
  function blockEndLine(lines, i) {
    if (/^\s*\|/.test(lines[i])) {
      while (i + 1 < lines.length && /^\s*\|/.test(lines[i + 1])) i++
      return i
    }
    var fences = 0
    for (var f = 0; f < i; f++) if (/^\s*```/.test(lines[f])) fences++
    if (fences % 2 === 1 || /^\s*```/.test(lines[i])) {
      while (i + 1 < lines.length && !/^\s*```/.test(lines[i + 1])) i++
      if (i + 1 < lines.length) i++
    }
    return i
  }

  function insertSnippet(md) {
    withMarkdown(function(lines, map) {
      var at = blockEndLine(lines, Math.min(caretLine(map), lines.length - 1))
      var rest = lines.slice(at + 1)
      var atEnd = rest.join("").trim() === ""
      var out = lines.slice(0, at + 1).concat([""], md.split("\n"), [""])
      if (!atEnd) out = out.concat(rest)
      replaceDoc(out.join("\n"), atEnd ? -1 : area.cursorPosition)
    })
  }

  // ── tables ──────────────────────────────────────────────────────────
  function splitRow(line) {
    var t = line.trim()
    if (t.charAt(0) === "|") t = t.substring(1)
    if (t.charAt(t.length - 1) === "|") t = t.substring(0, t.length - 1)
    // no regex lookbehind in the QML engine: protect escaped pipes by hand
    return t.split("\\|").join("\u0001").split("|").map(function(c) { return c.split("\u0001").join("\\|") })
  }
  function joinRow(cells) { return "| " + cells.map(function(c) { return c.trim() }).join(" | ") + " |" }

  // The caret's cell, counted from the table's leading cell separator.
  function caretCell() {
    var t = area.getText(0, area.length), caret = area.cursorPosition
    var prev = Math.max(t.lastIndexOf(root.sep, caret - 1), t.lastIndexOf(root.tableEnd, caret - 1))
    var start = t.indexOf(root.cellSep, prev + 1)
    if (start < 0 || start > caret) return -1
    var n = -1                                   // the leading separator is not a cell
    for (var i = start; i < caret; i++) if (t.charAt(i) === root.cellSep) n++
    return Math.max(0, n)
  }

  function tableOp(op) {
    if (!root.inTable) { root.statusRequestedText = "Put the cursor in a table cell first"; return }
    withMarkdown(function(lines, map) { root.rewriteTable(op, lines, map) })
  }

  function rewriteTable(op, lines, map) {
    var at = Math.min(caretLine(map), lines.length - 1)
    while (at >= 0 && !/^\s*\|/.test(lines[at])) at--
    if (at < 0) return
    var first = at, last = at
    while (first > 0 && /^\s*\|/.test(lines[first - 1])) first--
    while (last + 1 < lines.length && /^\s*\|/.test(lines[last + 1])) last++
    var rows = lines.slice(first, last + 1).map(splitRow), cols = rows[0].length
    var cell = caretCell()
    var rowIdx = cell < 0 ? 0 : Math.floor(cell / cols), colIdx = cell < 0 ? 0 : cell % cols
    if (rowIdx > 0) rowIdx += 1                  // the separator row is not a document row
    var blank = function(n) { var out = []; for (var k = 0; k < n; k++) out.push(""); return out }
    if (op === "addRow") {
      rows.splice((rowIdx === 0 ? 1 : rowIdx) + 1, 0, blank(cols))
    } else if (op === "addCol") {
      for (var r2 = 0; r2 < rows.length; r2++) rows[r2].push(r2 === 1 ? "---" : "")
    } else if (op === "delRow") {
      if (rowIdx <= 1) { root.statusRequestedText = "The header row stays"; return }
      rows.splice(rowIdx, 1)
    } else if (op === "delCol") {
      if (cols <= 1) { root.statusRequestedText = "A table needs at least one column"; return }
      for (var r3 = 0; r3 < rows.length; r3++) rows[r3].splice(colIdx, 1)
    }
    var rebuilt = rows.map(function(cells, k) {
      return k === 1 ? "|" + cells.map(function() { return "---" }).join("|") + "|" : joinRow(cells)
    })
    var out = lines.slice(0, first).concat(rebuilt, lines.slice(last + 1))
    replaceDoc(out.join("\n"), area.cursorPosition)
  }


  function toggleCode() {
    if (root.readOnly || root.plain) return
    var f = area.cursorSelection.font
    var mono = /mono/i.test(f.family)
    f.family = mono ? root.bodyFontFamily : "monospace"
    area.cursorSelection.font = f
    root.edited()
  }

  property bool linkBarOpen: false
  function openLinkBar() {
    if (root.readOnly || root.plain) return
    root.linkBarOpen = true
    linkText.text = area.selectedText
    linkUrl.text = "https://"
    Qt.callLater(function() { (area.selectedText ? linkUrl : linkText).forceActiveFocus(); linkUrl.cursorPosition = linkUrl.text.length })
  }
  function insertLink() {
    var url = linkUrl.text.trim(), text = linkText.text.trim() || url
    root.linkBarOpen = false
    if (!url) { focusEditor(); return }
    var s = area.selectionStart, e = area.selectionEnd
    if (s !== e) area.remove(Math.min(s, e), Math.max(s, e))
    // Same colour the converter gives a link, so one typed here and one that
    // came from the note look alike before any reload.
    area.insert(Math.min(s, e), '<a href="' + url.replace(/"/g, "%22") + '" style="color:'
                + root.linkColour + ';">' + text.replace(/</g, "&lt;") + "</a>")
    focusEditor()
    root.edited()
  }

  function tool(id) {
    if (!toolEnabled(["addRow", "addCol", "delRow", "delCol"].indexOf(id) >= 0 ? "table" : id)) return
    switch (id) {
      case "bold": case "italic": case "underline": case "strikeout": toggleFormat(id); break
      case "highlight": highlightSelection(); break
      case "code": toggleCode(); break
      case "h1": case "h2": case "h3": case "p": case "ul": case "ol": case "todo": case "quote": case "indent": case "outdent": setBlockStyle(id); break
      case "table": insertSnippet("| Column 1 | Column 2 |\n|---|---|\n|  |  |"); break
      case "addRow": case "addCol": case "delRow": case "delCol": tableOp(id); break
      case "rule": insertSnippet("---"); break
      case "codeblock": insertSnippet("```\ncode\n```"); break
      case "link": openLinkBar(); break
    }
  }
  function cursorPosition() { return area.cursorPosition }
  function setCursorPosition(pos) { area.cursorPosition = Math.max(0, Math.min(pos, area.length)) }
  function focusTitle() { titleField.forceActiveFocus() }

  readonly property int wordCount: {
    var t = area.getText(0, area.length).replace(/[\u2029\uFDD0\uFDD1]/g, " ").trim()
    return t ? t.split(/\s+/).length : 0
  }

  // ---- formatting (Ctrl+B / I / U)
  // With a selection, Qt applies the format directly. With no selection Qt
  // cannot carry a format into text typed next, so we remember a pending
  // style and apply it to every new run of typed text until the caret moves.
  property var pending: null
  property int pendingLen: 0
  property int pendingCursor: -1
  property bool applying: false

  function clearPending() { pending = null; pendingCursor = -1 }

  function toggleFormat(kind) {
    if (!(kind === "bold" || kind === "italic" || kind === "underline" || kind === "strikeout")) return
    var f = area.cursorSelection.font
    if (area.selectionStart !== area.selectionEnd) {
      f[kind] = !f[kind]
      area.cursorSelection.font = f
      root.edited()
      return
    }
    if (!pending) pending = { bold: f.bold, italic: f.italic, underline: f.underline, strikeout: f.strikeout }
    pending[kind] = !pending[kind]
    pendingLen = area.length
    pendingCursor = area.cursorPosition
  }

  function applyPendingToInsertion() {
    if (!pending || applying) return
    var n = area.length - pendingLen
    var pos = area.cursorPosition
    pendingLen = area.length
    if (n <= 0 || pos - n < 0) { pendingCursor = pos; return }
    applying = true
    area.select(pos - n, pos)
    var f = area.cursorSelection.font
    f.bold = pending.bold; f.italic = pending.italic; f.underline = pending.underline; f.strikeout = pending.strikeout
    area.cursorSelection.font = f
    area.deselect()
    area.cursorPosition = pos
    pendingCursor = pos
    applying = false
  }

  // ---- the note's sheet: title, toolbar and body on one surface. No frame
  // around it and no rule beside it — a box drawn around a page is one line
  // too many.
  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.spacing.xs

    // ---- header: the title belongs on the note's own sheet
    Item {
      width: parent.width
      height: titleColumn.implicitHeight + Style.spacing.md

      Column {
        id: titleColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.xxs

        Text {
          textFormat: Text.PlainText
          visible: root.showingNotice
          width: parent.width
          text: root.noticeTitle
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.titleSize
          elide: Text.ElideRight
        }

        TextField {
          id: titleField
          width: parent.width
          // Sticky Notes have no separate title (subject = first line).
          visible: !root.showingNotice && root.hasTitle
          enabled: root.hasNote && !root.readOnly
          placeholderText: root.hasNote ? "Untitled" : "Note Note"
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.titleSize
          horizontalPadding: Style.spacing.xs
          verticalPadding: 0
          // A title is a title: no box around it. The padding still comes off
          // the spec the field would have drawn, so nothing shifts.
          background: null
          onTextEdited: root.edited()
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.shortcut(event) }
          Keys.onReturnPressed: root.focusEditor()
          Keys.onEnterPressed: root.focusEditor()
          Keys.onDownPressed: root.focusEditor()
        }

        // Only the empty-state hint lives here; where a note comes from is
        // what the sidebar shows.
        Text {
          textFormat: Text.PlainText
          visible: !root.showingNotice && !root.hasNote
          width: parent.width
          text: "Pick a note on the left, or press ctrl+n for a new one."
          color: Util.alpha(root.foreground, 0.65)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    // ---- formatting toolbar (Markdown notes only)
    Flow {
      id: toolbar
      visible: root.hasNote && !root.plain && !root.readOnly && !root.showingNotice && (root.enabledTools === null || root.enabledTools.length > 0)
      width: parent.width
      spacing: Style.spacing.sm

      Repeater {
        // Material Design glyphs from the shell's Nerd Font, by name:
        // md-format_bold, md-format_italic, … (see PROVIDERS.md for tool ids).
        model: [
          { id: "bold", icon: "󰉤", tip: "Bold (ctrl+b)" },
          { id: "italic", icon: "󰉷", tip: "Italic (ctrl+i)" },
          { id: "underline", icon: "󰊇", tip: "Underline (ctrl+u)" },
          { id: "strikeout", icon: "󰊁", tip: "Strikethrough (ctrl+s)" },
          { id: "highlight", icon: "󰙒", tip: "Highlight (ctrl+shift+h)" },
          { id: "code", icon: "󰅴", tip: "Inline code" },
          { id: "sep" },
          { id: "h1", icon: "󰉫", tip: "Heading 1" },
          { id: "h2", icon: "󰉬", tip: "Heading 2" },
          { id: "h3", icon: "󰉭", tip: "Heading 3" },
          { id: "p", icon: "󰉽", tip: "Normal text" },
          { id: "sep" },
          { id: "ul", icon: "󰉹", tip: "Bullet list" },
          { id: "ol", icon: "󰉻", tip: "Numbered list" },
          { id: "todo", icon: "󰥪", tip: "Checkbox" },
          { id: "outdent", icon: "󰉵", tip: "Outdent" },
          { id: "indent", icon: "󰉶", tip: "Indent" },
          { id: "sep" },
          { id: "quote", icon: "󰉾", tip: "Quote" },
          { id: "codeblock", icon: "󰅩", tip: "Code block" },
          { id: "rule", icon: "󰍴", tip: "Horizontal rule" },
          { id: "link", icon: "󰌹", tip: "Insert link" },
          { id: "sep" },
          { id: "table", icon: "󰓫", tip: "Insert a table" },
          { id: "addRow", icon: "󰓳", tip: "Add a row below" },
          { id: "delRow", icon: "󰓵", tip: "Delete this row" },
          { id: "addCol", icon: "󰓬", tip: "Add a column" },
          { id: "delCol", icon: "󰓮", tip: "Delete this column" }
        ]
        delegate: Loader {
          required property var modelData
          sourceComponent: modelData.id === "sep" ? sepComp : buttonComp
          readonly property bool tableOnly: ["addRow", "addCol", "delRow", "delCol"].indexOf(modelData.id) >= 0
          readonly property bool allowed: modelData.id === "sep" || root.toolEnabled(tableOnly ? "table" : modelData.id)
          visible: allowed && (tableOnly ? root.inTable : (modelData.id === "table" ? !root.inTable : true))
          onLoaded: if (modelData.id !== "sep") { item.iconText = modelData.icon; item.tooltipText = modelData.tip; item.toolId = modelData.id }
        }
      }
      Component { id: sepComp; Item { width: Style.spacing.md; height: Style.spacing.controlHeight } }
      Component {
        id: buttonComp
        Button {
          property string toolId: ""
          property bool hovering: false
          // Quiet toolbar: the outline appears only under the cursor.
          bordered: hovering
          foreground: root.foreground
          accent: root.accent
          iconSize: Style.font.icon
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.xxs
          onHovered: function(isHovered) { hovering = isHovered }
          onClicked: root.tool(toolId)
        }
      }
    }

    // ---- link bar
    Row {
      visible: root.linkBarOpen
      width: parent.width
      spacing: Style.spacing.sm
      TextField { id: linkText; width: Style.space(200); placeholderText: "Text"; foreground: root.foreground; accent: root.accent; font.family: root.fontFamily; verticalPadding: Style.spacing.xxs
        Keys.onReturnPressed: root.insertLink(); Keys.onEscapePressed: { root.linkBarOpen = false; root.focusEditor() } }
      TextField { id: linkUrl; width: Style.space(340); placeholderText: "https://…"; foreground: root.foreground; accent: root.accent; font.family: root.fontFamily; verticalPadding: Style.spacing.xxs
        Keys.onReturnPressed: root.insertLink(); Keys.onEscapePressed: { root.linkBarOpen = false; root.focusEditor() } }
      Button { text: "Insert"; bordered: true; foreground: root.foreground; accent: root.accent; verticalPadding: Style.spacing.xxs; onClicked: root.insertLink() }
      Button { text: "Cancel"; bordered: true; foreground: root.foreground; accent: root.accent; verticalPadding: Style.spacing.xxs; onClicked: { root.linkBarOpen = false; root.focusEditor() } }
    }

      // A hairline under the tools, so they read as the note's own strip.
      Item {
        visible: toolbar.visible
        width: parent.width
        height: root.ruleRoomAbove + Style.spacing.hairline + root.ruleRoomBelow

        Rectangle {
          y: root.ruleRoomAbove
          width: parent.width
          height: Style.spacing.hairline
          color: Util.alpha(root.foreground, 0.12)
        }
      }

      Loader {
        id: customLoader
        visible: root.customView !== null
        width: parent.width
        height: visible ? parent.height - y : 0
        sourceComponent: root.customView
        onLoaded: { for (var k in root.customViewProps) if (item.hasOwnProperty(k)) item[k] = root.customViewProps[k] }
      }

      Column {
        visible: root.showingNotice && root.customView === null
        width: parent.width
        spacing: Style.spacing.lg
        leftPadding: Style.spacing.md
        topPadding: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          width: parent.width - Style.spacing.md * 2
          text: root.noticeText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
          lineHeight: 1.25
        }

        Text {
          textFormat: Text.PlainText
          visible: root.noticeCode.length > 0
          text: root.noticeCode
          // Accent as ink — anchored to the foreground so it reads on the
          // theme's background either way round (see NoteList.accentInk).
          color: Qt.tint(root.foreground, Util.alpha(root.accent, 0.6))
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.letterSpacing: 4
        }

        Row {
          spacing: Style.spacing.sm
          Repeater {
            model: root.noticeActions
            Button {
              required property var modelData
              text: modelData.label
              iconText: modelData.icon || ""
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: if (typeof modelData.action === "function") modelData.action()
            }
          }
        }
      }

      Flickable {
        id: flick
        visible: !root.showingNotice
        width: parent.width
        height: parent.height - y
        clip: true
        contentWidth: width
        contentHeight: area.height
        boundsBehavior: Flickable.StopAtBounds

        ListWheel { flick: flick }

        function ensureVisible(r) {
          if (contentY >= r.y) contentY = r.y
          else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
        }

        TextEdit {
          id: area
          width: flick.width
          // Fill the frame so a click anywhere in the empty area focuses
          // the editor.
          height: Math.max(implicitHeight, flick.height)
          leftPadding: Style.spacing.xs
          rightPadding: Style.spacing.xs
          readOnly: !root.hasNote || root.readOnly
          color: root.foreground
          selectionColor: Style.selectionFill
          selectedTextColor: root.foreground
          // Rich text in, rich text out. Markdown cannot hold a highlight,
          // an empty paragraph or an indent, so the document keeps HTML and
          // services/markdown converts at both ends.
          textFormat: root.plain ? TextEdit.PlainText : TextEdit.RichText
          font.family: root.bodyFontFamily
          font.pixelSize: Style.font.subtitle
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            root.shortcut(event)
            if (!event.accepted && !root.plain && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) root.beforeReturn()
          }
          onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
          onTextChanged: {
            if (root.settingText) return
            root.applyPendingToInsertion()
            root.edited()
          }
          // A caret move that isn't the result of typing ends the pending
          // style. While typing, cursorPositionChanged fires before
          // textChanged, so a move that matches the grown length is typing.
          onCursorPositionChanged: {
            root.scheduleInTable()
            if (!root.pending || root.applying) return
            var byTyping = cursorPosition === root.pendingCursor + (length - root.pendingLen)
            if (cursorPosition !== root.pendingCursor && !byTyping) root.clearPending()
          }

          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.xs
            visible: area.length === 0 && !!root.placeholder
            text: root.placeholder
            color: root.foreground
            opacity: 0.45
            font.family: root.bodyFontFamily
            font.pixelSize: Style.font.subtitle
            wrapMode: Text.Wrap
          }
        }
      }
  }

  // Word count sits in the corner of the note's own surface.
  Text {
    id: counter
    visible: root.hasNote && !root.showingNotice
    textFormat: Text.PlainText
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    // Lined up with the note's own margin, not tucked into the corner:
    // it reads as the last line of the page rather than a badge on it.
    anchors.rightMargin: Style.spacing.panelPadding
    anchors.bottomMargin: Style.spacing.panelPadding
    text: root.wordCount + (root.wordCount === 1 ? " word" : " words")
    color: Util.alpha(root.foreground, 0.35)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
