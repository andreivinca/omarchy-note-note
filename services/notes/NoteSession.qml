import QtQuick

// Owns document identity, load generations, drafts and save completion.
// UI, provider lookup and status presentation are injected, so transitions
// can be exercised with delayed providers without a desktop or account.
Item {
  id: session
  property var editor: null
  property var providerFor: null
  property var versionFor: null
  property var report: null

  property string currentPath: ""
  property bool loadingNote: false
  property bool loadFailed: false
  property bool dirty: false
  property bool locked: false
  property string loadingPath: ""
  property var loadHandle: null
  property string loadedVersion: ""
  property int noteLoadSeq: 0
  property var saveEpoch: ({})
  property var savesPending: ({})
  property var drafts: ({})
  property int saveRevision: 0
  readonly property bool busy: Object.keys(session.savesPending).length > 0
  readonly property string notDisplayable: "This note could not be displayed — it has not been changed"

  function cancelLoad() {
    var handle = session.loadHandle
    session.loadHandle = null
    if (handle) {
      handle.cancel()
    }
  }

  function selectPath(path) {
    if (session.locked || path === session.currentPath || (path && !session.providerFor(path))) {
      return
    }
    session.flushSave()
    session.currentPath = path
    session.load(false)
  }

  function reloadCurrent() {
    if (!session.locked && !session.dirty && !session.saveInFlight(session.currentPath)) {
      session.load(true)
    }
  }

  function load(reload) {
    var path = session.currentPath
    var generation = ++session.noteLoadSeq
    session.cancelLoad()
    session.loadingNote = true
    session.loadFailed = false
    session.loadingPath = path
    session.dirty = false
    // A note opens at its top (NoteEditor.showBody); a reload in place
    // keeps the caret and the scroll where the reader had them.
    var view = reload ? editor.viewState() : null
    editor.clearNotice()
    editor.readOnly = true
    editor.documentBase = ""
    if (!reload) {
      editor.setNote("", "")
    }
    if (!path) {
      session.loadingNote = false
      session.loadedVersion = ""
      return
    }
    // An accepted save can outlive selection. Returning to that note shows
    // its captured document, including a draft whose conversion/save failed.
    var draft = session.drafts[path]
    if (draft) {
      editor.restoreDocument(draft.document)
      session.noteReady(false)
      session.dirty = !!draft.error
      return
    }
    var provider = session.providerFor(path)
    if (!provider) {
      session.noteUnavailable("The notebook is not available")
      return
    }
    var handle = provider.load(path, function(result) {
      if (!session.ownsLoad(path, generation)) {
        return
      }
      session.loadHandle = null
      if (result.error) {
        session.noteUnavailable(provider.name + ": " + result.error)
        return
      }
      session.loadedVersion = result.version || session.versionFor(path)
      editor.documentBase = result.base || ""
      editor.setNote(result.title || "", result.body || "", function(shown) {
        if (!session.ownsLoad(path, generation)) {
          return
        }
        if (!shown) {
          session.noteUnavailable(session.notDisplayable)
          return
        }
        if (view) {
          editor.restoreViewState(view)
        }
        session.noteReady(result.editable === false)
        if (reload) {
          session.report(provider.name + ": reloaded, changed elsewhere")
        }
      })
    })
    // A synchronous provider may have finished before returning its handle.
    if (session.ownsLoad(path, generation) && session.loadingNote) {
      session.loadHandle = handle || null
    }
  }

  function ownsLoad(path, generation) {
    return session.currentPath === path && session.noteLoadSeq === generation
  }

  function noteReady(readOnly) {
    editor.readOnly = readOnly || session.locked
    session.loadFailed = false
    session.loadingNote = false
    session.loadingPath = ""
    session.dirty = false
  }

  function noteUnavailable(message) {
    editor.readOnly = true
    session.loadFailed = true
    session.loadingNote = false
    session.loadingPath = ""
    session.report(message)
  }

  function onEdited() {
    if (session.loadingNote || session.locked || !session.currentPath || editor.readOnly) {
      return
    }
    session.dirty = true
    var provider = session.providerFor(session.currentPath)
    if (provider && typeof provider.noteEdited === "function") {
      provider.noteEdited(session.currentPath)
    } else {
      schedule.path = session.currentPath
      schedule.restart()
    }
  }

  Timer {
    id: schedule
    property string path: ""
    interval: 1500
    onTriggered: {
      if (path === session.currentPath) {
        session.flushSave()
      }
    }
  }

  function saveInFlight(path) {
    return (session.savesPending[path] || 0) > 0
  }

  function countSave(path, delta) {
    var count = (session.savesPending[path] || 0) + delta
    var pending = Object.assign({}, session.savesPending)
    if (count > 0) {
      pending[path] = count
    } else {
      delete pending[path]
    }
    session.savesPending = pending
    session.saveRevision++
  }

  // Used only after the user confirms deleting this note.
  function cancelPendingSave(path) {
    if (path) {
      session.saveEpoch[path] = (session.saveEpoch[path] || 0) + 1
      delete session.drafts[path]
    }
  }

  function remove(path, callback) {
    if (session.locked) {
      callback({ error: "A note operation is still finishing" })
      return
    }
    var provider = session.providerFor(path)
    if (!provider) {
      callback({ error: "The notebook is not available" })
      return
    }
    var current = path === session.currentPath
    var recovery = current ? editor.snapshotDocument() : (session.drafts[path] || {}).document
    var unsaved = current ? session.dirty || session.saveInFlight(path) : !!session.drafts[path]
    var readOnly = editor.readOnly
    session.cancelPendingSave(path)
    session.locked = true
    editor.readOnly = true
    provider.remove(path, function(result) {
      if (result.error && recovery && unsaved) {
        session.drafts[path] = { document: recovery, error: result.error, epoch: session.saveEpoch[path] }
      }
      if (current) {
        session.dirty = !!result.error && unsaved
      }
      editor.readOnly = readOnly
      session.locked = false
      callback(result)
    })
  }

  function flushSave() {
    var path = session.currentPath
    if (!session.dirty || !path || editor.readOnly) {
      return
    }
    var provider = session.providerFor(path)
    if (!provider) {
      return
    }
    var epoch = (session.saveEpoch[path] || 0) + 1
    session.saveEpoch[path] = epoch
    var draft = { document: editor.snapshotDocument(), epoch: epoch, error: "" }
    session.drafts[path] = draft
    session.dirty = false
    session.loadedVersion = ""
    session.countSave(path, 1)
    editor.requestMarkdown(function(body, ok) {
      if (session.saveEpoch[path] !== epoch) {
        session.countSave(path, -1)
        return
      }
      if (!ok) {
        session.finishSave(path, draft, { error: "the note could not be read for saving" })
        return
      }
      provider.save(path, draft.document.title, body, function(result) {
        session.finishSave(path, draft, result || {})
      })
    })
  }

  function finishSave(path, draft, result) {
    if (session.drafts[path] === draft) {
      if (result.error) {
        draft.error = result.error
        if (path === session.currentPath) {
          session.dirty = true
        }
      } else {
        delete session.drafts[path]
        if (path === session.currentPath && !session.dirty && result.version) {
          session.loadedVersion = result.version
        }
      }
    }
    if (result.error || result.warning) {
      session.report(result.error || result.warning)
    }
    // Release last: observers checking whether retirement is safe see the
    // final draft/error state, never a gap before a failed draft is restored.
    session.countSave(path, -1)
  }

  function reconcile(exists, version) {
    if (session.locked || session.loadingNote || session.dirty || session.saveInFlight(session.currentPath)) {
      return
    }
    if (session.currentPath && !exists) {
      session.selectPath("")
    } else if (session.currentPath && version && session.loadedVersion && version !== session.loadedVersion) {
      session.reloadCurrent()
    } else if (version && !session.loadedVersion) {
      session.loadedVersion = version
    }
  }

  function failureFor(providerIds) {
    for (var path in session.drafts) {
      if (providerIds.indexOf(path.substring(0, path.indexOf(":"))) >= 0 && session.drafts[path].error) {
        return "A note has unsaved changes: " + session.drafts[path].error
      }
    }
    return ""
  }
}
