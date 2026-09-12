import QtQuick
import qs.Commons

Item {
  id: root

  property color foreground: Color.menu.text
  property int titleSize: bodyFontSize * 2
  property int bodyFontSize: Style.font.title
  readonly property color fill: Util.alpha(root.foreground, 0.12)

  clip: true

  Column {
    width: parent.width
    spacing: Style.spacing.xxxl

    Rectangle {
      anchors.right: parent.right
      width: Math.min(Style.space(180), parent.width * 0.35)
      height: Style.font.bodySmall
      radius: Style.space(3)
      color: root.fill
    }

    Rectangle {
      id: title
      x: Style.spacing.xs
      width: Math.min(Style.space(420), Math.max(0, parent.width - x * 2) * 0.65)
      height: root.titleSize
      radius: Style.space(4)
      color: root.fill
    }

    Column {
      x: title.x
      width: title.width * 0.72
      topPadding: Style.spacing.lg
      spacing: Style.spacing.lg

      Rectangle {
        width: parent.width
        height: root.bodyFontSize
        radius: Style.space(3)
        color: root.fill
      }

      Rectangle {
        width: parent.width * 0.8
        height: root.bodyFontSize
        radius: Style.space(3)
        color: root.fill
      }
    }
  }

  SequentialAnimation on opacity {
    running: root.visible
    loops: Animation.Infinite

    NumberAnimation {
      from: 0.55
      to: 1
      duration: 900
      easing.type: Easing.InOutSine
    }

    NumberAnimation {
      from: 1
      to: 0.55
      duration: 900
      easing.type: Easing.InOutSine
    }
  }
}
