import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui

QQC.AbstractButton {
  id: root

  property StatusStyle style: StatusStyle {}
  property string iconText: ""
  property string tooltipText: ""
  property color foreground: style.foreground
  property color accent: style.accent
  property color backgroundColor: Util.alpha(foreground, 0.06)
  property real radius: style.radius
  property var borderSpec: Border.flat(Util.alpha(foreground, hovered || activeFocus ? 0.45 : 0.2), style.borderWidth)
  leftPadding: style.horizontalPadding + style.borderWidth
  rightPadding: leftPadding
  topPadding: style.verticalPadding + style.borderWidth
  bottomPadding: topPadding
  implicitWidth: Math.max(style.minimumButtonWidth, Math.ceil(implicitContentWidth) + leftPadding + rightPadding)
  implicitHeight: Math.max(style.controlHeight, Math.ceil(implicitContentHeight) + topPadding + bottomPadding)
  hoverEnabled: true
  focusPolicy: Qt.NoFocus
  Accessible.name: text || tooltipText

  background: BorderSurface {
    radius: root.radius
    borderSpec: root.borderSpec
    color: root.down ? Style.pressedFillFor(root.foreground, root.accent)
      : root.hovered ? Style.hoverFillFor(root.foreground, root.accent)
      : root.checked ? Style.selectedFillFor(root.foreground, root.accent)
      : root.backgroundColor
    Behavior on color {
      ColorAnimation {
        duration: 120
      }
    }
  }

  contentItem: RowLayout {
    spacing: root.style.iconSpacing

    StatusIcon {
      style: root.style
      visible: root.iconText.length > 0
      text: root.iconText
      color: root.foreground
      fontSize: root.style.iconSize
      Layout.alignment: Qt.AlignVCenter
      Layout.fillWidth: true
      Layout.fillHeight: true
    }

    Text {
      visible: root.text.length > 0
      text: root.text
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.style.fontFamily
      font.pixelSize: root.style.fontSize
      verticalAlignment: Text.AlignVCenter
      Layout.alignment: Qt.AlignVCenter
    }
  }

  QQC.ToolTip.visible: hovered && tooltipText.length > 0
  QQC.ToolTip.text: tooltipText
  QQC.ToolTip.delay: 400

  HoverHandler {
    cursorShape: Qt.PointingHandCursor
  }
}
