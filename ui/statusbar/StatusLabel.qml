import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

QQC.Control {
  id: root
  property StatusStyle style: StatusStyle {}
  property alias text: label.text
  property alias color: label.color
  property alias elide: label.elide
  property string iconText: ""
  property url iconSource: ""
  property color iconColor: color
  property real iconSize: style.fontSize
  property real maximumTextWidth: Infinity
  clip: true

  implicitWidth: Math.ceil(implicitContentWidth) + leftPadding + rightPadding
  implicitHeight: Math.max(style.minimumHeight,
    Math.ceil(implicitContentHeight) + topPadding + bottomPadding)
  leftPadding: style.horizontalPadding
  rightPadding: style.horizontalPadding
  topPadding: style.verticalPadding + style.borderWidth
  bottomPadding: topPadding
  font.family: style.fontFamily
  font.pixelSize: style.fontSize

  // Padding belongs around the whole caption. Between its icon and text
  // there is only one gap, independent of the caption's outer padding.
  contentItem: RowLayout {
    spacing: root.style.iconSpacing

    Image {
      id: logo
      objectName: "statusLabelImage"
      visible: status === Image.Ready
      source: root.iconSource
      sourceSize.width: root.iconSize * 2
      sourceSize.height: root.iconSize * 2
      fillMode: Image.PreserveAspectFit
      smooth: true
      Layout.preferredWidth: root.iconSize
      Layout.preferredHeight: root.iconSize
      Layout.alignment: Qt.AlignVCenter
    }

    StatusIcon {
      objectName: "statusLabelIcon"
      visible: !logo.visible && root.iconText.length > 0
      style: root.style
      text: root.iconText
      color: root.iconColor
      fontSize: root.iconSize
      Layout.alignment: Qt.AlignVCenter
    }

    Text {
      id: label
      objectName: "statusLabelText"
      visible: text.length > 0
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.style.foreground
      font: root.font
      Layout.minimumWidth: 0
      Layout.maximumWidth: root.maximumTextWidth
      Layout.fillWidth: true
      Layout.fillHeight: true
    }
  }
}
