import QtQuick
import QtQuick.Controls as QQC
import qs.Commons

QQC.MenuItem {
  id: row
  required property var editor
  property var tool: subMenu ? subMenu.tool : null
  objectName: tool ? "editingMenu-" + tool.toolId : ""
  text: tool ? tool.label : ""
  hoverEnabled: true
  implicitWidth: rowLabel.implicitWidth + leftPadding + rightPadding
  implicitHeight: rowLabel.implicitHeight + Style.spacing.sm
  leftPadding: Style.spacing.controlPaddingX
  rightPadding: Style.spacing.controlPaddingX + (subMenu ? arrow.implicitWidth + Style.spacing.md : 0)
  font.family: editor.noteFontFamily
  font.pixelSize: Math.round(editor.bodyFontSize * (tool ? tool.previewScale : 1))
  font.bold: tool ? tool.previewBold : false

  contentItem: Text {
    id: rowLabel
    text: row.text
    font: row.font
    color: row.highlighted ? Style.hoverStateColor(Color.popups.text, row.editor.accent) : Color.popups.text
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
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
