import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import qs.Commons

QQC.MenuItem {
  id: row
  required property var editor
  required property real iconColumnWidth
  property var tool: subMenu ? subMenu.tool : null
  objectName: tool ? "editingMenu-" + tool.toolId : ""
  text: tool ? tool.label : ""
  hoverEnabled: true
  implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
  implicitHeight: contentItem.implicitHeight + topPadding + bottomPadding
  topPadding: Style.spacing.sm / 2
  bottomPadding: topPadding
  leftPadding: Style.spacing.controlPaddingX
  rightPadding: Style.spacing.controlPaddingX + (subMenu ? arrow.implicitWidth + Style.spacing.md : 0)
  font.family: editor.noteFontFamily
  font.pixelSize: Math.round(editor.bodyFontSize * (tool ? tool.previewScale : 1))
  font.bold: tool ? tool.previewBold : false

  contentItem: RowLayout {
    spacing: Style.spacing.controlGap

    Text {
      text: row.tool ? row.tool.icon : ""
      textFormat: Text.PlainText
      visible: row.iconColumnWidth > 0
      Layout.preferredWidth: row.iconColumnWidth
      Layout.alignment: Qt.AlignVCenter
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
      color: rowLabel.color
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      id: rowLabel
      Layout.fillWidth: true
      text: row.text
      font: row.font
      color: row.highlighted ? Style.hoverStateColor(Color.popups.text, row.editor.accent) : Color.popups.text
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }
  arrow: Text {
    x: row.width - width - Style.spacing.controlPaddingX
    y: (row.height - height) / 2
    visible: !!row.subMenu
    text: "›"
    font: row.font
    color: rowLabel.color
  }
  background: Rectangle {
    radius: Style.cornerRadius
    color: row.highlighted ? Style.hoverFillFor(Color.popups.text, row.editor.accent) : "transparent"
  }
}
