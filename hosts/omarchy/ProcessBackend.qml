import QtQuick
import Quickshell.Io as Io

Item {
  id: backend
  signal started()
  signal output(string chunk)
  signal exited(int code)
  signal failed(string message)
  property bool launched: false
  property bool stopping: false
  property bool streaming: false
  property bool streamFinished: false
  property bool processExited: false
  property int exitCode: 0
  property int maxOutputBytes: 0
  function start(command, environment, options) {
    streaming = options.streaming
    maxOutputBytes = options.maxOutputBytes
    process.command = command
    process.environment = environment
    process.stdout = streaming ? lines : collected
    process.stdinEnabled = true
    process.running = true
  }
  function write(text) {
    process.write(text)
  }
  function closeInput() {
    process.stdinEnabled = false
  }
  function stop() {
    stopping = true
    process.running = false
  }
  function complete() {
    if (!stopping && processExited && (streaming || streamFinished)) {
      exited(exitCode)
    }
  }
  Io.StdioCollector {
    id: collected
    waitForEnd: false
    onDataChanged: {
      if (data.byteLength > backend.maxOutputBytes && !backend.stopping) {
        backend.failed("the process output exceeded its byte limit")
      }
    }
    onStreamFinished: {
      if (!backend.stopping) {
        backend.output(text)
        backend.streamFinished = true
        backend.complete()
      }
    }
  }
  Io.SplitParser {
    id: lines
    onRead: function(line) {
      backend.output(line + "\n")
    }
  }
  Io.Process {
    id: process
    stderr: Io.SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        // Errors use framed stdout; never log provider payloads.
      }
    }
    onStarted: {
      backend.launched = true
      backend.started()
    }
    onExited: function(code) {
      backend.processExited = true
      backend.exitCode = code
      backend.complete()
    }
    onRunningChanged: {
      if (!running && !backend.launched && !backend.stopping) {
        backend.failed("could not start the process")
      }
    }
  }
}
