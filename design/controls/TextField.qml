import QtQuick
import QtQuick.Controls as Controls
import ".."

Controls.TextField {
  id: field
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool password: false
  property bool hasCursor: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.sm
  color: foreground
  selectionColor: Util.alpha(accent, 0.35)
  selectedTextColor: foreground
  placeholderTextColor: Util.alpha(foreground, 0.5)
  echoMode: password ? TextInput.Password : TextInput.Normal
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  leftPadding: horizontalPadding + 1
  rightPadding: leftPadding
  topPadding: verticalPadding + 1
  bottomPadding: topPadding
  background: Rectangle {
    radius: Style.cornerRadius
    color: Util.alpha(field.foreground, 0.04)
    border.width: 1
    border.color: field.activeFocus ? field.accent : Util.alpha(field.foreground, 0.3)
  }
}
