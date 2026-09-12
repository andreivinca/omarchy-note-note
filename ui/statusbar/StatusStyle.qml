import QtQuick
import qs.Commons

// Optional shared appearance for the generic controls. Custom controls do
// not need this type, and the layout host never reads it.
QtObject {
  id: root

  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  property real fontSize: Style.font.caption
  property real iconSize: Style.font.iconSmall
  property real iconSpacing: Style.spacing.xs
  property real horizontalPadding: 5
  property real verticalPadding: Style.space(2)
  property real borderWidth: 1
  property real radius: Math.min(Style.cornerRadius, Style.space(4))
  property real minimumHeight: Style.space(20)
  property real minimumButtonWidth: Style.space(24)
  readonly property real controlHeight: Math.max(minimumHeight,
    Math.ceil(metrics.height) + verticalPadding * 2 + borderWidth * 2)
  readonly property FontMetrics metrics: FontMetrics {
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }
}
