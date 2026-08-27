import QtQuick
import qs.Commons
import qs.Ui

// The settings page: a raw view of note-note's own config
// (~/.config/notenote/config.json), edited as JSON and saved explicitly.
// There is deliberately no form of switches here — a future setting only
// ever needs a new key in the default file, never a new widget in this one.
Item {
  id: root

  property bool opened: false
  property string initialText: ""
  property string errorText: ""
  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Util.alpha(Color.background, 0.7)
  property color accent: Color.accent
  property string fontFamily: Style.fontFamily
  property int cornerRadius: Style.cornerRadius

  signal canceled()
  signal saveRequested(string text)

  function showError(message) { root.errorText = message }

  function handleKey(event) {
    if (!root.opened) return false
    if (event.key === Qt.Key_Escape) { root.canceled(); return true }
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) { root.saveRequested(editArea.text); return true }
    return false
  }

  // Loaded once per open, not live-bound: nothing else changes root.config
  // while this is up except our own Save, which closes the dialog anyway.
  onOpenedChanged: if (root.opened) {
    root.errorText = ""
    editArea.text = root.initialText
    editArea.forceActiveFocus()
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(64), Style.space(640))
      height: Math.min(parent.height - Style.space(64), Style.space(560))
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: root.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Text {
          id: titleText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          text: "Settings"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Flickable {
          id: editScroll
          anchors.top: titleText.bottom
          anchors.topMargin: Style.spacing.sm
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: errorLine.visible ? errorLine.top : buttonRow.top
          anchors.bottomMargin: Style.spacing.sm
          clip: true
          contentWidth: width
          contentHeight: editArea.height
          boundsBehavior: Flickable.StopAtBounds

          ListWheel { flick: editScroll }

          function ensureVisible(r) {
            if (contentY >= r.y) contentY = r.y
            else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
          }

          TextEdit {
            id: editArea
            width: editScroll.width
            height: Math.max(implicitHeight, editScroll.height)
            leftPadding: Style.spacing.xs
            rightPadding: Style.spacing.xs
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            color: root.foreground
            selectionColor: Style.selectionFill
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onCursorRectangleChanged: editScroll.ensureVisible(cursorRectangle)
          }
        }

        Text {
          id: errorLine
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: buttonRow.top
          anchors.bottomMargin: Style.spacing.sm
          visible: root.errorText.length > 0
          text: root.errorText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Row {
          id: buttonRow
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.spacing.sm

          Button {
            text: "Cancel"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.canceled()
          }
          Button {
            text: "Save"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.saveRequested(editArea.text)
          }
        }
      }
    }
  }
}
