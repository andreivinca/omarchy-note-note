import QtQuick
import "app/hosts/standalone" as Native
import "app/providers/onenote" as OneNote
import "app/services/platform"

// Use the real OneNote queue and process ownership with a slow synthetic
// read and a delayed write. No account or network request is involved.
Native.Main {
  id: window
  property var workspaceUnderTest: null
  property var providerUnderTest: null
  property bool writeCompleted: false
  property bool closeRequested: false

  Component {
    id: providerComponent
    OneNote.Provider {
      function runProcess(runner, args, payload, callback) {
        var delay = args[0] === "update" ? "0.4" : "30"
        return runner.run({ command: ["python3", "-c", "import time; time.sleep(" + delay + "); print('{}')"] }, callback)
      }
    }
  }

  Connections {
    target: window.workspaceUnderTest
    function onReadyToClose() {
      if (!window.writeCompleted || !window.providerUnderTest.busy) {
        console.error("FAIL! close must drain the write while the slow read is still active")
        Qt.exit(1)
        return
      }
      console.error("<<<CLOSE_DONE>>>")
    }
  }

  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (!window.workspaceUnderTest) {
        window.workspaceUnderTest = window.contentItem.children.find(function(child) {
          return child.objectName === "workspace"
        })
      }
      var workspace = window.workspaceUnderTest
      if (!workspace || !workspace.providersLoaded || window.closeRequested) {
        return
      }
      if (!window.providerUnderTest) {
        var provider = providerComponent.createObject(workspace, {
          host: workspace, services: { requests: workspace.services.requests }
        })
        window.providerUnderTest = provider
        workspace.providers = workspace.providers.concat([provider])
        provider.rq.enqueue({ key: "slow-read", owner: provider, priority: 1 }, function(ctx) {
          provider.runScript(["list"], "", ctx)
        }, function() {})
        provider.rq.enqueue({ key: "accepted-write", owner: provider, flush: true }, function(ctx) {
          provider.runScript(["update"], "", ctx)
        }, function(result) {
          window.writeCompleted = !!result && !result.error
        })
        return
      }
      if (window.providerUnderTest.busy) {
        window.closeRequested = true
        if (Platform.env("NOTE_NOTE_TEST_WM_CLOSE") === "1") {
          console.error("<<<WM_CLOSE_READY>>>")
        } else {
          window.close()
        }
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    onTriggered: {
      console.error("FAIL! the window remained open waiting for a background read")
      Qt.exit(1)
    }
  }
}
