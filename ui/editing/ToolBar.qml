import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import ".." as AppUi

Item {
  id: bar
  required property var registry
  property color background: Color.menu.background
  property bool toolsVisible: true
  readonly property real groupPadding: Style.spacing.xs
  // Buttons and dividers share the first row's center. Its height
  // includes both levels of padding and grows with the tallest control.
  readonly property real rowHeight: Math.max(Style.space(44),
    toolFlow.buttonHeight + 2 * (groupPadding + Style.spacing.sm))
  readonly property var editor: registry.editor
  readonly property bool panelOpen: registry.actions.some(function(tool) {
    return tool.panelOpen
  })
  height: visible ? Math.max(rowHeight, strip.implicitHeight) + Style.spacing.hairline : 0

  AppUi.ChromePopupStyle {
    id: chromePopupStyle
    background: bar.background
    foreground: bar.editor.foreground
  }

  Component {
    id: submenuFactory
    ToolMenu {
      registry: bar.registry
      submenuComponent: submenuFactory
      maximumWidth: toolFlow.width
      popupStyle: chromePopupStyle
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.tint(bar.background, Util.alpha(bar.editor.foreground, 0.07))
  }

  Column {
    id: strip
    width: parent.width
    padding: Style.spacing.sm
    topPadding: (bar.rowHeight - toolFlow.buttonHeight) / 2 - bar.groupPadding
    bottomPadding: topPadding
    spacing: padding

    Flow {
      id: toolFlow
      visible: bar.toolsVisible
      width: parent.width - parent.leftPadding - parent.rightPadding
      spacing: strip.padding
      // All groups share the tallest button's height, including text-only
      // dropdowns whose labels are shorter than the icon glyphs.
      readonly property real buttonHeight: {
        var tallest = Style.space(28)
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
          required property int index
          required property var modelData
          objectName: "editingToolGroup-" + modelData.id
          registry: bar.registry
          tools: modelData.tools
          toolbarFlow: toolFlow
          submenuComponent: submenuFactory
          popupStyle: chromePopupStyle
          buttonHeight: toolFlow.buttonHeight
          panelPadding: bar.groupPadding
          panelOpen: bar.panelOpen
          separatorVisible: index < bar.registry.toolbarGroups.length - 1
          alignRight: !separatorVisible && tools.length === 1 && tools[0].isMenu
          precedingWidth: {
            var used = 0
            for (var i = 0; i < toolFlow.children.length; i++) {
              var group = toolFlow.children[i]
              if (group.modelData && group.index < index && group.visible) {
                used += group.implicitWidth + toolFlow.spacing
              }
            }
            return used
          }
          color: "transparent"
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

  function menuContains(tool, id) {
    if (tool.toolId === id) {
      return true
    }
    if (!tool.isMenu) {
      return false
    }
    return bar.registry.menuTools(tool.toolId).some(function(child) {
      return bar.menuContains(child, id)
    })
  }

  function popupX(id, popupWidth) {
    for (var i = 0; i < groups.count; i++) {
      var group = groups.itemAt(i)
      var button = group ? group.buttonFor(id) : null
      if (!button && group) {
        for (var j = 0; j < group.tools.length; j++) {
          if (bar.menuContains(group.tools[j], id)) {
            button = group.buttonFor(group.tools[j].toolId)
            break
          }
        }
      }
      if (button) {
        var buttonX = button.mapToItem(bar, 0, 0).x
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
            parent: bar
            objectName: "editingPopup-" + tool.toolId
            popupType: QQC.Popup.Item
            x: bar.popupX(tool.toolId, width)
            y: bar.height
            padding: chromePopupStyle.padding + Border.left(chromePopupStyle.borderSpec)
            focus: true
            visible: tool.panelOpen && bar.registry.canExecute(tool)
            closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
            onClosed: {
              if (tool.panelOpen) {
                tool.cancelPanel()
              }
            }
            background: BorderSurface {
              color: chromePopupStyle.fill
              borderSpec: chromePopupStyle.borderSpec
              radius: chromePopupStyle.radius
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
