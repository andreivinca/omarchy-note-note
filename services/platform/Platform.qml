pragma Singleton
import QtQuick

// The launcher installs its backend before initializing the workspace.
QtObject {
  property var backend: null
  readonly property url textInspectorUrl: !backend ? "" : backend.omarchy
    ? Qt.resolvedUrl("../../ui/NativeBlocks.qml") : backend.textInspectorUrl

  function env(name) {
    return backend ? backend.env(name) : ""
  }
  function directory(variable, fallback) {
    var value = env(variable)
    return value.charAt(0) === "/" ? value : env("HOME") + fallback
  }
  readonly property string configDir: directory("XDG_CONFIG_HOME", "/.config") + "/notenote"
  readonly property string stateDir: directory("XDG_STATE_HOME", "/.local/state") + (backend && backend.omarchy ? "/omarchy" : "/notenote")
  readonly property string cacheDir: directory("XDG_CACHE_HOME", "/.cache") + (backend && backend.omarchy ? "/omarchy" : "/notenote")
  readonly property string providersDir: directory("XDG_CONFIG_HOME", "/.config") + (backend && backend.omarchy ? "/omarchy/note-note/providers" : "/notenote/providers")
  readonly property string pasteDir: cacheDir + "/note-note-paste"
  readonly property var environment: ({
    NOTE_NOTE_STATE_DIR: stateDir,
    NOTE_NOTE_CACHE_DIR: cacheDir,
    NOTE_NOTE_PASTE_DIR: pasteDir,
    NOTE_NOTE_ACCOUNT_CONFIG: directory("XDG_CONFIG_HOME", "/.config") + (backend && backend.omarchy ? "/omarchy/note-note.json" : "/notenote/accounts.json")
  })
  function createProcess(parent) {
    if (!backend) {
      throw new Error("The application platform has not been initialized")
    }
    return backend.processComponent.createObject(parent)
  }
  function openUrl(url) {
    return Qt.openUrlExternally(url)
  }
  function copyText(text) {
    backend.copyText(text)
  }
  function localPath(url) {
    return decodeURIComponent(url.toString().replace(/^file:\/\//, ""))
  }
  function fileUrl(path) {
    return "file://" + path.split("/").map(encodeURIComponent).join("/")
  }
}
