import QtQuick
import QtQml.Models
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

QQC.Menu {
  id: toolMenu
  required property var registry
  required property var tool
  required property Component submenuComponent
  required property real maximumWidth
  readonly property var rows: registry.menuTools(tool.toolId)
  readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
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
  leftPadding: Border.left(borderSpec) + Style.spacing.xxs
  rightPadding: Border.right(borderSpec) + Style.spacing.xxs
  topPadding: Border.top(borderSpec) + Style.spacing.xxs
  bottomPadding: Border.bottom(borderSpec) + Style.spacing.xxs
  onRowsChanged: close()

  background: BorderSurface {
    color: Color.popups.background
    borderSpec: toolMenu.borderSpec
    radius: Style.cornerRadius
  }
  contentItem: ListView {
    implicitHeight: contentHeight
    model: toolMenu.contentModel
    currentIndex: toolMenu.currentIndex
    spacing: Style.spacing.labelGap
    clip: true
    boundsBehavior: Flickable.StopAtBounds
  }
  delegate: ToolMenuItem {
    editor: toolMenu.registry.editor
  }

  Component {
    id: actionComponent
    ToolMenuItem {
      editor: toolMenu.registry.editor
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
