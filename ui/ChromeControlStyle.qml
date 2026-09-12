import QtQuick
import qs.Commons

// Theme-relative surface and sizing for chrome inputs.
QtObject {
  id: root
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  readonly property color surface: Qt.tint(background, Util.alpha(foreground, 0.07))
  readonly property color fill: Qt.tint(surface, Util.alpha(foreground, 0.08))
  readonly property color borderColor: Qt.tint(surface, Util.alpha(foreground, 0.18))
  readonly property color focusBorderColor: Qt.tint(surface, Util.alpha(foreground, 0.35))
  readonly property real borderWidth: 1
  readonly property real radius: Math.min(Style.cornerRadius, Style.space(6))
  readonly property real height: Style.space(26)
}
