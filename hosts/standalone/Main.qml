import QtQuick
import QtQuick.Controls
import NoteNote.Native
import "../.." as App

ApplicationWindow {
  id: window
  property bool closeAccepted: false
  title: "Note Note"
  width: 1120
  height: 760
  minimumWidth: 760
  minimumHeight: 480
  visible: true
  color: workspace.background
  palette.window: SystemTheme.colors.background
  palette.windowText: SystemTheme.colors.foreground
  palette.base: SystemTheme.colors.base
  palette.alternateBase: SystemTheme.colors.alternateBase
  palette.text: SystemTheme.colors.text
  palette.button: SystemTheme.colors.button
  palette.buttonText: SystemTheme.colors.buttonText
  palette.highlight: SystemTheme.colors.highlight
  palette.highlightedText: SystemTheme.colors.highlightedText
  palette.toolTipBase: SystemTheme.colors.toolTipBase
  palette.toolTipText: SystemTheme.colors.toolTipText
  palette.link: SystemTheme.colors.link
  palette.linkVisited: SystemTheme.colors.linkVisited
  palette.light: SystemTheme.colors.light
  palette.midlight: SystemTheme.colors.midlight
  palette.mid: SystemTheme.colors.mid
  palette.dark: SystemTheme.colors.dark
  palette.shadow: SystemTheme.colors.shadow
  palette.accent: SystemTheme.colors.accent
  palette.placeholderText: SystemTheme.colors.placeholderText
  palette.disabled.text: SystemTheme.colors.disabledText
  palette.disabled.buttonText: SystemTheme.colors.disabledButtonText
  palette.disabled.windowText: SystemTheme.colors.disabledWindowText

  Backend {
    id: backend
  }
  App.Workspace {
    id: workspace
    objectName: "workspace"
    anchors.fill: parent
    onDismissRequested: requestClose()
    onReadyToClose: {
      workspace.releaseProviders()
      window.closeAccepted = true
      window.close()
      Qt.callLater(function() {
        Qt.quit()
      })
    }
  }
  onClosing: function(event) {
    event.accepted = window.closeAccepted
    if (!event.accepted) {
      workspace.requestClose()
    }
  }
  Connections {
    target: Desktop
    function onActivationRequested() {
      if (window.visibility === Window.Minimized) {
        window.showNormal()
      } else {
        window.show()
      }
      window.raise()
      window.requestActivate()
    }
  }
  Component.onCompleted: {
    backend.install()
    workspace.initialize()
    workspace.open("{}")
  }
}
