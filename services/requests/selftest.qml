import QtQuick
import "scheduler.js" as Scheduler

// The scenarios behind `services/requests/selftest.py`. Run it, not this.
//
// Two halves, for the two things there are to get wrong. The **scheduler**
// half calls scheduler.js directly with the clock as an argument, so a
// sixty-second park costs nothing and every case is exact. The **queue** half
// drives a real `RequestQueue` with real timers and short waits, which is the
// only way to check the property that actually matters: every enqueue is
// answered exactly once, whatever happens to it.
Item {
  id: harness

  property var results: []
  function check(name, ok, detail) {
    harness.results.push({ name: name, ok: ok === true, detail: detail === undefined ? "" : ("" + detail) })
  }

  Component {
    id: timerComponent
    Timer {
      id: shot
      property var action: null
      repeat: false
      onTriggered: {
        var run = shot.action
        shot.action = null
        if (run) {
          run()
        }
        Qt.callLater(function() { shot.destroy() })
      }
    }
  }
  function delay(ms, action) {
    timerComponent.createObject(harness, { interval: ms, action: action }).start()
  }

  // ── the scheduler, on a clock we hold ───────────────────────────────
  function schedulerCases() {
    var s, a, b, c, decided, opts = { concurrency: 3 }

    // Per-key FIFO, and only per key.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "p", label: "a" }).job
    b = Scheduler.enqueue(s, { key: "p", label: "b" }).job
    c = Scheduler.enqueue(s, { key: "q", label: "c" }).job
    harness.check("fifo: the older job of a key goes first",
                  Scheduler.nextRunnable(s, 1000, opts) === a)
    Scheduler.markRunning(s, a, 1000)
    harness.check("fifo: another key runs beside it",
                  Scheduler.nextRunnable(s, 1000, opts) === c)
    Scheduler.markRunning(s, c, 1000)
    harness.check("fifo: the key's second job waits for the first",
                  Scheduler.nextRunnable(s, 1000, opts) === null)
    Scheduler.onResult(s, a, {}, 1000)
    harness.check("fifo: and runs once the first is answered",
                  Scheduler.nextRunnable(s, 1000, opts) === b)

    // Priority: across keys yes, inside one key never.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "k", priority: 1, label: "k1" }).job
    b = Scheduler.enqueue(s, { key: "k", priority: 0, label: "k2" }).job
    c = Scheduler.enqueue(s, { key: "o", priority: 0, label: "o" }).job
    harness.check("priority: interactive work overtakes background", Scheduler.nextRunnable(s, 0, opts) === c)
    Scheduler.markRunning(s, c, 0)
    harness.check("priority: but a key is never reordered by it", Scheduler.nextRunnable(s, 0, opts) === a)

    // A background job never takes the lane's last slot.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "bg", priority: 1 }).job
    b = Scheduler.enqueue(s, { key: "fg", priority: 0 }).job
    Scheduler.markRunning(s, b, 0)
    harness.check("background leaves the last slot alone",
                  Scheduler.nextRunnable(s, 0, { concurrency: 2 }) === null)
    harness.check("background runs when there is room",
                  Scheduler.nextRunnable(s, 0, { concurrency: 3 }) === a)

    // Ties round-robin by owner, so one busy provider cannot starve another.
    s = Scheduler.makeState()
    var mine = { name: "mine" }, yours = { name: "yours" }
    a = Scheduler.enqueue(s, { key: "a1", owner: mine }).job
    b = Scheduler.enqueue(s, { key: "a2", owner: mine }).job
    c = Scheduler.enqueue(s, { key: "b1", owner: yours }).job
    var one = Scheduler.nextRunnable(s, 0, { concurrency: 1 })
    Scheduler.markRunning(s, one, 0)
    Scheduler.onResult(s, one, {}, 0)
    var two = Scheduler.nextRunnable(s, 0, { concurrency: 1 })
    harness.check("owners take turns", one === a && two === c, one.key + " then " + two.key)
    // Fairness is by owner, not by arrival: an owner that has never had the
    // lane goes ahead of an older job from one that just had it. This is what
    // stops a provider mid-listing from starving the one beside it.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "old", owner: mine }).job
    Scheduler.markRunning(s, a, 0)
    Scheduler.onResult(s, a, {}, 0)
    b = Scheduler.enqueue(s, { key: "older", owner: mine }).job
    c = Scheduler.enqueue(s, { key: "newer", owner: yours }).job
    harness.check("an idle owner goes first, however new its job",
                  Scheduler.nextRunnable(s, 0, { concurrency: 1 }) === c)

    // replace and dedupe.
    s = Scheduler.makeState()
    var first = Scheduler.enqueue(s, { key: "page:1", mode: "replace", settled: function() {} })
    var second = Scheduler.enqueue(s, { key: "page:1", mode: "replace", settled: function() {} })
    harness.check("replace supersedes the queued job", second.superseded === first.job)
    harness.check("replace leaves exactly one queued", s.jobs.length === 1 && s.jobs[0] === second.job)
    var third = Scheduler.enqueue(s, { key: "page:1", mode: "dedupe", settled: function() {} })
    harness.check("dedupe queues nothing new", third.job === null && third.joined === second.job)
    harness.check("dedupe joins its caller to the job", second.job.settled.length === 2)

    // A throttle parks the whole lane, and the job keeps its place.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "t" }).job
    b = Scheduler.enqueue(s, { key: "u" }).job
    Scheduler.markRunning(s, a, 1000)
    decided = Scheduler.onResult(s, a, { kind: "throttled", retryAfter: 30 }, 1000)
    harness.check("throttled parks the lane", decided.action === "park" && decided.at === 31000, decided.at)
    harness.check("parked: nothing runs at all", Scheduler.nextRunnable(s, 1000, opts) === null)
    harness.check("parked: the job waits at the head", s.jobs[0] === a)
    harness.check("parked: it runs again when the park is over",
                  Scheduler.nextRunnable(s, 31000, opts) === a)
    harness.check("parked: cooling and the countdown are readable",
                  Scheduler.cooling(s, 1000) === true && Scheduler.remaining(s, 1000) === 30)

    // No Retry-After (which is the usual OneNote 429): a growing backoff.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "t" }).job
    Scheduler.markRunning(s, a, 0)
    harness.check("no retryAfter: first park is 10s", Scheduler.onResult(s, a, { kind: "throttled" }, 0).at === 10000)
    Scheduler.markRunning(s, a, 10000)
    harness.check("no retryAfter: then 20s", Scheduler.onResult(s, a, { kind: "throttled" }, 10000).at === 30000)
    Scheduler.markRunning(s, a, 30000)
    harness.check("no retryAfter: then 40s", Scheduler.onResult(s, a, { kind: "throttled" }, 30000).at === 70000)

    // A transient failure is the job's own, and gives up after three tries.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "x" }).job
    b = Scheduler.enqueue(s, { key: "y" }).job
    Scheduler.markRunning(s, a, 0)
    decided = Scheduler.onResult(s, a, { kind: "transient" }, 0)
    harness.check("transient waits for this job only", decided.action === "retryAt" && decided.at === 2500, decided.at)
    harness.check("transient does not park the lane", Scheduler.nextRunnable(s, 0, opts) === b)
    Scheduler.markRunning(s, a, 2500)
    harness.check("transient backs off further", Scheduler.onResult(s, a, { kind: "transient" }, 2500).at === 7500)
    Scheduler.markRunning(s, a, 7500)
    harness.check("transient gives up and delivers",
                  Scheduler.onResult(s, a, { kind: "transient" }, 7500).action === "deliver")

    // A legacy {error} answer is delivered as it always was.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "e" }).job
    Scheduler.markRunning(s, a, 0)
    harness.check("an ordinary error is delivered",
                  Scheduler.onResult(s, a, { error: "no" }, 0).action === "deliver")

    // Hiding the window.
    s = Scheduler.makeState()
    a = Scheduler.enqueue(s, { key: "r" }).job
    b = Scheduler.enqueue(s, { key: "w", flush: true }).job
    var dropped = Scheduler.setPaused(s, true)
    harness.check("paused drops the reads", dropped.length === 1 && dropped[0] === a)
    harness.check("paused keeps the writes", s.jobs.length === 1 && s.jobs[0] === b)
    harness.check("paused still dispatches a write", Scheduler.nextRunnable(s, 0, opts) === b)
    Scheduler.markRunning(s, b, 0)
    Scheduler.onResult(s, b, { kind: "throttled", retryAfter: 5 }, 0)
    harness.check("a parked write waits for the cooldown too", Scheduler.nextRunnable(s, 0, opts) === null)

    // A provider going away.
    s = Scheduler.makeState()
    var owner = { name: "provider" }
    a = Scheduler.enqueue(s, { key: "m", owner: owner }).job
    b = Scheduler.enqueue(s, { key: "n", owner: {} }).job
    Scheduler.markRunning(s, a, 0)
    c = Scheduler.enqueue(s, { key: "m2", owner: owner }).job
    dropped = Scheduler.cancelOwner(s, owner)
    harness.check("cancelOwner drops what has not started", dropped.length === 1 && dropped[0] === c)
    harness.check("cancelOwner lets the in-flight job finish", s.running.length === 1 && s.running[0] === a)
    harness.check("cancelOwner leaves other owners alone", s.jobs.length === 1 && s.jobs[0] === b)

    harness.check("depth counts queued and running", Scheduler.depth(s) === 2, Scheduler.depth(s))
  }

  // ── the queue itself, with real timers ──────────────────────────────
  RequestQueue { id: lane; domain: "selftest"; concurrency: 3 }
  RequestQueue { id: single; domain: "selftest-one"; concurrency: 1 }
  RequestQueue { id: lonely; domain: "selftest-cancel"; concurrency: 1 }

  property var scenarios: [orderAndOnce, replaceThroughTheQueue, dedupeThroughTheQueue,
                           throttleThroughTheQueue, hidingTheWindow, badCallbacks, cancelThroughTheQueue]
  property int at: -1
  function next() {
    harness.at++
    if (harness.at >= harness.scenarios.length) {
      harness.report()
      return
    }
    harness.scenarios[harness.at]()
  }

  // One key runs strictly in order, and every enqueue is answered once.
  function orderAndOnce() {
    var log = []
    function job(name, ms) {
      lane.enqueue({ key: "k", label: name },
        function(ctx) { log.push("start:" + name); harness.delay(ms, function() { ctx.done({ ok: name }) }) },
        function(result, info) { log.push("settled:" + name + ":" + (result ? result.ok : "?")) })
    }
    job("one", 40)
    job("two", 5)
    harness.delay(200, function() {
      harness.check("one key runs strictly in order",
                    log.join(",") === "start:one,settled:one:one,start:two,settled:two:two", log.join(","))
      // A job that answers twice, and one whose start throws: both answered once.
      var answers = 0, thrown = 0
      lane.enqueue({ key: "twice" }, function(ctx) { ctx.done({ a: 1 }); ctx.done({ a: 2 }) },
                   function() { answers++ })
      lane.enqueue({ key: "throws" }, function(ctx) { thrown++; throw new Error("start blew up") },
                   function(result) { harness.check("a start that throws is still answered",
                                                    result && ("" + result.error).indexOf("blew up") >= 0, result && result.error) })
      harness.delay(120, function() {
        harness.check("done() twice answers once", answers === 1, answers)
        harness.check("a start that throws runs once", thrown === 1, thrown)
        harness.next()
      })
    })
  }

  function replaceThroughTheQueue() {
    var answers = []
    function save(name, ms) {
      return lane.enqueue({ key: "page:7", mode: "replace", label: name, flush: true },
        function(ctx) { harness.delay(ms, function() { ctx.done({ ok: name }) }) },
        function(result, info) {
          answers.push(name + ":" + (info.superseded ? "superseded" : (result ? result.ok : "?")))
        })
    }
    save("first", 40)
    harness.delay(10, function() {
      save("second", 5)          // queues behind the one in flight
      save("third", 5)           // and supersedes it before it ever starts
      harness.delay(200, function() {
        harness.check("replace: everyone is answered exactly once", answers.length === 3, answers.join(","))
        harness.check("replace: the in-flight job is not preempted — it delivers its own result",
                      answers.indexOf("first:first") >= 0, answers.join(","))
        harness.check("replace: the queued job is superseded",
                      answers.indexOf("second:superseded") >= 0, answers.join(","))
        harness.check("replace: the newest one runs",
                      answers.indexOf("third:third") >= 0, answers.join(","))
        harness.next()
      })
    })
  }

  function dedupeThroughTheQueue() {
    var started = 0, answered = 0
    for (var i = 0; i < 3; i++) {
      lane.enqueue({ key: "list", mode: "dedupe", priority: 1 },
        function(ctx) { started++; harness.delay(10, function() { ctx.done({ ok: true }) }) },
        function() { answered++ })
    }
    harness.delay(150, function() {
      harness.check("dedupe: the work runs once", started === 1, started)
      harness.check("dedupe: every caller is answered", answered === 3, answered)
      harness.next()
    })
  }

  function throttleThroughTheQueue() {
    var tries = 0, sawCooling = false
    lane.enqueue({ key: "throttling" },
      function(ctx) {
        tries++
        var answer = tries === 1 ? { kind: "throttled", retryAfter: 0.3 } : { ok: true }
        harness.delay(5, function() { ctx.done(answer) })
      },
      function(result, info) {
        harness.check("throttled: the job re-runs after the park",
                      tries === 2 && result && result.ok === true, "tries=" + tries)
        harness.check("throttled: the retries are counted", info.attempts === 2, info.attempts)
        harness.check("throttled: the lane reported it was cooling", sawCooling === true)
        harness.check("throttled: and stops once it is over", lane.cooling === false)
        harness.next()
      })
    harness.delay(80, function() { sawCooling = lane.cooling && lane.cooldownRemaining > 0 })
  }

  function hidingTheWindow() {
    var readInfo = null, wrote = false
    // A slow job on a one-at-a-time lane, so the two behind it are still
    // queued when the window hides.
    single.enqueue({ key: "blocker" }, function(ctx) { harness.delay(150, function() { ctx.done({}) }) },
                   function() {})
    single.enqueue({ key: "read", priority: 1 }, function(ctx) { ctx.done({}) },
                   function(result, info) { readInfo = info })
    single.enqueue({ key: "write", flush: true }, function(ctx) { wrote = true; ctx.done({}) },
                   function() {})
    harness.delay(20, function() { single.paused = true })
    harness.delay(320, function() {
      harness.check("hidden: a queued read is cancelled, not dropped silently",
                    readInfo !== null && readInfo.cancelled === true, JSON.stringify(readInfo))
      harness.check("hidden: a queued write still drains", wrote === true)
      single.paused = false
      harness.next()
    })
  }

  function badCallbacks() {
    var after = false
    lane.enqueue({ key: "boom" }, function(ctx) { ctx.done({}) },
                 function() { throw new Error("settled blew up") })
    lane.enqueue({ key: "after" }, function(ctx) { ctx.done({}) },
                 function() { after = true })
    harness.delay(150, function() {
      harness.check("a throwing callback does not wedge the lane", after === true)
      harness.check("and the lane is empty again", lane.depth === 0, lane.depth)
      harness.next()
    })
  }

  function cancelThroughTheQueue() {
    // A lane of its own. On a lane that has already dispatched for someone
    // else, the round-robin would rightly hand the free slot to this
    // scenario's never-seen owner instead of to the blocker in front of it —
    // fairness across owners, which the scheduler cases pin separately.
    var owner = { name: "going away" }
    var info = null, ran = false
    lonely.enqueue({ key: "hold" }, function(ctx) { harness.delay(120, function() { ctx.done({}) }) },
                   function() {})
    lonely.enqueue({ key: "doomed", owner: owner }, function(ctx) { ran = true; ctx.done({}) },
                   function(result, i) { info = i })
    harness.delay(20, function() { lonely.cancelOwner(owner) })
    harness.delay(250, function() {
      harness.check("cancelOwner answers the queued job as cancelled",
                    info !== null && info.cancelled === true, JSON.stringify(info))
      harness.check("cancelOwner: its work never started", ran === false)
      // A handle cancels its own enqueue.
      var handle = lonely.enqueue({ key: "byhand" }, function(ctx) { ctx.done({}) },
                                  function(result, i) { info = i })
      handle.cancel()
      harness.delay(120, function() {
        harness.check("a handle cancels its own job", info !== null && info.cancelled === true)
        harness.next()
      })
    })
  }

  function report() {
    console.error("<<<RESULT>>>" + JSON.stringify(harness.results) + "<<<END>>>")
    Qt.exit(0)
  }

  Component.onCompleted: {
    harness.schedulerCases()
    harness.next()
  }

  // Nothing here should take anywhere near this long; if it does, say so
  // rather than hanging the run.
  Timer {
    interval: 20000
    running: true
    onTriggered: {
      harness.check("the scenarios finished", false, "timed out at scenario " + harness.at)
      harness.report()
    }
  }
}
