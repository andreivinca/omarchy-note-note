import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "QuoteBars.js" as QuoteBars

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
  // The surface the note sits on — what the checkbox cover paints in, so
  // the native marker glyph vanishes under it (block decorations, below).
  property color background: Color.menu.background
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
  // The note's own directory, for notes that name their images by a relative
  // path (the local provider's `.assets/`): the document resolves the links
  // against it, and the converter measures the files through it. Set by the
  // host from load()'s `base`, before the body goes in; "" for backends
  // whose images are absolute file:// URLs.
  property string documentBase: ""
  readonly property string highlightColour: root.markdown ? root.markdown.highlight : "#f9e2af"
  readonly property string highlightInk: root.markdown ? root.markdown.highlightInk : "#1e1e2e"
  readonly property string linkColour: root.markdown ? root.markdown.link : "#4282d7"
  // The chip the converter paints behind inline code (Markdown.qml); the
  // code tool applies the same one, so code made here and code that came
  // from the note look alike.
  readonly property string codeChipColour: root.markdown ? root.markdown.codeChip : "transparent"

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
    root.markdown.toMarkdown(documentHtml(), function(md) { callback(md) }, root.documentBase)
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

  // A document title needs display weight, while the readable-width cap keeps
  // both short notes and long prose calm on wide windows.
  readonly property int titleSize: Math.round(Style.font.heading * 1.55)
  readonly property real contentMaxWidth: Style.space(620)
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
    clearView()
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
    root.markdown.toHtml(body, function(html) { root.showBody(html, token) }, root.documentBase)
  }

  function showBody(document, token) {
    if (token !== root.noteToken) return          // a newer note won the race
    settingText = true
    area.text = document
    settingText = false
    // The note opens at its top: caret on the first character, and the view
    // pinned there — ensureVisible follows the caret everywhere after this.
    area.cursorPosition = 0
    flick.contentY = 0
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
    var lit = withoutChip(fragment).indexOf("background-color") >= 0
    // The restyled copy goes in after the selection and the original comes
    // out second: inserted at a block's start instead, Qt hands the block
    // the fragment's own paragraph format, and a list item stops being one.
    area.insert(to, lit ? unhighlight(fragment)
                        : '<span style="background-color:' + root.highlightColour
                          + "; color:" + root.highlightInk + ';">' + fragment + "</span>")
    area.remove(from, to)
    area.select(from, to)
    root.edited()
  }

  // Qt serialises any range as a whole document whose body holds the block
  // the selection sits in — a paragraph, a heading, a list wrapping its item,
  // a table wrapping its cell. Peel every wrapper that encloses the whole
  // fragment, down to the inline HTML actually selected: a block tag put back
  // mid-line starts a new block, which is how a highlight used to split a
  // checkbox line. A wrapper whose closing tag appears again inside is a
  // selection spanning blocks, and stays.
  function inlineFragment(html) {
    var f = ((html.split("<body>")[1] || "").split("</body>")[0])
              .replace(/<!--(Start|End)Fragment-->/g, "").trim()
    // A fragment that starts with a list gets a phantom empty paragraph in
    // front from Qt's serialiser; it is not part of the selection.
    f = f.replace(/^<p[^>]*-qt-paragraph-type:empty[^>]*>\s*<br\s*\/?>\s*<\/p>\s*(?=<[uo]l\b)/, "")
    var wrap = /^<(p|li|ul|ol|h[1-6]|blockquote|pre|table|tbody|tr|td|th)(\s[^>]*)?>([\s\S]*)<\/\1>$/
    for (var m = wrap.exec(f); m; m = wrap.exec(f)) {
      if (m[3].indexOf("</" + m[1] + ">") >= 0) break
      f = m[3].trim()
    }
    return f
  }

  // The marker colour goes, and so does the ink that came with it — left
  // behind, it kept reading as near-black text on a dark theme. Only the
  // highlight's own ink is taken: a link keeps its blue, and inline code
  // keeps its chip — that background is the code tool's, not this one's.
  function unhighlight(fragment) {
    var ink = String(root.highlightInk).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    var chip = String(root.codeChipColour).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    return fragment.replace(new RegExp('background-color\\s*:(?!\\s*' + chip + '\\s*[;"])[^;"]*;?', "gi"), "")
                   .replace(new RegExp("color\\s*:\\s*" + ink + "\\s*;?", "gi"), "")
  }

  // The chip is a background-color too; the highlight tool looks through
  // this, or a selection holding inline code would read as already lit.
  function withoutChip(html) {
    var chip = String(root.codeChipColour).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    return html.replace(new RegExp("background-color\\s*:\\s*" + chip + "\\s*;?", "gi"), "")
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

  // Ctrl+Shift+V: the clipboard's text and nothing that rode along with it —
  // no fonts, no colours, no source formatting. The text goes in escaped, so
  // nothing in it can read as markup; newlines become line breaks, and
  // white-space:pre keeps the runs of spaces (a pasted snippet's indentation)
  // that Qt's HTML parser folds otherwise. Inserted after the selection and
  // the selection removed second, the highlight's order, for the same
  // block-start reason. A clipboard with no text pastes nothing.
  function pastePlain() {
    if (root.readOnly) return
    if (!root.clipboard || root.plain) { area.paste(); return }
    root.clipboard.takeText(function(text) {
      if (!text) return
      var from = Math.min(area.selectionStart, area.selectionEnd)
      var to = Math.max(area.selectionStart, area.selectionEnd)
      var esc = text.replace(/\r\n?/g, "\n").replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    .replace(/\n/g, "<br />")
      var before = area.length
      area.insert(to, '<span style="white-space:pre;">' + esc + "</span>")
      var added = area.length - before
      if (from !== to) area.remove(from, to)
      area.cursorPosition = from + added
      root.edited()
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
    fitImageAt(at)
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
    }, root.documentBase)
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
  function replaceDoc(md, caret, then) {
    var pos = caret === undefined ? area.cursorPosition : (caret < 0 ? Number.MAX_VALUE : caret)
    root.markdown.toHtml(md, function(html) {
      area.remove(0, area.length)
      area.insert(0, html)
      area.cursorPosition = Math.max(0, Math.min(pos, area.length))
      root.edited()
      focusEditor()
      if (then) then()
    }, root.documentBase)
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

  // ── block decorations: quote bars and code slabs ────────────────────
  // Qt rich text has no block borders, padding or rounded corners, so the
  // classic bar beside a quote and the slab behind a code block cannot live
  // in the document: the editor draws them — rectangles over each run of
  // quote or code blocks (QuoteBars.js), placed with positionToRectangle.
  // Decoration only: they never enter the document, the caret map or the
  // note. The document's own code background is a near-invisible marker
  // (the dialect's code signature), not the slab the eye sees.
  //
  // The blocks come from the native inspector (cpp/) when it is built, and
  // from scanning the document's HTML when it is not: the Loader errors on
  // the missing library and the fallback carries on.
  property var quoteBars: []
  property var codeSlabs: []
  // The checkboxes wear the same trick: Qt Quick paints a task item's
  // marker as a raw ☐/☒ glyph, hardcoded in its renderer, so the editor
  // covers the glyph's cell with the surface colour and draws the box the
  // eye sees. The marker itself stays in the document — it carries the
  // state, and a click on it is Qt's own toggle.
  property var checkBoxes: []
  readonly property color quoteBarColour: Util.alpha("#2e75b5", 0.8)
  readonly property color codeSlabColour: Util.alpha(root.foreground, 0.07)
  Timer { id: decorTimer; interval: 120; onTriggered: root.updateDecorations() }
  // With the native inspector the pass is cheap — real block formats, no
  // serialisation — so it runs synchronously and the bars and slabs move in
  // the same frame as the edit. The HTML-scan fallback serialises the whole
  // document, so it keeps the debounce (and huge notes take it too).
  function scheduleDecorations() {
    if (nativeBlocks.item && area.length <= 200000) updateDecorations()
    else decorTimer.restart()
  }
  Loader {
    id: nativeBlocks
    source: "NativeBlocks.qml"
    onStatusChanged: if (status === Loader.Error)
      console.log("note-note: native text inspector not built (sh cpp/build.sh); scanning HTML instead")
  }

  // The native marker's cell, measured the way Qt Quick lays it out: the
  // glyph's right edge sits one space ahead of the text, the glyph its own
  // advance before that, fontMetrics.height() tall from the line's top
  // (qquicktextnodeengine.cpp, measured on 6.11). The drawn box covers
  // exactly that cell, so Qt's glyph never shows through.
  FontMetrics { id: markerMetrics; font: area.font }

  // An edit can leave the document off the form a re-render would give;
  // the inspector restores it synchronously from the text change, before
  // the frame paints — on the debounced decorations tick the wrong form
  // was visible for a blink first. Three restorations: items typed into a
  // list inherit the split item's margins (normalizeListMargins), a block
  // born outside the dialect's writer misses its line height
  // (normalizeLineHeights), and Enter or a delete can bare the block
  // above a table, which Qt then hides — the table rides up over the
  // caret's row until the block gets its blank filler back
  // (fillEmptyBlocksBeforeTables). The caret goes back in front of a
  // filler put in under it, so typing lands ahead of the invisible
  // character. The flag stops the inspector's writes from re-entering as
  // edits of their own.
  property bool normalizing: false
  function normalizeNow() {
    if (root.normalizing || root.plain || root.readOnly || !nativeBlocks.item) return
    if (!nativeBlocks.item.document) nativeBlocks.item.document = area.textDocument
    root.normalizing = true
    nativeBlocks.item.normalizeListMargins()
    nativeBlocks.item.normalizeLineHeights()
    var filled = nativeBlocks.item.fillEmptyBlocksBeforeTables()
    root.normalizing = false
    if (filled >= 0 && area.cursorPosition === filled + 1) area.cursorPosition = filled
  }

  function updateDecorations() {
    if (root.plain) { root.quoteBars = []; root.codeSlabs = []; root.imageBoxes = []; root.checkBoxes = []; return }
    var runs, boxes
    // The native path runs even on an empty document: a note can hold no
    // characters and still be one checkbox block (docs/engine-notes.md),
    // and that box deserves its drawn face too.
    if (nativeBlocks.item) {
      if (!nativeBlocks.item.document) nativeBlocks.item.document = area.textDocument
      var bs = nativeBlocks.item.blocks()
      runs = QuoteBars.runsFromBlocks(bs)
      boxes = QuoteBars.boxesFromBlocks(bs)
      root.imageBoxes = root.readOnly ? [] : root.imageGeometry()
    } else if (area.length > 0 && area.length <= 200000) {
      var html = area.getFormattedText(0, area.length), text = area.getText(0, area.length)
      runs = QuoteBars.runs(html, text)
      boxes = QuoteBars.boxes(html, text)
    } else { root.quoteBars = []; root.codeSlabs = []; root.checkBoxes = []; return }
    var bars = [], slabs = [], marks = [], i
    for (i = 0; i < runs.quote.length; i++) bars.push(root.barGeometry(runs.quote[i].from, runs.quote[i].to))
    for (i = 0; i < runs.code.length; i++) slabs.push(root.slabGeometry(runs.code[i].from, runs.code[i].to))
    for (i = 0; i < boxes.length; i++) {
      var r = area.positionToRectangle(boxes[i].position)
      marks.push({ position: boxes[i].position, checked: boxes[i].checked, x: r.x, y: r.y })
    }
    root.quoteBars = bars
    root.codeSlabs = slabs
    root.checkBoxes = marks
  }

  function barGeometry(from, to) {
    var a = area.positionToRectangle(from), b = area.positionToRectangle(to)
    // The quote's text starts one quote margin in; the bar stands in that
    // margin, a small gap ahead of the text.
    return { x: a.x - 16, y: a.y, height: b.y + b.height - a.y }
  }

  function slabGeometry(from, to) {
    var a = area.positionToRectangle(from), b = area.positionToRectangle(to)
    // The code text is inset by the writer's padding margin (CODE_PAD_PX);
    // the slab reaches back over it, and past the lines vertically, so the
    // text sits padded inside it. Indented code carries its indent in `a.x`.
    var x = a.x - 14
    return { x: x, y: a.y - 8, width: Math.max(0, area.width - x - Style.spacing.xs),
             height: b.y + b.height - a.y + 16 }
  }

  // ── image resize: a marker on every image's bottom-right corner ─────
  // Dragging it sets the image's display width (aspect kept), written into
  // the document by the native inspector as one format-only edit — one undo
  // step — and into the note as `![alt](src){width=N}` by the converter.
  // Without the built inspector images simply have no handle: QML can
  // neither read an image's drawn size nor set one without rewriting HTML.
  //
  // [{ position, x, y, width, height }] in the editor's own coordinates.
  property var imageBoxes: []
  // Mirrors dialect.MAX_IMAGE_DISPLAY in services/markdown/qthtml — the
  // display cap the converter puts on a large image that names no width.
  readonly property int maxImageDisplay: 640
  readonly property int minImageWidth: 48
  onReadOnlyChanged: scheduleDecorations()

  function imageGeometry() {
    var images = nativeBlocks.item.images(), out = []
    for (var i = 0; i < images.length; i++) {
      var img = images[i]
      if (!(img.width > 0) || !(img.height > 0)) continue   // not loaded yet
      // The caret rectangle before the image is its left edge and its
      // line's top; the image's bottom sits on its own baseline (ascent).
      var r = area.positionToRectangle(img.position)
      out.push({ position: img.position, x: r.x, y: r.y + Math.max(0, img.ascent - img.height),
                 width: img.width, height: img.height })
    }
    return out
  }

  function resizeImage(position, width) {
    if (root.readOnly || root.plain || !nativeBlocks.item) return
    if (!nativeBlocks.item.document) nativeBlocks.item.document = area.textDocument
    if (!nativeBlocks.item.setImageWidth(position, width)) return
    root.updateDecorations()
    root.edited()
  }

  // A screenshot pastes far wider than the pane; give it the display cap the
  // loader would apply (maxImageDisplay). The cap never reaches the note —
  // the converter recognises it — so an untouched paste keeps the note
  // clean, and the handle is how a width becomes the author's own.
  function fitImageAt(pos) {
    if (!nativeBlocks.item) return                // pasted large, capped on reload
    if (!nativeBlocks.item.document) nativeBlocks.item.document = area.textDocument
    var text = area.getText(pos, Math.min(pos + 4, area.length)), i = text.indexOf(root.objectChar)
    if (i < 0) return
    var images = nativeBlocks.item.images()
    for (var k = 0; k < images.length; k++)
      if (images[k].position === pos + i && images[k].naturalWidth > root.maxImageDisplay) {
        // Joined to the paste's own edit, so one Ctrl+Z takes both.
        nativeBlocks.item.setImageWidth(pos + i, root.maxImageDisplay, true)
        return
      }
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

  // An empty code block, ready to type into. Its one empty line is held open
  // by a filler character (services/markdown/qthtml/dialect.py,
  // EMPTY_CODE_LINE); selecting the filler puts the caret in the block with
  // the monospace format, and the first keystroke replaces it — the converter
  // strips a leftover one anyway.
  function insertCodeBlock() {
    withMarkdown(function(lines, map) {
      var at = blockEndLine(lines, Math.min(caretLine(map), lines.length - 1))
      var rest = lines.slice(at + 1)
      var atEnd = rest.join("").trim() === ""
      var out = lines.slice(0, at + 1).concat(["", "```", "", "```", ""])
      if (!atEnd) out = out.concat(rest)
      // The new block lands right after the last document block at or before
      // the insertion line; fence lines and blanks own no block (NO_BLOCK).
      var block = -1
      for (var i = 0; i <= at && i < (map.blocks || []).length; i++)
        if (map.blocks[i] > block) block = map.blocks[i]
      replaceDoc(out.join("\n"), area.cursorPosition, function() { selectBlock(block + 1) })
    })
  }

  // Where a document block's content starts: blocks begin after each
  // paragraph or cell separator (blockAt counts them the same way).
  function blockStart(block) {
    var t = area.getText(0, area.length), n = 0, start = 0
    for (var i = 0; i < t.length && n < block; i++) {
      var c = t.charCodeAt(i)
      if (c === 0x2029 || c === 0xFDD0) { n++; start = i + 1 }
    }
    return start
  }

  // Select the (single-character) content of a document block.
  function selectBlock(block) {
    var start = blockStart(block)
    area.select(start, Math.min(start + 1, area.length))
  }

  // ── leaving a block: the second Enter ───────────────────────────────
  // Qt's own Enter continues a code block, quote or list with a fresh empty
  // line; Enter again on that empty line leaves the block instead. The edit
  // takes the same markdown trip as every block tool (docs/decisions.md):
  // the empty line comes off the block, a blank paragraph lands after it,
  // and its filler is selected so typing starts clean.

  // The caret's block as the dialect sees it: its kind (code line, quote
  // line, list item), whether it is empty, and whether it ends its run —
  // from the native inspector when built, from the document's HTML when not.
  function blockInfoAt(pos) {
    // The full text once, indexed — never ranged getText, which answers
    // with the whole table for any range touching one (see updateInTable).
    var t = area.getText(0, area.length)
    var kind = "", next = "", start = -1, end = -1
    if (nativeBlocks.item) {
      if (!nativeBlocks.item.document) nativeBlocks.item.document = area.textDocument
      var bs = nativeBlocks.item.blocks()
      for (var i = 0; i < bs.length; i++) {
        if (pos < bs[i].position || pos > bs[i].end) continue
        start = bs[i].position; end = bs[i].end
        kind = bs[i].list ? "list" : QuoteBars.kindOfBlock(bs[i])
        if (i + 1 < bs.length) next = bs[i + 1].list ? "list" : QuoteBars.kindOfBlock(bs[i + 1])
        break
      }
    } else if (area.length <= 200000) {
      var n = 0
      start = 0; end = t.length
      for (var j = 0; j < t.length; j++) {
        var c = t.charCodeAt(j)
        if (c !== 0x2029 && c !== 0xFDD0) continue
        if (j < pos) { n++; start = j + 1 } else { end = j; break }
      }
      var ks = QuoteBars.kinds(area.getFormattedText(0, area.length))
      kind = inListItem(pos) ? "list" : (ks[n] || "")
      if (end < t.length) next = inListItem(end + 1) ? "list" : (ks[n + 1] || "")
    }
    if (start < 0) return null
    var text = t.substring(start, end)
    return { kind: kind, empty: text === "" || text === root.imageLead, last: next !== kind }
  }

  // Code and quotes leave only from their run's last line (an empty line
  // higher up is content); an empty list item leaves from anywhere,
  // splitting the list the way every editor does.
  function returnLeavesBlock() {
    if (root.readOnly || root.plain || area.selectionStart !== area.selectionEnd) return false
    if (root.tableReturn()) return true
    var b = blockInfoAt(area.cursorPosition)
    if (!b || !b.empty || !b.kind) return false
    if (b.kind !== "list" && !b.last) return false
    root.leaveBlock(b.kind)
    return true
  }

  // Enter in a table's last cell makes an extra line inside the cell (Qt's
  // own behaviour); Enter again on that empty line takes it out and starts
  // a new row, caret in its first cell. That empty line is the one block
  // bounded by a paragraph separator and the table's end character.
  function tableReturn() {
    // The caret's block, bounded by a paragraph separator and the table's
    // end, holding nothing or only a filler space (an empty cell's, pushed
    // down by typing before it). Read the full text and index it: a ranged
    // getText touching a table answers with the whole table (updateInTable).
    var pos = area.cursorPosition
    if (pos <= 0 || pos >= area.length) return false
    var t = area.getText(0, area.length)
    var sep = function(c) { return c === 0x2029 || c === 0xFDD0 || c === 0xFDD1 }
    var start = pos, end = pos
    while (start > 0 && !sep(t.charCodeAt(start - 1))) start--
    while (end < t.length && !sep(t.charCodeAt(end))) end++
    if (start === 0 || end === t.length) return false
    if (t.charCodeAt(start - 1) !== 0x2029 || t.charCodeAt(end) !== 0xFDD1) return false
    var body = t.substring(start, end)
    if (body !== "" && body !== root.imageLead) return false
    root.leaveTableRow()
    return true
  }

  function leaveTableRow() {
    withMarkdown(function(lines, map) {
      var cellBlock = blockAt(area.cursorPosition) - 1   // the extra line adds one
      var last = lineOfBlock(map, cellBlock)
      if (!/^\s*\|/.test(lines[last] || "")) return
      var first = last
      while (first > 0 && /^\s*\|/.test(lines[first - 1])) first--
      var cols = splitRow(lines[first]).length
      var cells = []
      for (var k = 0; k < cols; k++) cells.push("")
      var out = lines.slice(0, last + 1).concat([joinRow(cells)], lines.slice(last + 1))
      // a row's line carries its first cell's block; the new row's first
      // cell comes one row of cells later
      var target = map.blocks[last] + cols
      replaceDoc(out.join("\n"), area.cursorPosition,
                 function() { area.cursorPosition = root.blockStart(target) })
    })
  }

  function leaveBlock(kind) {
    withMarkdown(function(lines, map) {
      var i = caretLine(map)
      var target = map.blocks[i]
      var out = lines.slice()
      if (kind === "code") {
        // the caret's line is the fence's empty last line; it comes out,
        // and the blank goes in after the closing fence
        if (out[i] !== "") return
        out.splice(i, 1)
        if (!/^\s*```/.test(out[i] || "")) return
        out.splice(i + 1, 0, "", " ", "")
      } else if (kind === "list") {
        out.splice(i, 1, "", " ", "")
      }
      // a quote's empty line already reads back as a blank paragraph
      // (kept in the map now, trimmed only on save): re-rendering the
      // markdown is the whole edit
      replaceDoc(out.join("\n"), area.cursorPosition, function() { selectBlock(target) })
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


  // Inline code takes the highlight's trip: the selection's HTML goes back
  // in wearing the mono family — which IS the dialect's code span — and the
  // chip the converter paints behind loaded code (codeChipColour), so the
  // style is visible the moment the tool is used. Same insert-then-remove
  // order as highlightSelection, for the same list-item reason.
  function toggleCode() {
    if (root.readOnly || root.plain) return
    var from = Math.min(area.selectionStart, area.selectionEnd)
    var to = Math.max(area.selectionStart, area.selectionEnd)
    if (from === to) return
    var fragment = inlineFragment(area.getFormattedText(from, to))
    var mono = /font-family:[^;"]*mono/i.test(fragment)
    area.insert(to, mono ? uncode(fragment)
                         : "<span style=\"font-family:'monospace'; background-color:"
                           + root.codeChipColour + ';">' + fragment + "</span>")
    area.remove(from, to)
    area.select(from, to)
    root.edited()
  }

  // Off is both halves off: the mono family (the body font takes over) and
  // the chip. Only mono families are taken — any other face a paste brought
  // along is not this tool's to touch.
  function uncode(fragment) {
    return withoutChip(fragment.replace(/font-family:[^;"]*mono[^;"]*;?/gi, ""))
  }

  // ── escaping inline code: Right at its end ──────────────────────────
  // Qt takes the typing format from the character before the caret, so code
  // that ends the note traps it: there is no character to arrow past, and
  // everything typed next would come out mono on the chip. Anywhere else
  // Right already escapes — onto the next character, or onto the next
  // block, where a non-empty block's own first character wins. So at the
  // note's very end Right steps out instead: one plain-format space goes
  // in after the code and the caret lands beyond it, typing in the body
  // style. The space is the one the next word would want anyway; left
  // unused at the line's end, the round trips drop it (Qt swallows a
  // paragraph's trailing space — which is also why the insert needs
  // white-space:pre to survive at all; measured on 6.11). A second Right
  // is refused by the mono test: the character before the caret is now
  // the plain space itself.
  function escapeCode() {
    if (root.readOnly || root.plain) return false
    if (area.selectionStart !== area.selectionEnd) return false
    var pos = area.cursorPosition
    if (pos === 0 || pos < area.length) return false
    if (!/font-family:[^;"]*mono/i.test(area.getFormattedText(pos - 1, pos))) return false
    // A code block's lines are mono too, and must stay all-mono or the
    // block stops being one (reader): the escape is inline code's only.
    var b = blockInfoAt(pos)
    if (b && b.kind === "code") return false
    area.insert(pos, '<span style="white-space:pre;"> </span>')
    area.cursorPosition = area.length
    root.edited()
    return true
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
      case "codeblock": insertCodeBlock(); break
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
    id: sheet
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.spacing.panelPadding
    anchors.bottomMargin: Style.spacing.panelPadding
    x: Math.max(Style.spacing.panelPadding, (parent.width - width) / 2)
    width: Math.min(root.contentMaxWidth, parent.width - Style.spacing.panelPadding * 2)
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
          font.bold: true
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

      // The rows of the text-style menu, the toolbar's one dropdown: each
      // previews its own size, on the same scale the dialect writes headings
      // at (HEADING_FONT_SIZE in services/markdown/qthtml/dialect.py —
      // xx-large, x-large, large). Sub- and superscript stayed out: the
      // dialect's Markdown has no syntax for them, so the round trip through
      // save would drop them (docs/decisions.md). Providers gate the ids one
      // by one, so the menu carries only the rows the provider can store.
      readonly property var styleMenuRows: [
        { id: "h1", label: "Heading 1", scale: 2.0, bold: true },
        { id: "h2", label: "Heading 2", scale: 1.5, bold: true },
        { id: "h3", label: "Heading 3", scale: 1.17, bold: true },
        { id: "p", label: "Normal text", scale: 1.0, bold: false }
      ].filter(function(o) { return root.toolEnabled(o.id) })

      Repeater {
        // Material Design glyphs from the shell's Nerd Font, by name:
        // md-format_bold, md-format_italic, … (see PROVIDERS.md for tool ids).
        model: [
          { id: "bold", icon: "󰉤", tip: "Bold (ctrl+b)" },
          { id: "italic", icon: "󰉷", tip: "Italic (ctrl+i)" },
          { id: "underline", icon: "󰊇", tip: "Underline (ctrl+u)" },
          { id: "strikeout", icon: "󰊁", tip: "Strikethrough (ctrl+s)" },
          { id: "sep" },
          // The dressing-up group: what a run of text *is* (highlight, code,
          // heading), apart from the toggles of how it is drawn. The style
          // entry is one dropdown, not four buttons — the block styles read
          // as a choice of one, the way bold/italic never could. Its rows
          // keep the ids h1 h2 h3 p (toolbar.styleMenuRows), so providers
          // and `editorTool` see nothing new.
          { id: "highlight", icon: "󰙒", tip: "Highlight (ctrl+shift+h)" },
          { id: "code", icon: "󰅴", tip: "Inline code" },
          { id: "style", icon: "󰉿", tip: "Text style" },
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
          sourceComponent: modelData.id === "sep" ? sepComp : (modelData.id === "style" ? styleComp : buttonComp)
          readonly property bool tableOnly: ["addRow", "addCol", "delRow", "delCol"].indexOf(modelData.id) >= 0
          // The style menu stands for its rows: it stays as long as any of
          // them survives the provider's gate.
          readonly property bool allowed: modelData.id === "sep"
            || (modelData.id === "style" ? toolbar.styleMenuRows.length > 0
                                         : root.toolEnabled(tableOnly ? "table" : modelData.id))
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
      Component {
        id: styleComp
        Button {
          id: styleButton
          property string toolId: ""
          property bool hovering: false
          // Held open reads as held down: the outline stays while the menu is up.
          bordered: hovering || styleMenu.opened
          foreground: root.foreground
          accent: root.accent
          iconSize: Style.font.icon
          // A chevron after the glyph — this button opens a menu, the others act.
          text: "󰅀"
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.xxs
          onHovered: function(isHovered) { hovering = isHovered }
          onClicked: styleMenu.opened ? styleMenu.close() : styleMenu.open()
          // The toolbar can vanish under the menu (a provider switch, a
          // notice); the menu must not outlive it.
          onVisibleChanged: if (!visible) styleMenu.close()

          // The two candidate widest rows, measured at their menu size, so
          // every row takes the same width and the hover fill is not ragged.
          TextMetrics { id: widestHeading; text: "Heading 1"; font.family: root.fontFamily; font.bold: true; font.pixelSize: Math.round(Style.font.body * 2) }
          TextMetrics { id: widestNormal; text: "Normal text"; font.family: root.fontFamily; font.pixelSize: Style.font.body }

          QQC.Popup {
            id: styleMenu
            y: styleButton.height + Style.spacing.xxs
            readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
            readonly property real rowWidth: Math.ceil(Math.max(widestHeading.width, widestNormal.width)) + 2 * Style.spacing.controlPaddingX
            padding: Style.spacing.xxs
            leftPadding: Border.left(borderSpec) + Style.spacing.xxs
            rightPadding: Border.right(borderSpec) + Style.spacing.xxs
            topPadding: Border.top(borderSpec) + Style.spacing.xxs
            bottomPadding: Border.bottom(borderSpec) + Style.spacing.xxs
            background: BorderSurface {
              color: Color.popups.background
              borderSpec: styleMenu.borderSpec
              radius: Style.cornerRadius
            }
            contentItem: Column {
              spacing: Style.spacing.labelGap
              Repeater {
                model: toolbar.styleMenuRows
                delegate: Rectangle {
                  id: styleRow
                  required property var modelData
                  width: styleMenu.rowWidth
                  height: rowLabel.implicitHeight + Style.spacing.sm
                  radius: Style.cornerRadius
                  color: rowMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, root.accent) : "transparent"
                  Text {
                    id: rowLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    text: styleRow.modelData.label
                    color: rowMouse.containsMouse ? Style.hoverStateColor(Color.popups.text, root.accent) : Color.popups.text
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(Style.font.body * styleRow.modelData.scale)
                    font.bold: styleRow.modelData.bold
                  }
                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { styleMenu.close(); root.tool(styleRow.modelData.id) }
                  }
                }
              }
            }
          }
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

        // The code slabs, painted behind the editor so the text sits on
        // them; the bars above it live at the bottom of the TextEdit.
        Repeater {
          model: root.codeSlabs
          Rectangle {
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: modelData.width
            height: modelData.height
            radius: 6
            color: root.codeSlabColour
          }
        }

        TextEdit {
          id: area
          width: flick.width
          // Fill the frame so a click anywhere in the empty area focuses
          // the editor.
          height: Math.max(implicitHeight, flick.height)
          leftPadding: Style.spacing.xs
          rightPadding: Style.spacing.xs
          // Room for the code slab's vertical overhang (slabGeometry): a
          // block at either end of the note would otherwise push the slab's
          // rounded corners past the content edge, where the Flickable's
          // clip squares them off.
          topPadding: 8
          bottomPadding: 8
          readOnly: !root.hasNote || root.readOnly
          color: root.foreground
          selectionColor: Style.selectionFill
          selectedTextColor: root.foreground
          // Rich text in, rich text out. Markdown cannot hold a highlight,
          // an empty paragraph or an indent, so the document keeps HTML and
          // services/markdown converts at both ends.
          textFormat: root.plain ? TextEdit.PlainText : TextEdit.RichText
          // Relative image links (a local note's `.assets/…`) resolve
          // against the note's own folder; without one, the default.
          baseUrl: root.documentBase
                   ? "file://" + encodeURI(root.documentBase).replace(/#/g, "%23").replace(/\?/g, "%3F") + "/"
                   : Qt.resolvedUrl(".")
          font.family: root.bodyFontFamily
          font.pixelSize: Style.font.title
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            root.shortcut(event)
            if (event.accepted || root.plain) return
            if (event.key === Qt.Key_Right
                && !(event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier))
                && root.escapeCode()) { event.accepted = true; return }
            if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
            if (!(event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier))
                && root.returnLeavesBlock()) { event.accepted = true; return }
            root.beforeReturn()
          }
          onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
          onWidthChanged: root.scheduleDecorations()
          onImplicitHeightChanged: root.scheduleDecorations()
          onTextChanged: {
            if (root.normalizing) return
            root.normalizeNow()
            root.scheduleDecorations()
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
            anchors.topMargin: area.topPadding
            visible: area.length === 0 && !!root.placeholder
            text: root.placeholder
            color: root.foreground
            opacity: 0.45
            font.family: root.bodyFontFamily
            font.pixelSize: Style.font.title
            wrapMode: Text.Wrap
          }

          // The quote bars, drawn in the quotes' left margin — children of
          // the editor, so they scroll with it and share its coordinates.
          Repeater {
            model: root.quoteBars
            Rectangle {
              required property var modelData
              x: modelData.x
              y: modelData.y
              width: 4
              height: modelData.height
              color: root.quoteBarColour
            }
          }

          // The checkboxes, drawn over Qt's own ☐/☒ marker glyphs
          // (markerMetrics has the cell). Decoration only, and deliberately
          // without handlers: the click falls through to Qt's marker
          // underneath, which toggles the real state and comes back through
          // textChanged to repaint this.
          Repeater {
            model: root.checkBoxes
            Item {
              id: checkItem
              required property var modelData
              readonly property real glyphWidth: markerMetrics.advanceWidth(modelData.checked ? "☒" : "☐")
              readonly property int side: Math.round(markerMetrics.height)
              x: modelData.x - markerMetrics.advanceWidth(" ") - glyphWidth - 1
              y: modelData.y
              width: glyphWidth + 2
              height: Math.ceil(markerMetrics.height)

              Rectangle { anchors.fill: parent; color: root.background }

              Rectangle {
                id: face
                // Right edge on the glyph's own, not centred in the cell: a
                // face wider than the glyph would otherwise lean into the
                // one-space gap Qt lays before the text, and that gap is
                // the air that keeps the box off its words.
                x: parent.width - width - 1
                anchors.verticalCenter: parent.verticalCenter
                width: checkItem.side
                height: checkItem.side
                radius: Math.max(3, Math.round(checkItem.side * 0.3))
                color: checkItem.modelData.checked ? root.accent : "transparent"
                border.color: checkItem.modelData.checked ? root.accent
                            : Util.alpha(root.foreground, overBox.hovered ? 0.75 : 0.4)
                border.width: checkItem.modelData.checked ? 0 : Math.max(1.2, checkItem.side / 9)
                antialiasing: true

                // The tick: two round-capped arms meeting at the elbow, in
                // the surface colour so it reads as cut out of the accent.
                readonly property real arm: Math.max(1.5, checkItem.side * 0.16)
                Rectangle {
                  visible: checkItem.modelData.checked
                  x: face.width * 0.32 - width / 2
                  y: face.height * 0.625 - height / 2
                  width: face.width * 0.276 + face.arm
                  height: face.arm
                  radius: face.arm / 2
                  rotation: 45
                  antialiasing: true
                  color: root.background
                }
                Rectangle {
                  visible: checkItem.modelData.checked
                  x: face.width * 0.60 - width / 2
                  y: face.height * 0.52 - height / 2
                  width: face.width * 0.538 + face.arm
                  height: face.arm
                  radius: face.arm / 2
                  rotation: -48
                  antialiasing: true
                  color: root.background
                }
              }

              // The pointing hand over the box, where the TextEdit below
              // would show its I-beam; the handler grabs nothing, so the
              // click still falls through to Qt's marker.
              HoverHandler { id: overBox; cursorShape: Qt.PointingHandCursor }
            }
          }

          // The image resize handles: hovering an image reveals a marker on
          // its bottom-right corner; dragging it shows the target size as an
          // outline and applies the width on release (resizeImage). Children
          // of the editor for the same reason the bars are: they scroll with
          // it. Hover passes clicks through, so the caret still lands.
          Repeater {
            model: root.imageBoxes
            Item {
              id: imageBox
              required property var modelData
              x: modelData.x
              y: modelData.y
              width: modelData.width
              height: modelData.height
              property real targetWidth: modelData.width
              readonly property real targetHeight: imageBox.height * imageBox.targetWidth / Math.max(1, imageBox.width)

              HoverHandler { id: overImage }

              Rectangle {                        // the target size, while dragging
                visible: grip.pressed
                width: imageBox.targetWidth
                height: imageBox.targetHeight
                color: "transparent"
                border.color: root.accent
                border.width: 1
                radius: 2
              }

              Rectangle {                        // the marker itself
                x: (grip.pressed ? imageBox.targetWidth : imageBox.width) - width / 2
                y: (grip.pressed ? imageBox.targetHeight : imageBox.height) - height / 2
                width: 10
                height: 10
                radius: 2
                visible: overImage.hovered || grip.containsMouse || grip.pressed
                color: root.accent
                border.color: Util.alpha(root.foreground, 0.6)
                border.width: 1
              }

              MouseArea {
                id: grip
                // The grab area stays on the original corner for the whole
                // drag — a mouse grab follows the cursor anywhere — so the
                // mapping below never chases a moving target.
                x: imageBox.width - 10
                y: imageBox.height - 10
                width: 20
                height: 20
                hoverEnabled: true
                cursorShape: Qt.SizeFDiagCursor
                preventStealing: true
                onPositionChanged: function(mouse) {
                  if (!grip.pressed) return
                  var to = grip.mapToItem(imageBox, mouse.x, mouse.y).x
                  imageBox.targetWidth = Math.max(root.minImageWidth,
                    Math.min(to, area.width - imageBox.x - area.rightPadding))
                }
                onReleased: {
                  var w = Math.round(imageBox.targetWidth)
                  if (w !== Math.round(imageBox.width)) root.resizeImage(imageBox.modelData.position, w)
                  else imageBox.targetWidth = imageBox.width
                }
              }
            }
          }
        }
      }
  }

  // ---- there is more: the sidebar's thin track, on the note's own edge.
  // Outside the Column (whose layout would give it a row of its own) and
  // outside the Flickable (whose children scroll away with the content).
  Rectangle {
    id: editorTrack
    visible: flick.visible && flick.contentHeight > flick.height + 1
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.xs
    // The Column sits panelPadding in from the pane and flick.y is measured
    // inside it; their sum is the viewport's top in this Item's coordinates.
    y: Style.spacing.panelPadding + flick.y
    height: flick.height
    width: Style.space(3)
    color: "transparent"

    Rectangle {
      width: parent.width
      radius: width / 2
      height: Math.max(Style.space(24),
                       editorTrack.height * (flick.height / Math.max(1, flick.contentHeight)))
      y: (editorTrack.height - height)
         * Math.max(0, Math.min(1, flick.contentY / Math.max(1, flick.contentHeight - flick.height)))
      color: Util.alpha(root.foreground, flick.moving ? 0.45 : 0.2)
      Behavior on color { ColorAnimation { duration: 150 } }
    }
  }

  // Word count sits in the corner of the note's own surface.
  Text {
    id: counter
    visible: root.hasNote && !root.showingNotice
    textFormat: Text.PlainText
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    // Lined up with the sheet's own right edge, not tucked into the corner:
    // it reads as the last line of the page rather than a badge on it.
    anchors.rightMargin: parent.width - sheet.x - sheet.width
    anchors.bottomMargin: Style.spacing.panelPadding
    text: root.wordCount + (root.wordCount === 1 ? " word" : " words")
    color: Util.alpha(root.foreground, 0.35)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
