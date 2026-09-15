import QtQuick
import ".."

FocusScope {
  id: dialog
  property bool opened: false
  property string message: ""
  property string confirmText: "Confirm"
  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.family
  property real cornerRadius: Style.cornerRadius
  property int selectedIndex: 0
  signal canceled()
  signal confirmed()
  visible: opened
  function handleKey(event) {
    if (!opened) {
      return false
    }
    if (event.key === Qt.Key_Escape) {
      canceled()
      return true
    }
    if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Tab, Qt.Key_Backtab].indexOf(event.key) >= 0) {
      selectedIndex = 1 - selectedIndex
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (selectedIndex === 0) {
        canceled()
      } else {
        confirmed()
      }
      return true
    }
    return false
  }
  onOpenedChanged: {
    if (opened) {
      selectedIndex = 0
    }
  }
  Rectangle {
    anchors.fill: parent
    color: dialog.scrim
    MouseArea {
      anchors.fill: parent
      onClicked: dialog.canceled()
    }
    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - 32, 400)
      height: contents.implicitHeight + 40
      color: dialog.background
      radius: dialog.cornerRadius
      border.color: Util.alpha(dialog.foreground, 0.3)
      MouseArea {
        anchors.fill: parent
      }
      Column {
        id: contents
        anchors.centerIn: parent
        width: parent.width - 40
        spacing: 20
        Text {
          width: parent.width
          text: dialog.message
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: dialog.foreground
          font.family: dialog.fontFamily
          font.pixelSize: Style.font.title
        }
        Row {
          anchors.right: parent.right
          spacing: 12
          Button {
            text: "Cancel"
            selected: dialog.selectedIndex === 0
            onClicked: dialog.canceled()
          }
          Button {
            text: dialog.confirmText
            foreground: Color.urgent
            selected: dialog.selectedIndex === 1
            onClicked: dialog.confirmed()
          }
        }
      }
    }
  }
}
