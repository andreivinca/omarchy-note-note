import QtQuick
import "../processes"
import "../requests"

// One confirmed, ordered writer per destination; reads keep framed failures.
Item {
  id: store
  readonly property string lib: Qt.resolvedUrl("../../lib/").toString().replace(/^file:\/\//, "")
  signal failed(string message)
  ProcessRunner { id: runner }
  RequestQueue { id: writes; domain: "files" }

  function read(path, cap, callback) {
    return runner.run({ command: ["python3", store.lib + "readfile.py", "--json", path, String(cap)] }, callback)
  }

  function write(path, text, callback) {
    return writes.enqueue({ key: path, mode: "append", owner: store, flush: true }, function(ctx) {
      runner.run({ command: ["python3", store.lib + "fileio.py"],
                   payload: JSON.stringify({ path: path, text: text, parents: true }) }, ctx.done)
    }, function(result, info) {
      var answer = result || { error: "file write was cancelled" }
      if (callback) {
        callback(answer)
      } else if (answer.error) {
        store.failed(answer.error)
      }
    })
  }
}
