import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: windows
  required property var workspace
  readonly property Item contentHost: workspace.detached ? floatingHost : cardHost
  // ── overlay ─────────────────────────────────────────────────────────
  PanelWindow {
    id: panel
    visible: windows.workspace.opened && !windows.workspace.detached
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-note-note"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: windows.workspace.scrim }
    MouseArea { anchors.fill: parent; onClicked: windows.workspace.dismiss() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Math.max(Style.space(900), Math.round(panel.width * 0.90)), panel.width - Style.gapsOut * 2)
      height: Math.min(Math.max(Style.space(600), Math.round(panel.height * 0.90)), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: windows.workspace.background
      borderSpec: Border.surfaceSpec("menu", "border", windows.workspace.borderColor, Math.max(1, Style.space(2)))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: cardHost
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
      }
    }
  }

  // ── detached window ─────────────────────────────────────────────────
  FloatingWindow {
    id: floating
    visible: windows.workspace.opened && windows.workspace.detached
    title: "Note Note"
    color: windows.workspace.background
    implicitWidth: Style.space(1120)
    implicitHeight: Style.space(760)
    minimumSize: Qt.size(Style.space(760), Style.space(480))
    onVisibleChanged: {
      if (!visible && windows.workspace.opened && windows.workspace.detached) {
        windows.workspace.dismiss()
      }
    }

    FocusScope {
      anchors.fill: parent
      focus: true
      Item {
        id: floatingHost
        anchors.fill: parent
      }
    }
  }
}
