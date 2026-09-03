import QtQuick
import qs.Commons
import qs.Ui

// A page of monospace text standing in for the workspace: a heading and a
// line under it saying what the text is, the text itself filling the rest,
// a way out in the top corner, and — when the page has something to do
// besides be read — one action at the foot beside the line it answers with.
//
// A page, not a dialog: it takes everything under the title bar rather than
// floating over a dimmed copy of it. That is what makes the bar above it
// still real — a notebook tab up there is a way out of here, and so are the
// corner's ✕ and Escape.
//
// Two things use it. The settings page edits note-note's own config as raw
// JSON, saved explicitly; there is deliberately no form of switches, because
// a future setting only ever needs a new key in the default file, never a new
// widget here. The key bindings page has only something to show, so it locks
// its text and drops the foot along with the action there was none for.
Item {
  id: root

  property bool opened: false
  property string title: ""
  // Under the heading: what the text below is — the file it came from, or a
  // word about where it applies. Empty leaves the line out entirely.
  property string subtitle: ""
  property string bodyText: ""
  // A page that only has something to show locks its text. The caret still
  // walks it and the mouse still selects from it — reading and copying are
  // not editing — but nothing typed lands.
  property bool readOnly: false
  // The foot's one action, named. Empty means the page has nothing to do but
  // be read, and the foot goes with it.
  property string actionText: ""
  property string actionTooltip: ""
  // The one line the page answers with — an error from the action, or its
  // confirmation. Which of the two decides the colour, so the same line never
  // has to be read twice to know whether it went well.
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
  signal actionRequested(string text)

  function showNotice(message, isError) {
    root.noticeText = message
    root.noticeIsError = isError === true
  }

  function handleKey(event) {
    if (!root.opened) {
      return false
    }
    if (event.key === Qt.Key_Escape) {
      root.closeRequested()
      return true
    }
    // Ctrl+S is the action's shortcut, so a page without an action has no
    // use for it — and swallowing it there would take the key from whatever
    // else might want it.
    if (root.actionText.length > 0
        && (event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
      root.actionRequested(bodyArea.text)
      return true
    }
    return false
  }

  // Loaded once per open, not live-bound: an action that rewrites the host's
  // copy would otherwise reformat the text under the cursor of someone who
  // has kept typing since.
  onOpenedChanged: if (root.opened) {
    root.noticeText = ""
    bodyArea.text = root.bodyText
    bodyArea.forceActiveFocus()
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
      tooltipText: root.readOnly ? "Back to your notes (esc)"
                                 : "Back to your notes (esc). Anything unsaved is left behind"
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
      text: root.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      id: subtitleText
      textFormat: Text.PlainText
      visible: root.subtitle.length > 0
      anchors.left: parent.left
      anchors.right: closeButton.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: titleText.bottom
      anchors.topMargin: Style.spacing.xxs
      text: root.subtitle
      color: Util.alpha(root.foreground, 0.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }

    // The text itself, on the page's own ground: no frame around it and no
    // wash under it. This is the page's content, not a field dropped onto
    // it — the heading and the line under it are edge enough, and the body
    // shares their left margin so the three line up down one edge.
    Flickable {
      id: bodyScroll
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: subtitleText.visible ? subtitleText.bottom : titleText.bottom
      anchors.topMargin: Style.spacing.md
      anchors.bottom: footer.top
      anchors.bottomMargin: footer.visible ? Style.spacing.md : 0
      clip: true
      contentWidth: width
      contentHeight: bodyArea.height
      boundsBehavior: Flickable.StopAtBounds

      ListWheel { flick: bodyScroll }

      function ensureVisible(r) {
        if (contentY >= r.y) {
          contentY = r.y
        } else if (contentY + height <= r.y + r.height) {
          contentY = r.y + r.height - height
        }
      }

      TextEdit {
        id: bodyArea
        width: bodyScroll.width
        height: Math.max(implicitHeight, bodyScroll.height)
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.Wrap
        selectByMouse: true
        readOnly: root.readOnly
        color: root.foreground
        selectionColor: Style.selectionFill
        selectedTextColor: root.foreground
        // Both pages are read down a column — JSON down its nesting, the key
        // bindings down their aligned keys — and a fixed pitch is what keeps
        // that column straight. The rest of the page keeps the host's
        // interface font.
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onCursorRectangleChanged: bodyScroll.ensureVisible(cursorRectangle)
        // The notice describes the text the action was last given. The moment
        // that text changes it describes nothing.
        onTextChanged: root.noticeText = ""
      }
    }

    // The page's foot: what it has to say on the left, the one thing left to
    // do on the right, on one line — the width is there, and stacking them
    // would make the body shorter for a line that is usually empty. A page
    // with nothing to do keeps neither, and gives the height back to the
    // text.
    Item {
      id: footer
      visible: root.actionText.length > 0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: visible ? Math.max(actionButton.height, noticeLine.height) : 0

      Text {
        id: noticeLine
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: actionButton.left
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
        id: actionButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.actionText
        tooltipText: root.actionTooltip
        bordered: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.actionRequested(bodyArea.text)
      }
    }
  }
}
