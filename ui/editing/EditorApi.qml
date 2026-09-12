import QtQuick
import "../MarkdownBlocks.js" as MarkdownBlocks
import "../Dialect.js" as Dialect

// The document API shared by tools. The host and TextEdit are implementation
// details; tool files use the operations below, never the host's QML ids.
QtObject {
  id: api
  required property var host
  required property var textArea

  readonly property bool writable: host.hasNote && !host.readOnly && !host.plain && !host.showingNotice
  readonly property var enabledTools: host.enabledTools
  readonly property int noteToken: host.noteToken
  readonly property bool inTable: host.inTable
  readonly property bool inList: host.inList
  readonly property bool inCode: host.inCode
  readonly property bool bold: pending && pending.bold !== undefined ? pending.bold : textArea.cursorSelection.font.bold
  readonly property bool italic: pending && pending.italic !== undefined ? pending.italic : textArea.cursorSelection.font.italic
  readonly property bool underline: pending && pending.underline !== undefined ? pending.underline : textArea.cursorSelection.font.underline
  readonly property bool strikeout: pending && pending.strikeout !== undefined ? pending.strikeout : textArea.cursorSelection.font.strikeout
  readonly property color foreground: host.foreground
  readonly property color accent: host.accent
  readonly property string fontFamily: host.fontFamily
  readonly property string noteFontFamily: host.noteFontFamily
  readonly property int bodyFontSize: host.bodyFontSize
  readonly property string highlightColour: host.highlightColour
  readonly property string highlightInk: host.highlightInk
  readonly property string codeChipColour: host.codeChipColour
  readonly property string linkColour: host.linkColour
  readonly property string nbsp4: "\u00a0\u00a0\u00a0\u00a0"

  readonly property bool canColorText: host.canColorText

  function setTextColor(color) {
    if (!canColorText || !acceptsInline() || selectionInCode()) {
      return false
    }
    var range = selection()
    if (range.from === range.to) {
      if (!pending) {
        pending = ({})
      }
      pending.color = color
      pendingLen = textArea.length
      pendingCursor = textArea.cursorPosition
      return true
    }
    clearPending()
    var changed = host.setTextColor(range.from, range.to, color)
    if (changed) {
      host.edited()
    }
    return changed
  }

  function supports(capability) {
    return enabledTools === null || enabledTools.indexOf(capability) >= 0
  }

  function selection() {
    var from = Math.min(textArea.selectionStart, textArea.selectionEnd)
    var to = Math.max(textArea.selectionStart, textArea.selectionEnd)
    return { from: from, to: to, text: textArea.selectedText,
             html: inlineFragment(textArea.getFormattedText(from, to)) }
  }

  function capture() {
    return host.editContext()
  }

  function current(context) {
    return writable && host.contextCurrent(context)
  }

  function focus() {
    host.focusEditor()
  }

  function report(message) {
    host.statusRequestedText = message
  }

  function cursorPosition() {
    return textArea.cursorPosition
  }

  function blockAt(position) {
    return host.blockAt(position)
  }

  function blockInfoAt(position) {
    return host.blockInfoAt(position)
  }

  function selectBlock(block) {
    host.selectBlock(block)
  }

  function blockEndLine(lines, line) {
    return host.blockEndLine(lines, line)
  }

  function lastBlockThrough(map, line) {
    return host.lastBlockThrough(map, line)
  }

  function caretLine(map) {
    return host.caretLine(map)
  }

  function lineAt(map, position) {
    return host.lineAt(map, position)
  }

  // Both conversion stages reject a changed note, document or selection.
  // Replacement is one undo transaction, including the optional landing edit.
  function withMarkdown(edit, asText) {
    host.withMarkdown(edit, asText)
  }

  function replaceDocument(markdown, caret, then) {
    host.replaceDoc(markdown, caret, then)
  }

  function insertSnippet(markdown) {
    host.insertSnippet(markdown)
  }

  function insertTable(markdown) {
    host.insertSnippet(markdown, true)
  }

  function acceptsInline() {
    return writable && !host.refusedAcrossCode()
  }

  function selectionInCode() {
    return host.selectionInCode()
  }

  function typeInCode(from, to, text) {
    return host.typeInCode(from, to, text)
  }

  function markedInCode(marker) {
    return host.markedInCode(marker)
  }

  // Insert after the selection before removing it, preserving list and
  // paragraph formats. Undo takes both strokes back together.
  function replaceInline(html, keepSelection) {
    var range = selection()
    host.atomic(function() {
      textArea.insert(range.to, Dialect.documentHtml(html))
      textArea.remove(range.from, range.to)
    })
    if (keepSelection) {
      textArea.select(range.from, range.to)
    }
    host.edited()
  }

  function insertHtml(html) {
    var range = selection()
    host.atomic(function() {
      if (range.from !== range.to) {
        textArea.remove(range.from, range.to)
      }
      textArea.insert(range.from, Dialect.documentHtml(html))
    })
    host.edited()
  }

  function escapeHtml(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;")
  }

  function inlineFragment(html) {
    var f = ((html.split("<body>")[1] || "").split("</body>")[0])
              .replace(/<!--(Start|End)Fragment-->/g, "").trim()
    // A fragment that starts with a list gets a phantom empty paragraph in
    // front from Qt's serialiser; it is not part of the selection.
    f = f.replace(/^<p[^>]*-qt-paragraph-type:empty[^>]*>\s*<br\s*\/?>\s*<\/p>\s*(?=<[uo]l\b)/, "")
    var wrap = /^<(p|li|ul|ol|h[1-6]|blockquote|pre|table|tbody|tr|td|th)(\s[^>]*)?>([\s\S]*)<\/\1>$/
    for (var m = wrap.exec(f); m; m = wrap.exec(f)) {
      if (m[3].indexOf("</" + m[1] + ">") >= 0) {
        break
      }
      f = m[3].trim()
    }
    return f
  }

  function withoutChip(html) {
    var chip = String(api.codeChipColour).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    return html.replace(new RegExp("background-color\\s*:\\s*" + chip + "\\s*;?", "gi"), "")
  }

  function transformBlocks(transform, options) {
    options = options || ({})
    var restyle = function(line) {
      return transform(api.blockParts(line))
    }
    withMarkdown(function(lines, map) {
      var first = lineAt(map, Math.min(textArea.selectionStart, textArea.selectionEnd))
      var last = lineAt(map, Math.max(textArea.selectionStart, textArea.selectionEnd))
      var caret = textArea.cursorPosition, changed = false
      var code = MarkdownBlocks.fences(lines)
      var isList = !!options.list
      // Selected paragraphs arrive with Markdown's blank separator lines
      // between them, and a separator restyled is an empty item — the extra
      // checkbox after every row. Under a list style a separator is never
      // restyled: dropped when the lines on both sides come out as items
      // (the transform toggles, so a click can also *strip* markers — a freed
      // paragraph needs its separator back or the two would lazily merge),
      // kept blank otherwise — before a table or a fence, or beside a line
      // toggling off. Separators own no document block, so the caret's
      // position never counted them and dropping them moves nothing.
      var itemRx = /^\s*([-*+]|\d+[.)])[ \t]/
      var out = [], prevItem = false, prevFreed = false
      for (var i = 0; i < lines.length; i++) {
        // Table rows/HTML tables and fenced code are never restyled.
        if (i < first || i > last || code[i] || /^\s*(\||<table[ >])/.test(lines[i])) {
          out.push(lines[i])
          prevItem = false
          prevFreed = false
          continue
        }
        if (isList && lines[i] === "") {
          var j = i + 1
          while (j <= last && j < lines.length && lines[j] === "") {
            j++
          }
          if (prevItem && j <= last && j < lines.length && !code[j] && !/^\s*\|/.test(lines[j])
              && itemRx.test(restyle(lines[j]))) {
            changed = true
            continue
          }
          out.push(lines[i])
          prevItem = false
          prevFreed = false
          continue
        }
        var next = restyle(lines[i])
        if (next !== lines[i]) {
          changed = true
        }
        // The toggle's other direction: two adjacent items freed of their
        // markers are two paragraphs, and paragraphs need the separator a
        // tight list never had — without it Markdown lazily reads them as
        // one line.
        var freed = isList && itemRx.test(lines[i]) && !itemRx.test(next)
        if (freed && prevFreed) {
          out.push("")
        }
        out.push(next)
        prevItem = isList && itemRx.test(next)
        prevFreed = freed
      }
      if (!changed) {
        if (options.unchangedMessage) {
          api.report(options.unchangedMessage)
        }
        return
      }
      replaceDocument(out.join("\n"), caret)
    })
  }

  function blockParts(line) {
    var m = /^([ \t]*)((?:#{1,6}[ \t]+)|(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:\d+[.)][ \t]+)|(?:>[ \t]+))?([\s\S]*)$/.exec(line)
    var indent = m[1] || "", prefix = m[2] || "", content = m[3] || ""
    var isList = /^([-*+]|\d+[.)])[ \t]/.test(prefix)
    return { indent: indent, prefix: prefix, content: content, isList: isList }
  }

  // Native table operations address the innermost QTextTable. The older
  // Markdown transform remains the plain-table fallback without the helper.
  function tableContext() {
    return host.tableContext()
  }

  function changeTable(operation, index, count) {
    return host.changeTable(operation, index, count)
  }

  function transformTable(transform) {
    if (!inTable) {
      report("Put the cursor in a table cell first")
      return
    }
    withMarkdown(function(lines, map) {
      api.rewriteTable(transform, lines, map)
    })
  }

  function rewriteTable(transform, lines, map) {
    var at = Math.min(caretLine(map), lines.length - 1)
    if (/^\s*<table[ >]/.test(lines[at] || "")) {
      report("Rebuild the native text helper to edit nested table rows and columns")
      return
    }
    while (at >= 0 && !/^\s*\|/.test(lines[at])) {
      at--
    }
    if (at < 0) {
      return
    }
    var first = at, last = at
    while (first > 0 && /^\s*\|/.test(lines[first - 1])) {
      first--
    }
    while (last + 1 < lines.length && /^\s*\|/.test(lines[last + 1])) {
      last++
    }
    var rows = lines.slice(first, last + 1).map(function(line) { return api.host.splitRow(line) }), cols = rows[0].length
    var cell = host.caretCell()
    var rowIdx = cell < 0 ? 0 : Math.floor(cell / cols), colIdx = cell < 0 ? 0 : cell % cols
    if (rowIdx > 0) {
      rowIdx += 1  // the separator row is not a document row
    }
    if (transform(rows, rowIdx, colIdx) === false) {
      return
    }
    var rebuilt = rows.map(function(cells, k) {
      return k === 1 ? "|" + cells.map(function() { return "---" }).join("|") + "|" : api.host.joinRow(cells)
    })
    var out = lines.slice(0, first).concat(rebuilt, lines.slice(last + 1))
    replaceDocument(out.join("\n"), textArea.cursorPosition)
  }

  // ---- formatting (Ctrl+B / I / U)
  // With a selection, Qt applies the format directly. With no selection Qt
  // cannot carry a format into text typed next, so we remember a pending
  // style and apply it to every new run of typed text until the caret moves.
  property var pending: null
  property int pendingLen: 0
  property int pendingCursor: -1
  property bool applying: false

  function clearPending() {
    pending = null
    pendingCursor = -1
  }

  function toggleFont(kind, marker) {
    if (!(kind === "bold" || kind === "italic" || kind === "underline" || kind === "strikeout")) {
      return
    }
    if (!acceptsInline() || markedInCode(marker)) {
      return
    }
    var f = textArea.cursorSelection.font
    if (textArea.selectionStart !== textArea.selectionEnd) {
      f[kind] = !f[kind]
      textArea.cursorSelection.font = f
      host.edited()
      return
    }
    if (!pending) {
      pending = { bold: f.bold, italic: f.italic, underline: f.underline, strikeout: f.strikeout }
    }
    var next = Object.assign({}, pending)
    next[kind] = !(pending[kind] === undefined ? f[kind] : pending[kind])
    pending = next
    pendingLen = textArea.length
    pendingCursor = textArea.cursorPosition
  }

  function typePending(text) {
    if (!pending || !writable || !host.canColorText) {
      return false
    }
    var range = selection()
    applying = true
    try {
      var position = host.insertFormattedText(range.from, range.to, text, pending)
      if (position < 0) {
        return false
      }
      textArea.cursorPosition = position
      pendingLen = textArea.length
      pendingCursor = position
      return true
    } finally {
      applying = false
    }
  }

  function applyPendingToInsertion() {
    if (!pending || applying) {
      return
    }
    var n = textArea.length - pendingLen
    var pos = textArea.cursorPosition
    pendingLen = textArea.length
    if (n <= 0 || pos - n < 0) {
      pendingCursor = pos
      return
    }
    applying = true
    textArea.select(pos - n, pos)
    // Formatting belongs to the keystroke that inserted this run, including
    // a combination of pending font attributes and text color.
    host.atomic(function() {
      var f = textArea.cursorSelection.font
      var hasFont = false
      for (var kind of ["bold", "italic", "underline", "strikeout"]) {
        if (api.pending[kind] !== undefined) {
          f[kind] = api.pending[kind]
          hasFont = true
        }
      }
      if (hasFont) {
        textArea.cursorSelection.font = f
      }
      if (api.pending.color !== undefined) {
        api.host.setTextColor(pos - n, pos, api.pending.color)
      }
    }, true)
    textArea.deselect()
    textArea.cursorPosition = pos
    pendingCursor = pos
    applying = false
  }

}
