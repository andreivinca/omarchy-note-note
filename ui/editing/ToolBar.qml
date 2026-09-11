import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

Item {
  id: bar
  required property var registry
  property color background: Color.menu.background
  readonly property var editor: registry.editor
  readonly property bool panelOpen: registry.tools.some(function(tool) {
    return tool.panelOpen
  })
  height: visible ? strip.implicitHeight + Style.spacing.hairline : 0

  Component {
    id: submenuFactory
    ToolMenu {
      registry: bar.registry
      submenuComponent: submenuFactory
      maximumWidth: toolFlow.width
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.tint(bar.background, Util.alpha(bar.editor.foreground, 0.015))
  }

  Column {
    id: strip
    width: parent.width
    topPadding: Style.spacing.sm
    bottomPadding: Style.spacing.sm
    leftPadding: Style.spacing.panelPadding
    rightPadding: Style.spacing.panelPadding
    spacing: Style.spacing.sm

    Flow {
      id: toolFlow
      width: parent.width - parent.leftPadding - parent.rightPadding
      spacing: Style.spacing.sm
      Repeater {
        id: buttons
        // Keep controls alive when capabilities/caret context change. Hiding
        // a tool closes its popup normally and preserves hover lifetimes.
        model: bar.registry.topLevelTools
        delegate: Item {
          id: entry
          required property var modelData
          readonly property int visibleIndex: bar.registry.toolbarTools.indexOf(modelData)
          readonly property bool startsGroup: visibleIndex > 0
            && bar.registry.groupFor(bar.registry.toolbarTools[visibleIndex - 1].toolId)
               !== bar.registry.groupFor(modelData.toolId)
          visible: visibleIndex >= 0
          width: actionButton.width + (startsGroup ? Style.spacing.md + Style.spacing.sm : 0)
          height: actionButton.height

          Button {
            id: actionButton
            objectName: "editingTool-" + entry.modelData.toolId
            enabled: bar.editor.writable && (!entry.modelData.isMenu || menu.rows.length > 0)
            anchors.right: parent.right
            property bool hovering: false
            bordered: hovering || menu.opened || entry.modelData.panelOpen
            foreground: bar.editor.foreground
            accent: bar.editor.accent
            iconText: entry.modelData.icon
            // A tooltip must not cover an open tool panel or menu.
            tooltipText: bar.panelOpen || menu.opened ? "" : entry.modelData.tooltip
            iconSize: Style.font.icon
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xxs
            text: entry.modelData.isMenu ? entry.modelData.label + " 󰅀" : (entry.modelData.panelPopup ? "󰅀" : "")
            opacity: enabled ? 1 : 0.45
            fontSize: Style.font.caption
            onHovered: function(over) {
              hovering = over
            }
            onClicked: {
              if (entry.modelData.isMenu) {
                if (menu.opened) {
                  menu.close()
                } else {
                  menu.open()
                }
              } else if (entry.modelData.panelPopup && entry.modelData.panelOpen) {
                entry.modelData.cancelPanel()
              } else {
                bar.registry.execute(entry.modelData.toolId)
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
              registry: bar.registry
              tool: entry.modelData
              submenuComponent: submenuFactory
              maximumWidth: toolFlow.width
              x: Math.min(0, toolFlow.width - entry.x - actionButton.x - width)
              y: actionButton.height + Style.spacing.xxs
            }
          }
        }
      }
    }

    Repeater {
      model: bar.registry.tools
      delegate: Loader {
        required property var modelData
        width: strip.width - strip.leftPadding - strip.rightPadding
        // Panels keep their controls while closed. Closing from a control's
        // signal must not destroy that control while its handler is running.
        active: !!modelData.panel && !modelData.panelPopup
        visible: !modelData.panelPopup && modelData.panelOpen && bar.registry.canExecute(modelData)
        sourceComponent: modelData.panel
      }
    }
  }

  function popupX(id, popupWidth) {
    for (var i = 0; i < buttons.count; i++) {
      var button = buttons.itemAt(i)
      if (button && button.modelData.toolId === id) {
        return Math.max(0, Math.min(strip.x + toolFlow.x + button.x, bar.width - popupWidth))
      }
    }
    return Style.spacing.panelPadding
  }

  Repeater {
    model: bar.registry.tools
    delegate: Loader {
      required property var modelData
      active: !!modelData.panel && modelData.panelPopup
      sourceComponent: Component {
        Item {
          objectName: "editingPopupHolder-" + modelData.toolId
          QQC.Popup {
            id: popup
            readonly property var tool: modelData
            readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
            parent: bar
            objectName: "editingPopup-" + tool.toolId
            popupType: QQC.Popup.Item
            x: bar.popupX(tool.toolId, width)
            y: bar.height
            padding: Style.spacing.sm
            focus: true
            visible: tool.panelOpen && bar.registry.canExecute(tool)
            closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
            onClosed: {
              if (tool.panelOpen) {
                tool.cancelPanel()
              }
            }
            background: BorderSurface {
              color: Color.popups.background
              borderSpec: popup.borderSpec
              radius: Style.cornerRadius
            }
            contentItem: Loader {
              sourceComponent: popup.tool.panel
            }
          }
        }
      }
    }
  }

  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(bar.editor.foreground, 0.1)
  }
}
