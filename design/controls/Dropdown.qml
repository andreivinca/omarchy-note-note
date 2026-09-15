import QtQuick
import QtQuick.Controls as Controls
import ".."

Controls.ComboBox {
  id: control
  property var options: []
  property string value: ""
  property string label: ""
  property bool showLabel: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  readonly property bool popupOpen: popup.opened
  signal changed(string value)
  model: options
  textRole: "label"
  valueRole: "value"
  currentIndex: indexOfValue(value)
  font.family: fontFamily
  font.pixelSize: Style.font.body
  palette.text: foreground
  palette.buttonText: foreground
  palette.highlight: accent
  onActivated: {
    value = String(currentValue)
    changed(value)
  }
  function open() {
    forceActiveFocus()
    popup.open()
  }
  function close() {
    popup.close()
  }
}
