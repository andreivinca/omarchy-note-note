import QtQuick
import NoteNote.Native
import "app/hosts/standalone" as Native
import "app/services/platform"
import "app/design" as Design

// Exercise the production event loop without QtTest's nested wait loops.
Native.Main {
  id: window
  property var workspaceUnderTest: null

  function check(condition, message) {
    if (!condition) {
      throw new Error(message)
    }
  }
  Timer {
    id: startup
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      try {
        window.workspaceUnderTest = window.contentItem.children.find(function(child) {
          return child.objectName === "workspace"
        })
        var workspace = window.workspaceUnderTest
        window.check(!!workspace, "workspace must be mounted in the application window")
        if (!workspace.providersLoaded) {
          return
        }
        window.check(workspace.visible && workspace.width === window.width && workspace.height === window.height,
                     "workspace must fill the visible window")
        window.check(SystemTheme.source === "omarchy", "standalone must detect the Omarchy theme fixture")
        window.check(Design.Color.background.toString() === "#182736", "shared UI must use the system background")
        window.check(window.palette.window.toString() === "#182736", "native controls must use the system background")
        window.check(window.palette.accent.toString() === "#6090d0", "native controls must use the system accent")
        var hello = workspace.providerById("hello")
        window.check(!!hello, "portable external provider must load")
        hello.action("setup")
        startup.stop()
        finish.start()
      } catch (error) {
        console.error("FAIL!", error.message, error.stack)
        Qt.exit(1)
      }
    }
  }
  Timer {
    id: finish
    interval: 200
    onTriggered: {
      var screenshot = Platform.env("NOTE_NOTE_TEST_SCREENSHOT")
      if (screenshot) {
        window.workspaceUnderTest.grabToImage(function(result) {
          console.error("<<<SCREENSHOT>>>", result.saveToFile(screenshot))
          window.close()
        })
      } else {
        window.close()
      }
      console.error("<<<LAUNCH_DONE>>>")
    }
  }
}
