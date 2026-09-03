import QtQuick
import qs.Commons
import qs.Ui

// The settings page: a raw view of note-note's own config
// (~/.config/notenote/config.json), edited as JSON and saved explicitly.
// There is deliberately no form of switches here — a future setting only
// ever needs a new key in the default file, never a new widget in this one.
//
// A page, not a dialog: it stands in for the whole workspace under the title
// bar rather than floating over a dimmed copy of it. That is what makes the
// bar above it still real — a notebook tab up there is a way out of here,
// and so is Close.
Item {
  id: root

  property bool opened: false
  property string initialText: ""
  // Shown under the heading: which file the text below is. The page edits
  // one named thing on disk and should say which.
  property string configPath: ""
  // The one line the page has to answer with — a parse error from Save, or
  // its confirmation. Which of the two decides the colour, so the same line
  // never has to be read twice to know whether it went well.
  property string noticeText: ""
  property bool noticeIsError: false
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  // The page sits flush along the bottom of whatever hosts it, in the place
  // the view bar holds when there is a note to describe. In the overlay that
  // host is a rounded card whose border is painted under the content, so the
  // page's bottom corners must curve with it or they square it off.
  property real cornerRadius: 0

  signal closeRequested()
  signal saveRequested(string text)

  function showError(message) { root.noticeText = message; root.noticeIsError = true }
  function showSaved() { root.noticeText = "Saved."; root.noticeIsError = false }

  function handleKey(event) {
    if (!root.opened) {
      return false
    }
    if (event.key === Qt.Key_Escape) {
      root.closeRequested()
      return true
    }
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
      root.saveRequested(editArea.text)
      return true
    }
    return false
  }

  // Loaded once per open, not live-bound: a save rewrites the host's config
  // and would otherwise reformat the text under the cursor of someone who
  // has kept typing since.
  onOpenedChanged: if (root.opened) {
    root.noticeText = ""
    editArea.text = root.initialText
    editArea.forceActiveFocus()
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: root.background
    bottomLeftRadius: root.cornerRadius
    bottomRightRadius: root.cornerRadius
  }

  Item {
    anchors.fill: parent
    anchors.margins: Style.spacing.panelPadding

    // The way out, in the corner a way out is looked for. Borderless like
    // the bar's own menu button: quiet until reached for, when the kit lends
    // it a hover ring.
    Button {
      id: closeButton
      anchors.right: parent.right
      anchors.verticalCenter: titleText.verticalCenter
      iconText: "󰅖"
      tooltipText: "Back to your notes (esc). Anything unsaved is left behind"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      iconSize: Style.font.icon
      width: Style.spacing.controlHeight
      height: Style.spacing.controlHeight
      radius: Math.min(Style.cornerRadius, height / 4)
      onClicked: root.closeRequested()
    }

    Text {
      id: titleText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: closeButton.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      text: "Settings"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      id: pathText
      textFormat: Text.PlainText
      visible: root.configPath.length > 0
      anchors.left: parent.left
      anchors.right: closeButton.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: titleText.bottom
      anchors.topMargin: Style.spacing.xxs
      text: root.configPath
      color: Util.alpha(root.foreground, 0.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }

    // The text itself, on the page's own ground: no frame around it and no
    // wash under it. This is the page's content, not a field dropped onto
    // it — the heading and the path are edge enough, and the JSON shares
    // their left margin so the three line up down one edge.
    Flickable {
      id: editScroll
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: pathText.visible ? pathText.bottom : titleText.bottom
      anchors.topMargin: Style.spacing.md
      anchors.bottom: footer.top
      anchors.bottomMargin: Style.spacing.md
      clip: true
      contentWidth: width
      contentHeight: editArea.height
      boundsBehavior: Flickable.StopAtBounds

      ListWheel { flick: editScroll }

      function ensureVisible(r) {
        if (contentY >= r.y) {
          contentY = r.y
        } else if (contentY + height <= r.y + r.height) {
          contentY = r.y + r.height - height
        }
      }

      TextEdit {
        id: editArea
        width: editScroll.width
        height: Math.max(implicitHeight, editScroll.height)
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.Wrap
        selectByMouse: true
        color: root.foreground
        selectionColor: Style.selectionFill
        selectedTextColor: root.foreground
        // The config is JSON, and JSON is read down its nesting: a fixed
        // pitch is what lines the levels up. The rest of the page keeps
        // the host's interface font.
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onCursorRectangleChanged: editScroll.ensureVisible(cursorRectangle)
        // The notice describes the text that was last sent to Save. The
        // moment that text changes it describes nothing.
        onTextChanged: root.noticeText = ""
      }
    }

    // The page's foot: what it has to say on the left, the one thing left to
    // do on the right, on one line — the width is there, and stacking them
    // would make the field shorter for a line that is usually empty.
    Item {
      id: footer
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(saveButton.height, noticeLine.height)

      Text {
        id: noticeLine
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: saveButton.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        text: root.noticeText
        color: root.noticeIsError ? Color.urgent : Style.selectedStateColor(root.foreground, root.accent)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Button {
        id: saveButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Save"
        tooltipText: "Write this to the config file (ctrl+s). The page stays open"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.saveRequested(editArea.text)
      }
    }
  }
}
