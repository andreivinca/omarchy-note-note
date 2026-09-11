import QtQuick
import qs.Commons
import qs.Ui

Rectangle {
  id: group
  required property var registry
  required property var tools
  required property Item toolbarFlow
  required property Component submenuComponent
  required property real buttonHeight
  property bool panelOpen: false
  readonly property var editor: registry.editor
  readonly property real panelPadding: Style.spacing.xxs
  readonly property real naturalButtonHeight: {
    var tallest = 0
    for (var i = 0; i < toolsFlow.children.length; i++) {
      tallest = Math.max(tallest, toolsFlow.children[i].implicitHeight)
    }
    return tallest
  }
  readonly property var buttonMetrics: {
    var count = 0
    var width = 0
    for (var i = 0; i < toolsFlow.children.length; i++) {
      var button = toolsFlow.children[i]
      if (!button.modelData) {
        continue
      }
      if (registry.isVisible(button.modelData)) {
        width += button.width
        count++
      }
    }
    return { count: count, width: width + Math.max(0, count - 1) * toolsFlow.spacing }
  }
  visible: buttonMetrics.count > 0
  implicitWidth: buttonMetrics.width + panelPadding * 2
  implicitHeight: toolsFlow.implicitHeight + panelPadding * 2
  width: Math.min(implicitWidth, toolbarFlow.width)
  height: implicitHeight
  radius: 4

  Flow {
    id: toolsFlow
    x: group.panelPadding
    y: group.panelPadding
    width: Math.max(0, group.width - group.panelPadding * 2)
    spacing: Style.spacing.xxs

    Repeater {
      id: buttons
      // Keep controls alive across capability/caret changes so hiding a
      // tool closes its popup without destroying the hovered control.
      model: group.tools
      delegate: Button {
        id: actionButton
        required property var modelData
        objectName: "editingTool-" + modelData.toolId
        visible: group.registry.isVisible(modelData)
        enabled: group.editor.writable && (!modelData.isMenu || menu.rows.length > 0)
        height: group.buttonHeight
        width: Math.max(implicitWidth, height)
        radius: Math.max(0, group.radius - group.panelPadding)
        borderSpec: Border.none()
        active: menu.opened || modelData.panelOpen
        foreground: group.editor.foreground
        accent: group.editor.accent
        iconText: modelData.icon
        // A tooltip must not cover an open tool panel or menu.
        tooltipText: group.panelOpen || menu.opened ? "" : modelData.tooltip
        iconSize: Style.font.icon
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        text: {
          if (modelData.isMenu && modelData.toolbarLabelVisible) {
            return modelData.label + " 󰅀"
          }
          return modelData.isMenu || modelData.panelPopup ? "󰅀" : ""
        }
        opacity: enabled ? 1 : 0.45
        fontSize: Style.font.caption
        onClicked: {
          if (modelData.isMenu) {
            if (menu.opened) {
              menu.close()
            } else {
              menu.open()
            }
          } else if (modelData.panelPopup && modelData.panelOpen) {
            modelData.cancelPanel()
          } else {
            group.registry.execute(modelData.toolId)
          }
        }
        onVisibleChanged: {
          if (!visible) {
            menu.close()
          }
        }
        Component.onDestruction: menu.close()

        ToolMenu {
          id: menu
          registry: group.registry
          tool: actionButton.modelData
          submenuComponent: group.submenuComponent
          maximumWidth: group.toolbarFlow.width
          x: Math.min(0, group.toolbarFlow.width - group.x - toolsFlow.x - actionButton.x - width)
          y: actionButton.height + group.panelPadding + Style.spacing.xxs
        }
      }
    }
  }

  function buttonFor(id) {
    for (var i = 0; i < buttons.count; i++) {
      var button = buttons.itemAt(i)
      if (button && button.modelData.toolId === id) {
        return button
      }
    }
    return null
  }
}
