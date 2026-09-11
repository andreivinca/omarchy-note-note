import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

Item {
  id: bar
  required property var registry
  property color background: Color.menu.background
  readonly property var editor: registry.editor
  readonly property bool panelOpen: registry.actions.some(function(tool) {
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
    padding: Style.spacing.sm
    spacing: padding

    Flow {
      id: toolFlow
      width: parent.width - parent.leftPadding - parent.rightPadding
      spacing: strip.padding
      // All groups share the tallest button's height, including text-only
      // dropdowns whose labels are shorter than the icon glyphs.
      readonly property real buttonHeight: {
        var tallest = 0
        for (var i = 0; i < children.length; i++) {
          var group = children[i]
          if (group.naturalButtonHeight) {
            tallest = Math.max(tallest, group.naturalButtonHeight)
          }
        }
        return tallest
      }
      Repeater {
        id: groups
        model: bar.registry.toolbarGroups
        delegate: ToolBarGroup {
          required property var modelData
          objectName: "editingToolGroup-" + modelData.id
          registry: bar.registry
          tools: modelData.tools
          toolbarFlow: toolFlow
          submenuComponent: submenuFactory
          buttonHeight: toolFlow.buttonHeight
          panelOpen: bar.panelOpen
          color: Qt.tint(bar.background, Util.alpha("#808080", 0.18))
        }
      }
    }

    Repeater {
      model: bar.registry.actions
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
    for (var i = 0; i < groups.count; i++) {
      var group = groups.itemAt(i)
      var button = group ? group.buttonFor(id) : null
      if (button) {
        var buttonX = strip.x + toolFlow.x + group.x + group.panelPadding + button.x
        return Math.max(0, Math.min(buttonX, bar.width - popupWidth))
      }
    }
    return strip.leftPadding
  }

  Repeater {
    model: bar.registry.actions
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
