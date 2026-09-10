import QtQuick
import "../../services/requests"

Item {
  id: test
  property var results: []
  property int phase: 0
  property int ticks: 0
  property int syncs: 0
  property int steps: 0
  property int serial: 0
  property int answers: 0
  property bool interactiveDone: false
  property bool holdSearch: false
  property bool failSearch: false
  property bool deferStep: false
  property var indexReply: null
  property var searchReply: null
  property var cleared: []
  property real resumeAt: 0

  function check(name, ok) { test.results.push({ name: name, ok: !!ok }) }
  function counts() {
    return { serial: ++test.serial, total: 1, indexed: 0, pending: 1, failed: 0, nextDelay: 0,
             sections: { s: { total: 1, indexed: 0, pending: 1, failed: 0 } } }
  }
  function backend(args, payload, callback) {
    if (args[0] === "search-sync") {
      test.syncs++
      callback({ status: test.counts() })
    } else if (args[0] === "search-step") {
      test.steps++
      if (test.deferStep) {
        callback({ status: test.counts(), deferred: true, retryAfter: 30 })
      } else {
        test.indexReply = callback
      }
      return { cancel: function() { callback({ error: "cancelled" }) } }
    } else if (args[0] === "search") {
      if (test.failSearch) {
        callback({ error: "unreadable cache" })
      } else if (test.holdSearch) {
        test.searchReply = callback
      } else {
        callback({ paths: ["onenote:p1"] })
      }
    } else if (args[0] === "clear-search") {
      test.cleared.push(args[1])
      callback({ ok: true })
    }
  }

  RequestQueue { id: lane; paused: true; concurrency: 3 }
  Component.onCompleted: {
    lane.queue.cooldownUntil = Date.now() + 60000
    lane.bump()
  }
  SearchCache {
    id: cache
    ready: true
    session: "session-a"
    inventoryReady: false
    pages: [{ id: "p1", sectionId: "s", modified: "1" }]
    queue: lane
    run: test.backend
  }

  Timer {
    interval: 10
    running: true
    repeat: true
    onTriggered: {
      test.ticks++
      if (test.phase === 0 && test.ticks >= 6) {
        test.check("startup waits for the inventory before reconciling persisted text", test.syncs === 0)
        cache.inventoryReady = true
        test.phase = 1
      } else if (test.phase === 1 && cache.initialized) {
        test.check("service cooldown does not start indexing", test.steps === 0)
        cache.search("needle", function(result) {
          test.answers++
          test.check("local search answers during a service cooldown", result.paths.length === 1)
        })
        test.check("search callback occurs exactly once", test.answers === 1)
        test.check("incomplete coverage is visible", cache.status(["s"]).indexOf("0 of 1") >= 0)
        test.check("incomplete inventory is visible even when known pages are indexed",
                   cache.status([]).indexOf("page list incomplete") >= 0)
        cache.inventoryComplete = true
        test.check("complete empty scope has no progress notice", cache.status([]) === "")
        lane.queue.cooldownUntil = 0
        lane.bump()
        lane.pump()
        test.phase = 2
      } else if (test.phase === 2 && test.indexReply) {
        test.check("two indexing jobs run while the window is hidden", lane.paused && test.steps === 2)
        test.check("indexing is not treated as a write to drain", lane.pendingFor(cache, true) === 0)
        lane.paused = false
        lane.enqueue({ key: "interactive", priority: 0, owner: test }, function(ctx) {
          test.interactiveDone = true
          ctx.done({ ok: true })
        }, function(result) {})
        test.phase = 3
      } else if (test.phase === 3 && test.interactiveDone) {
        test.check("indexing leaves an interactive slot", cache.indexing)
        cache.inventoryReady = false
        cache.session = "session-b"
        var done = test.indexReply
        test.indexReply = null
        done({ status: { serial: 9999, total: 1, indexed: 1, pending: 0, sections: {} } })
        test.check("old account response cannot install its coverage", !cache.state.total)
        test.check("account change clears only the old session", test.cleared.indexOf("session-a") >= 0)
        test.deferStep = true
        cache.inventoryReady = true
        test.phase = 4
      } else if (test.phase === 4 && cache.deferred) {
        test.resumeAt = cache.resumeAt
        cache.refresh()
        test.phase = 5
      } else if (test.phase === 5 && test.ticks > 160 && !cache.syncing) {
        test.check("refresh preserves the absolute budget resume time", cache.resumeAt === test.resumeAt)
        test.failSearch = true
        var notices = 0
        var notice = function() { notices++ }
        cache.changed.connect(notice)
        cache.search("failed", function(result) {
          test.check("failed cache search answers without matches", result.paths.length === 0)
        })
        cache.search("failed again", function(result) {})
        cache.changed.disconnect(notice)
        test.check("cache failures remain visible without a notification loop",
                   notices === 1 && cache.status(["s"]) === "Search cache unavailable")
        test.failSearch = false
        test.holdSearch = true
        cache.search("old account", function(result) {
          test.answers++
          test.check("late search cannot reveal the previous account", result.paths.length === 0)
        })
        cache.ready = false
        cache.session = ""
        test.searchReply({ paths: ["onenote:private-old-page"] })
        test.check("late search still answers exactly once", test.answers === 2)
        test.check("sign-out clears its cache", test.cleared.indexOf("session-b") >= 0)
        console.error("<<<RESULT>>>" + JSON.stringify(test.results) + "<<<END>>>")
        Qt.quit()
        test.phase = 6
      }
    }
  }
  Timer {
    interval: 8000
    running: true
    onTriggered: {
      test.check("controller completes without getting stuck (phase " + test.phase + ")", false)
      console.error("<<<RESULT>>>" + JSON.stringify(test.results) + "<<<END>>>")
      Qt.quit()
    }
  }
}
