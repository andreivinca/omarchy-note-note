import QtQuick
import ".."

Rectangle {
  property var borderSpec: Border.none()
  property real padding: 0
  property real topPadding: padding
  property real rightPadding: padding
  property real bottomPadding: padding
  property real leftPadding: padding
  readonly property real contentTopInset: Border.top(borderSpec) + topPadding
  readonly property real contentRightInset: Border.right(borderSpec) + rightPadding
  readonly property real contentBottomInset: Border.bottom(borderSpec) + bottomPadding
  readonly property real contentLeftInset: Border.left(borderSpec) + leftPadding
  border.width: Border.left(borderSpec)
  border.color: borderSpec ? borderSpec.color : "transparent"
}
