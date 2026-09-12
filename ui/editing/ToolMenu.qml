import QtQuick
import QtQml.Models
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import ".." as AppUi

QQC.Menu {
  id: toolMenu
  required property var registry
  required property var tool
  required property Component submenuComponent
  required property real maximumWidth
  required property AppUi.ChromePopupStyle popupStyle
  readonly property var rows: registry.menuTools(tool.toolId)
  readonly property real iconColumnWidth: {
    var widest = 0
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].icon) {
        widest = Math.max(widest, Style.font.icon, iconMetrics.advanceWidth(rows[i].icon))
      }
    }
    return widest
  }
  objectName: "editingPopup-" + tool.toolId
  title: tool.label
  cascade: true
  popupType: QQC.Popup.Item
  overlap: 0
  margins: Style.spacing.xxs
  implicitWidth: {
    var widest = 0
    for (var i = 0; i < count; i++) {
      var row = itemAt(i)
      if (row) {
        widest = Math.max(widest, row.implicitWidth)
      }
    }
    return Math.ceil(widest) + leftPadding + rightPadding
  }
  width: Math.min(implicitWidth, Math.max(0, maximumWidth))
  implicitHeight: contentItem.implicitHeight + topPadding + bottomPadding
  leftPadding: Border.left(popupStyle.borderSpec) + popupStyle.padding
  rightPadding: Border.right(popupStyle.borderSpec) + popupStyle.padding
  topPadding: Border.top(popupStyle.borderSpec) + popupStyle.padding
  bottomPadding: Border.bottom(popupStyle.borderSpec) + popupStyle.padding
  onRowsChanged: close()

  FontMetrics {
    id: iconMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.icon
  }

  background: BorderSurface {
    color: toolMenu.popupStyle.fill
    borderSpec: toolMenu.popupStyle.borderSpec
    radius: toolMenu.popupStyle.radius
  }
  contentItem: ListView {
    implicitHeight: contentHeight
    model: toolMenu.contentModel
    currentIndex: toolMenu.currentIndex
    spacing: 0
    clip: true
    boundsBehavior: Flickable.StopAtBounds
  }
  delegate: ToolMenuItem {
    editor: toolMenu.registry.editor
    iconColumnWidth: toolMenu.iconColumnWidth
    popupStyle: toolMenu.popupStyle
  }

  Component {
    id: actionComponent
    ToolMenuItem {
      editor: toolMenu.registry.editor
      iconColumnWidth: toolMenu.iconColumnWidth
      popupStyle: toolMenu.popupStyle
      onTriggered: {
        toolMenu.dismiss()
        toolMenu.registry.execute(tool.toolId)
      }
    }
  }
  Instantiator {
    model: toolMenu.rows
    // A shared factory creates each level with the same menu styling.
    // Visual actions belong to the content item; submenu holders own trees.
    delegate: QtObject {
      id: holder
      required property var modelData
      readonly property QtObject entry: modelData.isMenu
        ? toolMenu.submenuComponent.createObject(holder, { tool: modelData })
        : actionComponent.createObject(toolMenu.contentItem, { tool: modelData })
    }
    onObjectAdded: function(index, object) {
      if (object.modelData.isMenu) {
        toolMenu.insertMenu(index, object.entry)
      } else {
        toolMenu.insertItem(index, object.entry)
      }
    }
    onObjectRemoved: function(index, object) {
      if (object.modelData.isMenu) {
        toolMenu.removeMenu(object.entry)
      } else {
        toolMenu.removeItem(object.entry)
        object.entry.destroy()
      }
    }
  }
  Connections {
    target: toolMenu.registry.editor
    function onNoteTokenChanged() {
      toolMenu.close()
    }
    function onWritableChanged() {
      if (!toolMenu.registry.editor.writable) {
        toolMenu.close()
      }
    }
  }
  Connections {
    target: toolMenu.registry
    function onLayoutChanged() {
      toolMenu.close()
    }
  }
}
