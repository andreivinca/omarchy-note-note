import QtQuick
import QtQuick.Controls as Controls
import ".."

Controls.ToolTip {
  id: tip
  property color panelForeground: Color.foreground
  property color panelBackground: Color.background
  property color panelBorder: Util.alpha(Color.foreground, 0.25)
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  delay: 400
  background: Rectangle {
    color: tip.panelBackground
    border.color: tip.panelBorder
    radius: Style.cornerRadius
  }
  contentItem: Text {
    text: tip.text
    textFormat: Text.PlainText
    color: tip.panelForeground
    font.family: tip.fontFamily
    font.pixelSize: tip.fontSize
  }
}
