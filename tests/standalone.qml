import QtQuick
import QtTest
import "app" as App
import "app/hosts/standalone" as Native
import "app/services/platform"
import "app/services/processes"

Window {
  id: testWindow
  visible: true
  width: 1120
  height: 760
  property bool closedSafely: false

  Native.Backend {
    id: backend
  }
  ProcessRunner {
    id: runner
  }
  App.Workspace {
    id: workspace
    anchors.fill: parent
    onReadyToClose: testWindow.closedSafely = true
  }
  Component.onCompleted: {
    backend.install()
    workspace.initialize()
    workspace.open("{}")
  }

  TestCase {
    id: checks
    name: "Standalone"
    when: false

    function typeText(text) {
      for (var i = 0; i < text.length; i++) {
        keyClick(text.charAt(i))
      }
    }

    function request(options) {
      var answer = null
      var calls = 0
      var handle = runner.run(options, function(result) {
        calls++
        answer = result
      })
      tryVerify(function() {
        return answer !== null
      }, 5000)
      handle.cancel()
      compare(calls, 1)
      return answer
    }

    function test_01_process_contract() {
      var text = "漢字 📝\n'quoted' $literal"
      var answer = request({ command: ["python3", "-c", "import json,sys,os; print(json.dumps({'text':sys.stdin.read(),'env':os.environ['TASK_VALUE']}))"],
                             payload: text, environment: { TASK_VALUE: "literal value" } })
      compare(answer.text, text)
      compare(answer.env, "literal value")
      answer = request({ command: ["/missing-note-note-command"] })
      verify(!!answer.error)
      answer = request({ command: ["python3", "-c", "print('x' * 4096)"], maxOutputBytes: 64 })
      verify(answer.error.indexOf("byte limit") >= 0)
      answer = request({ command: ["python3", "-c", "import time; time.sleep(20)"], timeoutMs: 30 })
      compare(answer.error, "operation timed out")
      answer = request({ command: ["python3", "-c", "import os,time; b='📝漢字'.encode(); [(os.write(1,bytes([v])),time.sleep(.001)) for v in b]"], raw: true })
      compare(answer.text, "📝漢字")
      var cancelled = null
      var handle = runner.run({ command: ["python3", "-c", "raise Exception('must not start')"] }, function(result) {
        cancelled = result
      })
      handle.cancel()
      verify(cancelled.cancelled)
      handle.cancel()
      compare(runner.active, 0)
    }

    function test_02_platform_paths_and_clipboard() {
      verify(!Platform.backend.omarchy)
      compare(Platform.stateDir, Platform.env("XDG_STATE_HOME") + "/notenote")
      compare(Platform.cacheDir, Platform.env("XDG_CACHE_HOME") + "/notenote")
      compare(workspace.configPath, Platform.env("XDG_CONFIG_HOME") + "/notenote/config.json")
      var configRead = request({ command: ["python3", Platform.env("NOTE_NOTE_TEST_ROOT") + "/lib/readfile.py", "--json", workspace.configPath, "1048576"] })
      verify(JSON.parse(configRead.text).providers.onenote.enabled === false)
      var text = "clipboard 📝\nsecond line"
      Platform.copyText(text)
      compare(Platform.backend.clipboard("text").text, text)
      var answer = request({ command: ["python3", "-c", "import os,json; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith('NOTE_NOTE_')}))"] })
      compare(answer.NOTE_NOTE_STATE_DIR, Platform.stateDir)
      compare(answer.NOTE_NOTE_PASTE_DIR, Platform.pasteDir)
    }

    function test_03_workspace_and_shutdown() {
      tryVerify(function() {
        return workspace.providersLoaded && workspace.rows.some(function(row) {
          return row.kind === "note"
        })
      }, 5000)
      verify(!workspace.supportsOverlay)
      compare(workspace.providers.length, 1)
      var provider = workspace.providerById("local")
      var path = provider.notes[0].path
      workspace.selectPath(path)
      tryVerify(function() {
        return workspace.currentPath === path && !workspace.loadingNote
      }, 5000)
      var editor = findChild(workspace, "noteEditor")
      verify(editor !== null)
      compare(editor.plainText().trim(), "Original body")
      verify(editor.canColorText, "the compiled text engine must be available")
      editor.focusEditor()
      editor.setCursorPosition(editor.plainText().length)
      keyClick(Qt.Key_End)
      typeText(" appended")
      tryVerify(function() {
        return workspace.dirty
      })
      workspace.flushSave()
      tryVerify(function() {
        return !workspace.dirty && !workspace.saveInFlight(path)
      }, 5000)
      var loaded = null
      provider.load(path, function(result) {
        loaded = result
      })
      tryVerify(function() {
        return loaded !== null
      }, 5000)
      verify(loaded.body.indexOf("appended") >= 0)

      // Make the destination unwritable after loading it. The real writer
      // must fail, and the close must preserve the in-memory draft.
      provider.watch(false)
      var file = provider.fileOf(path)
      var blocked = request({ command: ["python3", "-c",
        "import os,sys,json; p=sys.argv[1]; os.rename(p,p+'.held'); os.mkdir(p); print(json.dumps({'ok':True}))", file] })
      verify(blocked.ok)
      editor.focusEditor()
      typeText(" kept after failure")
      workspace.requestClose()
      verify(workspace.closing)
      verify(!testWindow.closedSafely)
      tryVerify(function() {
        return !workspace.closing
      }, 5000)
      verify(workspace.dirty)
      verify(workspace.opened)
      verify(editor.plainText().indexOf("kept after failure") >= 0)
      verify(!testWindow.closedSafely)
      var restored = request({ command: ["python3", "-c",
        "import os,sys,json; p=sys.argv[1]; os.rmdir(p); os.rename(p+'.held',p); print(json.dumps({'ok':True}))", file] })
      verify(restored.ok)
      workspace.requestClose()
      tryVerify(function() {
        return testWindow.closedSafely
      }, 5000)
      verify(!workspace.dirty)
      verify(!workspace.saveInFlight(path))
    }

  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      try {
        checks.test_01_process_contract()
        checks.test_02_platform_paths_and_clipboard()
        checks.test_03_workspace_and_shutdown()
        console.error("<<<STANDALONE_DONE>>>")
        Qt.quit()
      } catch (error) {
        console.error("FAIL!", error.message, error.stack)
        console.error("Workspace:", workspace.debugState(), workspace.configPath, JSON.stringify(workspace.config))
        console.error("Provider startup:", workspace.providersLoaded, workspace.pendingExternalDirs, workspace.configReady)
        Qt.exit(1)
      }
    }
  }
}
