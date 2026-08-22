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
  function cursorPosition() { return area.cursorPosition }
  function setCursorPosition(pos) { area.cursorPosition = Math.max(0, Math.min(pos, area.length)) }
  function focusTitle() { titleField.forceActiveFocus() }

  readonly property int wordCount: {
    var t = area.getText(0, area.length).trim()
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
