import QtQuick
import "../.." as App

// Omarchy plugin entry point. All shell-call methods remain inherited from
// the shared workspace; only windows, theme and lifecycle belong to the host.
App.Workspace {
  id: plugin

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  readonly property string pluginId: manifest ? manifest.id : "io.github.andreivinca.note-note"

  supportsOverlay: true
  contentHost: windows.contentHost
  onDismissRequested: {
    if (shell && typeof shell.hide === "function") {
      shell.hide(pluginId);
    }
  }
  Component.onCompleted: {
    backend.install();
    initialize();
  }

  Backend {
    id: backend
  }

  Windows {
    id: windows

    workspace: plugin
  }
}
