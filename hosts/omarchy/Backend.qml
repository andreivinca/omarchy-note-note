import QtQuick
import Quickshell
import "../../services/platform"
import "../../services/processes"
import "../../design" as Design
import qs.Commons as Shell

Item {
  id: backend
  readonly property bool omarchy: true
  readonly property Component processComponent: Component {
    ProcessBackend {}
  }
  function env(name) {
    return Quickshell.env(name)
  }
  function copyText(text) {
    clipboard.run({ command: ["wl-copy"], payload: text, raw: true }, function(result) {
      if (result.error) {
        console.warn("note-note: could not copy to the clipboard")
      }
    })
  }
  ProcessRunner {
    id: clipboard
  }
  function install() {
    Platform.backend = backend
    Design.Style.source = Shell.Style
    Design.Color.source = Shell.Color
  }
}
