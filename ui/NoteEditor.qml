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
  readonly property alias text: area.text
  readonly property alias title: titleField.text
  readonly property bool bodyFocused: area.activeFocus
  // Plain characters, not Markdown serialisation — for backends that store text.
  function plainText() { return area.getText(0, area.length) }

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

  function setNote(t, body) {
    clearPending()
    settingText = true
    titleField.text = t
    titleField.cursorPosition = 0
    area.text = body
    settingText = false
    area.cursorPosition = area.length
  }

  // Highlight has no Markdown of its own and the editor cannot keep a
  // background colour through a save, so it is written as ==text==, the
  // common extension; providers turn it into their real highlight.
  function wrapSelection(marker) {
    var s = area.selectionStart, e = area.selectionEnd
    if (s === e) return
    var inner = area.getText(s, e)
    area.remove(s, e)
    area.insert(s, marker + inner + marker)
    area.select(s, s + inner.length + marker.length * 2)
    root.edited()
  }
  function focusEditor() { area.forceActiveFocus() }

  // ── formatting tools ────────────────────────────────────────────────
  // Inline styles use the selection's font. Block styles cannot be set from
  // QML, so they go through the Markdown: a marker is put at the end of each
  // selected paragraph, the note is serialised, the marked lines get their
  // new prefix, and the note is reloaded. Snippets are inserted as Markdown,
  // which the editor parses in place.
  readonly property string marker: "⦃M⦄"
  readonly property string nbsp4: "\u00a0\u00a0\u00a0\u00a0"

  readonly property string sep: "\u2029"
  // getText() separates paragraphs with U+2029 and table cells with U+FDD0/U+FDD1.
  function plainText2() { return area.getText(0, area.length).replace(/[\n\uFDD0\uFDD1]/g, root.sep) }
  function paragraphBounds(pos) {
    var all = plainText2()
    var start = all.lastIndexOf(root.sep, pos - 1) + 1
    var end = all.indexOf(root.sep, pos)
    return { start: start, end: end < 0 ? all.length : end }
  }
  function paragraphIndexAt(pos) { return plainText2().substring(0, pos).split(root.sep).length - 1 }
  function caretToParagraphEnd(index) {
    var plain = plainText2(), idx = 0
    for (var n = 0; n < index; n++) { var k = plain.indexOf(root.sep, idx); if (k < 0) break; idx = k + 1 }
    var endOfPara = plain.indexOf(root.sep, idx)
    area.cursorPosition = endOfPara < 0 ? plain.length : endOfPara
  }

  function setBlockStyle(style) {
    if (root.readOnly || root.plain) return
    var s = area.selectionStart, e = area.selectionEnd
    if (s > e) { var tmp = s; s = e; e = tmp }
    var first = paragraphBounds(s), firstIndex = paragraphIndexAt(first.start)
    // mark paragraphs from the last to the first so positions stay valid
    var ends = []
    for (var p = paragraphBounds(e); ; p = paragraphBounds(p.start - 1)) {
      ends.push(p.end)
      if (p.start <= first.start || p.start === 0) break
    }
    root.settingText = true
    for (var k = 0; k < ends.length; k++) area.insert(ends[k], root.marker)
    var md = area.text
    root.settingText = false
    var lines = md.split("\n"), inFence = false
    for (var i = 0; i < lines.length; i++) {
      if (/^\s*```/.test(lines[i])) inFence = !inFence
      if (lines[i].indexOf(root.marker) < 0) continue
      var clean = lines[i].split(root.marker).join("")
      // table rows and code fences are not restyled — that would corrupt them
      lines[i] = (inFence || /^\s*\|/.test(clean)) ? clean : restyleLine(clean, style)
    }
    var body = lines.join("\n")
    if (body === md.split(root.marker).join("")) {
      // nothing changed (e.g. indent outside a list): just drop the markers
      setNote(titleField.text, body)
      caretToParagraphEnd(firstIndex)
      if (style === "indent") root.statusRequestedText = "A nested list item needs one above it"
      return
    }
    setNote(titleField.text, body)
    caretToParagraphEnd(firstIndex)
    focusEditor()
    root.edited()
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
      case "ul": return indent + (/^[-*+]\s(?!\[)/.test(prefix) ? "" : "- ") + content
      case "ol": return indent + (/^\d+[.)]\s/.test(prefix) ? "" : "1. ") + content
      case "todo": return indent + (/\[[ xX]\]/.test(prefix) ? "" : "- [ ] ") + content
      case "quote": return (/^>\s/.test(prefix) ? "" : "> ") + content
      // Lists nest; plain text gets four non-breaking spaces per level, which
      // Markdown keeps and OneNote maps to a real paragraph indent.
      case "indent": return isList ? "  " + indent + prefix + content : indent + prefix + root.nbsp4 + content
      case "outdent": return isList ? indent.substring(2) + prefix + content
                                    : indent + prefix + (content.indexOf(root.nbsp4) === 0 ? content.substring(4) : content)
    }
    return line
  }

  function insertSnippet(md) {
    if (root.readOnly || root.plain) return
    var b = paragraphBounds(area.cursorPosition), index = paragraphIndexAt(b.start)
    root.settingText = true
    area.insert(b.end, root.marker)
    var src = area.text
    root.settingText = false
    var lines = src.split("\n"), out = [], snippetLines = md.split("\n").length, placed = false
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf(root.marker) >= 0) {
        var clean = lines[i].split(root.marker).join("")
        out.push(clean)
        // Qt's writer corrupts a table/code block that directly follows a
        // quote or a code fence; an empty line paragraph in between avoids it.
        if (/^\s*>/.test(clean) || /^\s*```/.test(clean)) { out.push(""); out.push("\u00a0") }
        out.push(""); out.push(md); out.push("")
        placed = true
      } else out.push(lines[i])
    }
    if (!placed) { out.push(""); out.push(md) }
    setNote(titleField.text, out.join("\n"))
    caretToParagraphEnd(index)        // tables/code have their own paragraphs; stay put
    focusEditor()
    root.edited()
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

  function splitRow(line) {
    var t = line.trim()
    if (t.charAt(0) === "|") t = t.substring(1)
    if (t.charAt(t.length - 1) === "|") t = t.substring(0, t.length - 1)
    // no regex lookbehind in the QML engine: protect escaped pipes by hand
    return t.split("\\|").join("\u0001").split("|").map(function(c) { return c.split("\u0001").join("\\|") })
  }
  function joinRow(cells) { return "| " + cells.map(function(c) { return c.trim() }).join(" | ") + " |" }

  function tableOp(op) {
    if (root.readOnly || root.plain) return
    var caret = area.cursorPosition
    root.settingText = true
    area.insert(caret, root.marker)
    var src = area.text
    root.settingText = false
    var lines = src.split("\n"), at = -1
    for (var i = 0; i < lines.length; i++) if (lines[i].indexOf(root.marker) >= 0) { at = i; break }
    var isRow = function(l) { return /^\s*\|/.test(l) }
    if (at < 0 || !isRow(lines[at])) {
      // not in a table: just drop the marker and say so
      setNote(titleField.text, src.split(root.marker).join(""))
      area.cursorPosition = Math.min(caret, area.length)
      root.statusText = "Put the cursor in a table cell first"
      return
    }
    var start = at, end = at
    while (start > 0 && isRow(lines[start - 1])) start--
    while (end + 1 < lines.length && isRow(lines[end + 1])) end++
    var rows = []
    for (var r = start; r <= end; r++) rows.push(splitRow(lines[r]))
    var rowIdx = at - start, colIdx = 0
    for (var c = 0; c < rows[rowIdx].length; c++) if (rows[rowIdx][c].indexOf(root.marker) >= 0) { colIdx = c; rows[rowIdx][c] = rows[rowIdx][c].split(root.marker).join("") }
    var cols = rows[0].length
    var blank = function(n) { var a = []; for (var k = 0; k < n; k++) a.push(""); return a }
    if (op === "addRow") {
      var after = rowIdx === 0 ? 1 : rowIdx            // below the header means below the separator
      rows.splice(after + 1, 0, blank(cols))
      rowIdx = after + 1
    } else if (op === "addCol") {
      for (var r2 = 0; r2 < rows.length; r2++) rows[r2].push(r2 === 1 ? "---" : "")
      colIdx = cols
    } else if (op === "delRow") {
      if (rowIdx <= 1) { root.statusText = "The header row stays; delete the table by selecting it"; setNote(titleField.text, src.split(root.marker).join("")); area.cursorPosition = Math.min(caret, area.length); return }
      rows.splice(rowIdx, 1)
      rowIdx = Math.min(rowIdx, rows.length - 1)
    } else if (op === "delCol") {
      if (cols <= 1) { root.statusText = "A table needs at least one column"; setNote(titleField.text, src.split(root.marker).join("")); area.cursorPosition = Math.min(caret, area.length); return }
      for (var r3 = 0; r3 < rows.length; r3++) rows[r3].splice(colIdx, 1)
      colIdx = Math.min(colIdx, cols - 2)
    }
    var rebuilt = rows.map(function(cells, k) { return k === 1 ? "|" + cells.map(function() { return "---" }).join("|") + "|" : joinRow(cells) })
    var outLines = lines.slice(0, start).concat(rebuilt).concat(lines.slice(end + 1))
    setNote(titleField.text, outLines.join("\n"))
    // caret back into the cell: table cells are consecutive paragraphs, row-major, no separator row
    var before = paragraphIndexAtMarkdownLine(outLines, start)
    var cell = before + (rowIdx === 0 ? 0 : rowIdx - 1) * rows[0].length + colIdx
    caretToParagraphEnd(cell)
    focusEditor()
    root.edited()
  }

  // How many editor paragraphs precede a given Markdown line (approximate:
  // one per non-blank, non-fence, non-separator line; table cells counted).
  function paragraphIndexAtMarkdownLine(lines, lineIndex) {
    var n = 0, inFence = false
    for (var i = 0; i < lineIndex; i++) {
      var l = lines[i]
      if (/^\s*```/.test(l)) { if (!inFence) n++; inFence = !inFence; continue }
      if (inFence) continue
      if (!l.trim()) continue
      if (/^\s*\|[\s:\-|]*\|\s*$/.test(l)) continue          // separator row
      if (/^\s*\|/.test(l)) { n += splitRow(l).length; continue }  // a cell per column
      n++
    }
    return n
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
    area.insert(Math.min(s, e), "[" + text.replace(/\]/g, "") + "](" + url.replace(/\)/g, "%29") + ")")
    focusEditor()
    root.edited()
  }

  function tool(id) {
    if (!toolEnabled(["addRow", "addCol", "delRow", "delCol"].indexOf(id) >= 0 ? "table" : id)) return
    switch (id) {
      case "bold": case "italic": case "underline": case "strikeout": toggleFormat(id); break
      case "highlight": wrapSelection("=="); break
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

  Column {
    anchors.fill: parent
    spacing: Style.spacing.md

    // ---- header
    Item {
      width: parent.width
      height: titleColumn.implicitHeight

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
          font.pixelSize: Style.font.heading
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
          font.pixelSize: Style.font.heading
          horizontalPadding: Style.spacing.xs
          verticalPadding: 0
          onTextEdited: root.edited()
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.shortcut(event) }
          Keys.onReturnPressed: root.focusEditor()
          Keys.onEnterPressed: root.focusEditor()
          Keys.onDownPressed: root.focusEditor()
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.showingNotice
          width: parent.width
          text: root.hasNote
            ? (root.wordCount + (root.wordCount === 1 ? " word" : " words") + " · " + root.notebookName + " / " + root.fileName)
            : "Pick a note on the left, or press ctrl+n for a new one."
          color: Qt.darker(root.foreground, 1.45)
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
      spacing: Style.spacing.xs

      Repeater {
        model: [
          { id: "bold", label: "B", tip: "Bold (ctrl+b)" }, { id: "italic", label: "I", tip: "Italic (ctrl+i)" },
          { id: "underline", label: "U", tip: "Underline (ctrl+u)" }, { id: "strikeout", label: "S", tip: "Strikethrough (ctrl+s)" },
          { id: "highlight", label: "==", tip: "Highlight (ctrl+shift+h)" }, { id: "code", label: "</>", tip: "Inline code" },
          { id: "sep" },
          { id: "h1", label: "H1", tip: "Heading 1" }, { id: "h2", label: "H2", tip: "Heading 2" }, { id: "h3", label: "H3", tip: "Heading 3" }, { id: "p", label: "¶", tip: "Normal text" },
          { id: "sep" },
          { id: "ul", label: "•", tip: "Bullet list" }, { id: "ol", label: "1.", tip: "Numbered list" }, { id: "todo", label: "☑", tip: "Checkbox" },
          { id: "outdent", label: "⇤", tip: "Outdent" }, { id: "indent", label: "⇥", tip: "Indent" },
          { id: "sep" },
          { id: "quote", label: "❝", tip: "Quote" }, { id: "codeblock", label: "{ }", tip: "Code block" }, { id: "table", label: "Table", tip: "Insert a table" },
          { id: "addRow", label: "+Row", tip: "Add a row below the cursor" }, { id: "addCol", label: "+Col", tip: "Add a column" },
          { id: "delRow", label: "−Row", tip: "Delete this row" }, { id: "delCol", label: "−Col", tip: "Delete this column" },
          { id: "rule", label: "—", tip: "Horizontal rule" }, { id: "link", label: "Link", tip: "Insert link" }
        ]
        delegate: Loader {
          required property var modelData
          sourceComponent: modelData.id === "sep" ? sepComp : buttonComp
          readonly property bool tableOnly: ["addRow", "addCol", "delRow", "delCol"].indexOf(modelData.id) >= 0
          readonly property bool allowed: modelData.id === "sep" || root.toolEnabled(tableOnly ? "table" : modelData.id)
          visible: allowed && (tableOnly ? root.inTable : (modelData.id === "table" ? !root.inTable : true))
          onLoaded: if (modelData.id !== "sep") { item.text = modelData.label; item.tooltipText = modelData.tip; item.toolId = modelData.id }
        }
      }
      Component { id: sepComp; Item { width: Style.spacing.md; height: Style.spacing.controlHeight } }
      Component {
        id: buttonComp
        Button {
          property string toolId: ""
          bordered: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.xxs
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

    // ---- content pane (CodeArea-shaped)
    BorderSurface {
      id: frame
      width: parent.width
      height: parent.height - y
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, 0.03)
      borderSpec: Border.controlSpec(area.activeFocus ? "focus" : "normal", root.foreground, root.accent)

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.sm
        spacing: Style.spacing.xs

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
            color: root.accent
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

          WheelHandler {
            target: null
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
              var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 3 : (event.angleDelta.y / 120) * Style.space(72)
              flick.contentY = Math.max(0, Math.min(flick.contentY - dy, Math.max(0, flick.contentHeight - flick.height)))
            }
          }

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
            // Markdown in, Markdown out: headings, bold, italic, lists render
            // live, and `text` serialises back to Markdown for the .md file.
            textFormat: root.plain ? TextEdit.PlainText : TextEdit.MarkdownText
            font.family: root.bodyFontFamily
            font.pixelSize: Style.font.subtitle
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { root.shortcut(event) }
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
              visible: !area.text && !!root.placeholder
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
    }
  }
}
