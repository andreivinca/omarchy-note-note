import QtQuick
import qs.Commons
import qs.Ui

// A sidebar footer action. Creation actions can collect a name in place,
// using the same row geometry and appearance as ordinary actions.
Item {
  id: root

  property string text: ""
  property string iconText: ""
  property bool editable: false
  property bool editing: false
  property string placeholderText: ""
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color iconColor: accent
  property string fontFamily: Style.font.menuFamily
  property real textInset: Style.spacing.md
  property real rowGap: Style.spacing.xs
  property real rowRadius: Math.min(Style.cornerRadius, Style.space(6))

  signal clicked()
  signal submitted(string name)

  implicitHeight: Style.spacing.controlHeight + rowGap

  function startEditing() {
    if (!root.editable) {
      return
    }
    root.editing = true
    nameField.text = ""
    nameField.forceActiveFocus()
  }

  onVisibleChanged: {
    if (!visible) {
      root.editing = false
    }
  }

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    x: Style.spacing.xxs
    width: parent.width - Style.spacing.xxs * 2
    height: parent.height - root.rowGap
    radius: root.rowRadius
    color: !root.editing && hover.hovered ? Style.hoverFill : "transparent"
    opacity: root.editing || hover.hovered ? 1 : 0.65

    HoverHandler { id: hover }

    Row {
      anchors.fill: parent
      anchors.leftMargin: root.textInset
      anchors.rightMargin: Style.spacing.sm
      spacing: Style.spacing.md

      Text {
        id: icon
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.icon + Style.space(2)
        text: root.iconText
        color: root.iconColor
        font.family: Style.fontFamily
        font.pixelSize: Style.font.iconSmall
        horizontalAlignment: Text.AlignHCenter
      }

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - icon.width - parent.spacing
        height: parent.height

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          visible: !root.editing
          textFormat: Text.PlainText
          text: root.text
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        TextField {
          id: nameField
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          visible: root.editing
          placeholderText: root.placeholderText
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          verticalPadding: Style.spacing.xxs
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.editing = false
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              var name = text.trim()
              root.editing = false
              if (name) {
                root.submitted(name)
              }
              event.accepted = true
            }
          }
          onActiveFocusChanged: {
            if (!activeFocus) {
              root.editing = false
            }
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      visible: !root.editing
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (root.editable) {
          root.startEditing()
        } else {
          root.clicked()
        }
      }
    }
  }
}
