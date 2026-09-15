import "../platform"
import "../processes"
import QtQuick

// The clipboard, for pasting into a note: its image, and its text for the
// plain paste.
//
// The native host reads QClipboard; the plugin reads through wl-paste.
// clipboard.py shares the staging and image scaling policy. Pasted files
// stay in the cache until the note is saved into its provider.
Item {
  id: root

  readonly property string dir: Platform.localPath(Qt.resolvedUrl(".")).replace(/\/$/, "")
  readonly property string script: dir + "/clipboard.py"
  readonly property string stagingDir: Platform.pasteDir

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

  // The clipboard's text, whatever flavour it is on offer in.  callback(string)
  // — "" when the clipboard holds no text at all.
  function takeText(callback) {
    run(["text"], function(result) { callback(result && result.text ? result.text : "") })
  }

  // The clipboard's HTML flavour, for the editor's own paste (see
  // clipboard.py, clipboard_html).  callback(string) — "" when none is on
  // offer, which sends the paste down Qt's own path.
  function takeHtml(callback) {
    run(["html"], function(result) { callback(result && result.html ? result.html : "") })
  }

  ProcessRunner { id: runner }

  function run(args, callback) {
    if (!Platform.backend.omarchy) {
      var result = Platform.backend.clipboard(args[0])
      if (args[0] === "image" && !result.error) {
        return runner.run({ command: ["python3", root.script, "image-stdin", root.stagingDir],
                            payload: JSON.stringify(result), timeoutMs: 60000 }, callback)
      }
      callback(result)
      return { cancel: function() {} }
    }
    return runner.run({ command: ["python3", root.script].concat(args), timeoutMs: 60000 }, callback)
  }
}
