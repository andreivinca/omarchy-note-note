import QtQuick
import "settings.js" as Settings
import "../../ui/editing/ToolbarSettings.js" as ToolbarSettings

// Settings changes have three phases: validate, drain, commit. Providers stay
// alive until their accepted writes settle; a failed save keeps the old setup.
Item {
  id: lifecycle
  property var host: null
  property var session: null
  property var editor: null
  property var files: null
  property bool busy: false
  property var pending: null

  function apply(text, callback) {
    if (lifecycle.busy || session.locked || session.loadingNote) {
      callback({ error: "A note or settings operation is still finishing" })
      return
    }
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      callback({ error: "Invalid JSON: " + error.message })
      return
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      callback({ error: "The settings must be a JSON object" })
      return
    }
    var toolbarError = ToolbarSettings.validateConfig(parsed)
    if (toolbarError) {
      callback({ error: toolbarError })
      return
    }
    var merged = host.mergeConfigDefaults(parsed)
    var changes = Settings.plan(host.config, merged, Object.keys(host.providerUrls))
    for (var i = 0; i < changes.length; i++) {
      if (changes[i].replace && changes[i].enabled) {
        var component = Qt.createComponent(host.providerUrls[changes[i].id])
        if (component.status !== Component.Ready) {
          callback({ error: "The provider could not be loaded: " + component.errorString() })
          return
        }
      }
    }
    lifecycle.pending = { parsed: parsed, merged: merged, changes: changes,
                          callback: callback, readOnly: editor.readOnly }
    lifecycle.busy = true
    session.flushSave()
    session.locked = true
    editor.readOnly = true
    for (var j = 0; j < changes.length; j++) {
      var provider = host.providerById(changes[j].id)
      if (provider && changes[j].replace && typeof provider.watch === "function") {
        provider.watch(false)
      }
    }
    drain.start()
    lifecycle.tryCommit()
  }

  function tryCommit() {
    if (!lifecycle.pending || session.busy) {
      return
    }
    var changes = lifecycle.pending.changes
    for (var i = 0; i < changes.length; i++) {
      var provider = host.providerById(changes[i].id)
      if (changes[i].replace && provider && host.providerBusy(provider)) {
        return
      }
    }
    drain.stop()
    var error = session.failureFor(Object.keys(host.providerUrls))
    if (error) {
      lifecycle.finish({ error: error })
      return
    }
    files.write(host.configPath, JSON.stringify(lifecycle.pending.parsed, null, 2) + "\n", function(result) {
      if (result.error) {
        lifecycle.finish(result)
        return
      }
      lifecycle.commit()
    })
  }

  function commit() {
    var pending = lifecycle.pending
    host.providerState = host.providerSnapshot()
    host.config = pending.merged
    for (var i = 0; i < pending.changes.length; i++) {
      var change = pending.changes[i]
      var provider = host.providerById(change.id)
      if (change.replace) {
        if (provider) {
          // The note has already been saved and all accepted work drained.
          if (host.providerOf(session.currentPath) === provider) {
            session.locked = false
            session.selectPath("")
            session.locked = true
          }
          host.retireProvider(provider)
        }
        if (change.enabled) {
          provider = host.addProvider(host.providerUrls[change.id])
          if (provider) {
            provider.refresh()
          }
        }
      } else if (provider && change.presentation) {
        host.applyProviderSettings(provider)
        provider.rebuild()
      }
    }
    host.reorderProviders()
    host.rebuildRows()
    host.saveState()
    lifecycle.finish({ ok: true })
  }

  function finish(result) {
    var pending = lifecycle.pending
    lifecycle.pending = null
    session.locked = false
    if (session.currentPath) {
      editor.readOnly = pending.readOnly
    }
    lifecycle.busy = false
    if (host.opened) {
      for (var i = 0; i < host.providers.length; i++) {
        var provider = host.providers[i]
        if (typeof provider.watch === "function") {
          provider.watch(true)
        }
      }
    }
    pending.callback(result)
  }

  Timer { id: drain; interval: 50; repeat: true; onTriggered: lifecycle.tryCommit() }
}
