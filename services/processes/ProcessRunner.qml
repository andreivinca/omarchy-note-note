import QtQuick

// Every request owns its task and settles exactly once.
Item {
  id: runner
  property int active: 0

  function run(options, callback) {
    var task = taskComponent.createObject(runner, options)
    if (!task) {
      Qt.callLater(function() {
        callback({ error: "could not create the process task" })
      })
      return { cancel: function() {} }
    }
    active++
    task.finished.connect(function(result) {
      var completed = task
      task = null
      runner.active--
      try {
        callback(result)
      } finally {
        completed.destroy()
      }
    })
    task.running = true
    return {
      cancel: function() {
        if (task) {
          task.cancel()
        }
      }
    }
  }
  Component {
    id: taskComponent
    ProcessTask {}
  }
}
