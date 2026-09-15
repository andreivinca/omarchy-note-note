import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import ".."

Controls.AbstractButton {
  id: button
  property string iconText: ""
  property string tooltipText: ""
  property bool selected: false
  property bool active: false
  property bool hasCursor: false
  property bool focusable: false
  property bool bordered: false
  property color foreground: Color.foreground
  property color backgroundColor: "transparent"
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property real iconSize: Style.font.icon
  property real iconRotation: 0
  property bool iconSpinning: false
  horizontalPadding: Style.spacing.controlPaddingX
  verticalPadding: Style.spacing.xs
  property bool leftAlign: false
  property real radius: Style.cornerRadius
  property var borderSpec: bordered || activeFocus ? Border.flat(Util.alpha(foreground, 0.4), 1) : Border.none()
  signal rightClicked()

  leftPadding: horizontalPadding + 1
  rightPadding: horizontalPadding + 1
  topPadding: verticalPadding + 1
  bottomPadding: verticalPadding + 1
  implicitWidth: implicitContentWidth + leftPadding + rightPadding
  implicitHeight: implicitContentHeight + topPadding + bottomPadding
  hoverEnabled: true
  focusPolicy: focusable ? Qt.StrongFocus : Qt.NoFocus
  Accessible.name: text || tooltipText
  opacity: enabled ? 1 : 0.5

  background: BorderSurface {
    radius: button.radius
    borderSpec: button.borderSpec
    color: button.down ? Style.pressedFillFor(button.foreground, button.accent)
      : button.hovered || button.hasCursor || button.activeFocus ? Style.hoverFillFor(button.foreground, button.accent)
      : button.selected || button.active ? Style.selectedFillFor(button.foreground, button.accent)
      : button.backgroundColor
  }
  contentItem: Item {
    implicitWidth: contentRow.implicitWidth
    implicitHeight: contentRow.implicitHeight

    RowLayout {
      id: contentRow
      x: button.leftAlign ? 0 : (parent.width - width) / 2
      anchors.verticalCenter: parent.verticalCenter
      anchors.alignWhenCentered: false
      spacing: Style.spacing.controlGap

      Text {
        visible: button.iconText.length > 0
        text: button.iconText
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.iconSize
        rotation: button.iconRotation
        Layout.alignment: Qt.AlignVCenter
        RotationAnimation on rotation {
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
          running: button.iconSpinning
        }
      }
      Text {
        visible: button.text.length > 0
        text: button.text
        textFormat: Text.PlainText
        color: button.selected ? Style.selectedStateColor(button.foreground, button.accent) : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
  Controls.ToolTip.visible: hovered && tooltipText.length > 0
  Controls.ToolTip.text: tooltipText
  Controls.ToolTip.delay: 400
  HoverHandler {
    cursorShape: Qt.PointingHandCursor
  }
  TapHandler {
    acceptedButtons: Qt.RightButton
    onTapped: button.rightClicked()
  }
}
