import QtQuick
import NoteNote.Native
import "../../services/platform"
import "../../design" as Design

Item {
  id: backend
  readonly property bool omarchy: false
  readonly property url textInspectorUrl: Qt.resolvedUrl("TextInspector.qml")
  readonly property Component processComponent: Component {
    NativeProcess {}
  }
  function env(name) {
    return Desktop.env(name)
  }
  function copyText(text) {
    Desktop.copyText(text)
  }
  function clipboard(format) {
    return Desktop.clipboard(format)
  }
  function install() {
    Design.Color.systemTheme = SystemTheme
    Platform.backend = backend
  }
}
