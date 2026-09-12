import QtQuick
import qs.Commons

// Shared by application menus, editing menus and their popup panels.
QtObject {
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  readonly property color fill: Qt.tint(background, Util.alpha(foreground, 0.07))
  readonly property var borderSpec: Border.flat(Qt.tint(fill, Util.alpha(foreground, 0.18)), 1)
  readonly property real radius: Math.min(Style.cornerRadius, Style.space(6))
  readonly property real padding: Style.spacing.xs
  readonly property real rowRadius: Math.max(0, radius - padding)
  readonly property real rowHeight: Style.spacing.popupRowHeight
  readonly property real horizontalPadding: Style.spacing.controlPaddingX
  readonly property real verticalPadding: Style.spacing.sm
}
