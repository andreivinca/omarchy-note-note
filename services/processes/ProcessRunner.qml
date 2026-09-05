import QtQuick
import Quickshell.Io

// One result and one cleanup for every process, including failed startup.
// Payloads travel over stdin; callbacks never receive unframed partial output.
Item {
  id: root

  property int active: 0

  function parse(text) {
    try {
      var result = JSON.parse(text)
      if (result && typeof result === "object" && !Array.isArray(result)) {
        return result
      }
    } catch (error) {
      // A malformed reply is an operation failure, never an empty document.
    }
    return { error: "the process returned an invalid reply" }
  }

  // options: command, environment, payload, timeoutMs, raw.
  // Returns an idempotent cancel handle. Cancellation settles before stopping.
  function run(options, callback) {
    var proc = processComponent.createObject(root, {
      command: options.command,
      environment: options.environment || ({}),
      callback: callback,
      payload: options.payload,
      raw: options.raw === true,
      timeoutMs: options.timeoutMs || 30000
    })
    if (!proc) {
      callback({ error: "could not create the process" })
      return { cancel: function() {} }
    }
    var handle = {
      cancel: function() {
        if (proc) {
          proc.finish({ error: "operation cancelled", cancelled: true })
        }
      }
    }
    proc.released.connect(function() { proc = null })
    root.active++
    proc.requested = true
    proc.stdinEnabled = options.payload !== undefined
    proc.running = true
    return handle
  }

  Component {
    id: processComponent
    Process {
      id: proc
      property var callback: null
      property var payload: undefined
      property bool outputFinished: false
      property bool exited: false
      property int exitCode: 0
      property bool requested: false
      property bool launched: false
      property bool finished: false
      property bool raw: false
      property string output: ""
      property int timeoutMs: 30000
      signal released()

      function finish(result) {
        if (proc.finished) {
          return
        }
        proc.finished = true
        var done = proc.callback
        proc.callback = null
        proc.running = false
        root.active--
        try {
          if (done) {
            done(result)
          }
        } finally {
          proc.released()
          Qt.callLater(function() { proc.destroy() })
        }
      }

      onStarted: {
        proc.launched = true
        if (proc.payload !== undefined) {
          proc.write(proc.payload)
          proc.payload = undefined
          proc.stdinEnabled = false
        }
      }
      stdout: StdioCollector {
        onStreamFinished: {
          proc.output = this.text
          proc.outputFinished = true
          proc.complete()
        }
      }
      onExited: function(code) {
        proc.exitCode = code
        proc.exited = true
        proc.complete()
      }
      function complete() {
        if (proc.finished || !proc.exited || !proc.outputFinished) {
          return
        }
        var result = proc.raw ? { text: proc.output } : root.parse(proc.output)
        if (proc.exitCode !== 0 && !result.error) {
          result = { error: "the process exited with code " + proc.exitCode }
        }
        proc.finish(result)
      }
      onRunningChanged: {
        if (!proc.running && !proc.launched && !proc.finished) {
          proc.finish({ error: "could not start the process" })
        }
      }
      property Timer deadline: Timer {
        interval: proc.timeoutMs
        running: proc.requested && !proc.finished
        onTriggered: proc.finish({ error: "operation timed out" })
      }
    }
  }
}
