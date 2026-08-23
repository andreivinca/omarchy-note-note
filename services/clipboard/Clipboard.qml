import Quickshell
import Quickshell.Io
import QtQuick

// The clipboard's image, for pasting a picture into a note.
//
// Wayland keeps the clipboard in the compositor, so the work happens in
// `clipboard.py` (wl-paste, bounded reads, a screenshot scaled down to
// something a backend will take). Pasted files are staged in the cache until
// the note is saved and the backend hands the image back as its own.
Item {
  id: root

  readonly property string dir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: dir + "/clipboard.py"
  readonly property string stagingDir: Quickshell.env("HOME") + "/.cache/omarchy/note-note-paste"

  // Does the clipboard hold a picture?  callback(true|false)
  // Cheap: it only asks the compositor what types are on offer.
  function hasImage(callback) {
    run(["types"], function(result) { callback(!!(result && result.image)) })
  }

  // The clipboard's image, written into the staging directory.
  //   callback({ path, mime, bytes }) on success, callback(null) otherwise —
  // "no image in the clipboard" is the ordinary case, not a failure to report.
  function takeImage(callback) {
    run(["image", root.stagingDir], function(result) { callback(result && result.path ? result : null) })
  }

  function run(args, callback) {
    var proc = reader.createObject(root, { command: ["python3", root.script].concat(args), callback: callback })
    proc.running = true
  }

  Component {
    id: reader
    Process {
      id: proc
      property var callback: null
      stdout: StdioCollector {
        onStreamFinished: {
          var done = proc.callback
          proc.callback = null
          var result = null
          try { result = JSON.parse(this.text) } catch (error) { result = null }
          if (done) done(result)
          Qt.callLater(function() { proc.destroy() })
        }
      }
      onExited: function(code) {
        if (proc.callback) { var done = proc.callback; proc.callback = null; done(null) }
      }
    }
  }
}
