import QtQuick
import qs.Commons
import qs.Ui
import ".." as AppUi

Rectangle {
  id: group
  required property var registry
  required property var tools
  required property Item toolbarFlow
  required property Component submenuComponent
  required property AppUi.ChromePopupStyle popupStyle
  required property real buttonHeight
  property bool panelOpen: false
  property bool alignRight: false
  property bool separatorVisible: true
  property real precedingWidth: 0
  readonly property var editor: registry.editor
  property real panelPadding: Style.spacing.xs
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
  width: Math.min(toolbarFlow.width, alignRight ? Math.max(implicitWidth, toolbarFlow.width - precedingWidth) : implicitWidth)
  height: implicitHeight
  radius: Math.min(Style.cornerRadius, Style.space(6))

  Rectangle {
    visible: group.separatorVisible
    anchors.right: parent.right
    y: group.panelPadding + (group.buttonHeight - height) / 2
    width: Style.spacing.hairline
    height: Style.space(18)
    color: Util.alpha(group.editor.foreground, 0.12)
  }

  Flow {
    id: toolsFlow
    x: group.alignRight ? group.width - width - group.panelPadding : group.panelPadding
    y: group.panelPadding
    width: Math.max(0, Math.min(group.buttonMetrics.width, group.width - group.panelPadding * 2))
    spacing: Style.spacing.xxs

    Repeater {
      id: buttons
      // Keep controls alive across capability/caret changes so hiding a
      // tool closes its popup without destroying the hovered control.
      model: group.tools
      delegate: Item {
        id: buttonSlot
        required property var modelData
        readonly property alias button: actionButton
        visible: group.registry.isVisible(modelData)
        implicitWidth: actionButton.implicitWidth
        implicitHeight: actionButton.implicitHeight
        width: actionButton.width
        height: group.buttonHeight

        Button {
          id: actionButton
          readonly property var modelData: buttonSlot.modelData
          readonly property bool labeledMenu: modelData.isMenu && modelData.toolbarLabelVisible
          objectName: "editingTool-" + modelData.toolId
          enabled: group.editor.writable && (!modelData.isMenu || menu.rows.length > 0)
          // Dropdowns and icon buttons share the same face geometry.
          anchors.verticalCenter: parent.verticalCenter
          anchors.alignWhenCentered: false
          height: group.buttonHeight
          width: Math.max(implicitWidth, height)
          radius: Math.max(0, group.radius - group.panelPadding)
          borderSpec: Border.none()
          // Labeled menus use the ordinary tool hover fill even at rest.
          background: labeledMenu ? Style.hoverFillFor(foreground, accent) : "transparent"
          active: menu.opened || modelData.panelOpen
          selected: modelData.checked
          foreground: Util.alpha(group.editor.foreground, 0.72)
          accent: group.editor.accent
          iconText: modelData.icon
          // A tooltip must not cover an open tool panel or menu.
          tooltipText: group.panelOpen || menu.opened ? "" : modelData.tooltip
          iconSize: Style.font.icon
          horizontalPadding: labeledMenu ? Style.space(12) : Style.spacing.sm
          verticalPadding: Style.spacing.xxs
          text: {
            if (labeledMenu) {
              return modelData.label + " 󰅀"
            }
            return modelData.isMenu || modelData.panelPopup ? "󰅀" : ""
          }
          opacity: enabled ? 1 : 0.45
          fontFamily: group.editor.fontFamily
          fontSize: Style.font.body
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
            popupStyle: group.popupStyle
            x: Math.min(0, group.toolbarFlow.width - group.x - toolsFlow.x - buttonSlot.x - actionButton.x - width)
            y: buttonSlot.height - actionButton.y + group.panelPadding + Style.spacing.xxs
          }
        }
      }
    }
  }

  function buttonFor(id) {
    for (var i = 0; i < buttons.count; i++) {
      var slot = buttons.itemAt(i)
      if (slot && slot.modelData.toolId === id) {
        return slot.button
      }
    }
    return null
  }
}
