import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import qs.Commons
import ".." as AppUi

QQC.MenuItem {
  id: row
  required property var editor
  required property real iconColumnWidth
  required property AppUi.ChromePopupStyle popupStyle
  property var tool: subMenu ? subMenu.tool : null
  objectName: tool ? "editingMenu-" + tool.toolId : ""
  text: tool ? tool.label : ""
  hoverEnabled: true
  implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
  implicitHeight: Math.max(popupStyle.rowHeight, contentItem.implicitHeight + topPadding + bottomPadding)
  topPadding: popupStyle.verticalPadding
  bottomPadding: topPadding
  leftPadding: popupStyle.horizontalPadding
  rightPadding: popupStyle.horizontalPadding + (subMenu ? arrow.implicitWidth + Style.spacing.controlGap : 0)
  // Retain relative heading previews at the same text scale as the chrome.
  font.family: editor.fontFamily
  font.pixelSize: Math.round(Style.font.body * (tool ? tool.previewScale : 1))
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
      textFormat: Text.PlainText
      font: row.font
      color: row.highlighted ? Style.hoverStateColor(row.popupStyle.foreground, row.editor.accent) : row.popupStyle.foreground
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }
  arrow: Text {
    x: row.width - width - row.popupStyle.horizontalPadding
    y: (row.height - height) / 2
    visible: !!row.subMenu
    text: "›"
    font.family: row.editor.fontFamily
    font.pixelSize: Style.font.body
    color: rowLabel.color
  }
  background: Rectangle {
    radius: row.popupStyle.rowRadius
    color: row.highlighted ? Style.hoverFillFor(row.popupStyle.foreground, row.editor.accent) : "transparent"
  }
}
