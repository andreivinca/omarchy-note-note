import QtQuick
import "scheduler.js" as Scheduler

// One provider's lane: everything that provider asks of its backend goes
// through here, in order, at most `concurrency` at a time, and parked whole
// while the backend is rate-limiting it.
//
// This is the half of the pacing that lives in the host, and it owns the
// *long* waits. Its counterpart, `lib/ratelimit.py`, paces individual HTTP
// requests inside each script and sleeps only short ones; anything longer
// comes back as {"kind":"throttled","retryAfter":N} and parks this lane
// instead. Neither layer waits out what the other already waited
// (docs/engine-notes.md).
//
// The contract, in one line: **every enqueue is answered exactly once** —
// delivered, superseded, or cancelled. A provider that never hears back is
// a note that silently did not save, and that is the bug this exists to make
// impossible.
//
// QtQuick only, so it runs offscreen under `qml6` for the selftest.
Item {
  id: root

  // The rate key this lane belongs to ("graph-onenote"); a label, used in
  // warnings. The pacing itself lives in the scripts.
  property string domain: ""
  // Jobs run in parallel up to this many. The Python-side slot cap holds
  // total HTTP concurrency to MAX_CONCURRENT however many jobs run.
  property int concurrency: 3
  // Set by the host while the window is hidden: reads stop, writes drain.
  property bool paused: false

  readonly property int depth: root.revision >= 0 ? Scheduler.depth(root.queue) : 0
  readonly property bool cooling: root.revision >= 0 ? Scheduler.cooling(root.queue, Date.now()) : false
  readonly property real cooldownRemaining: root.revision >= 0 ? Scheduler.remaining(root.queue, Date.now()) : 0

  // Depth, cooling or the cooldown moved. (`updated`, never `changed`: a
  // signal called `changed` collides with Qt's own — docs/engine-notes.md.)
  signal updated()

  readonly property var queue: Scheduler.makeState()
  // Bindings cannot see inside a plain JS object, so every change to it bumps
  // this and the three readonly properties above hang off it.
  property int revision: 0
  property bool pumping: false
  property bool pumpAgain: false

  // enqueue(opts, start, settled) -> handle { cancel() }
  //
  //   opts:     { key, mode: "append"|"replace"|"dedupe", priority: 0|1,
  //               owner, flush: bool, label }
  //   start:    function(ctx) — begin the work, and call ctx.done(result)
  //             exactly once. A second call is ignored, so a process that
  //             answers twice cannot double-deliver.
  //   settled:  function(result, info) — info is
  //             { superseded, cancelled, attempts }.
  function enqueue(opts, start, settled) {
    var o = opts || {}
    var r = Scheduler.enqueue(root.queue, {
      key: o.key, mode: o.mode, priority: o.priority, owner: o.owner,
      flush: o.flush, label: o.label, start: start, settled: settled })
    if (r.superseded)
      root.answer(r.superseded, null, { superseded: true, cancelled: false,
                                        attempts: r.superseded.attempts })
    var job = r.job || r.joined
    root.bump()
    // Not dispatched inline: `start` would then run before the caller's own
    // next statement, which is a surprise nobody writing a provider wants.
    Qt.callLater(root.pump)
    return { cancel: function() { root.cancelHandle(job, settled) } }
  }

  // A provider being destroyed or signed out. What has not started is
  // answered as cancelled; what is already running is left to finish, since
  // its process is running either way and its callbacks travel with it.
  function cancelOwner(owner) {
    var dropped = Scheduler.cancelOwner(root.queue, owner)
    for (var i = 0; i < dropped.length; i++)
      root.answer(dropped[i], null, { superseded: false, cancelled: true,
                                      attempts: dropped[i].attempts })
    root.bump()
    Qt.callLater(root.pump)
  }

  // ── the machinery ───────────────────────────────────────────────────
  function bump() { root.revision++; root.updated() }

  function call(fn, result, info) {
    if (!fn) return
    // A provider's closure can outlive the provider (destroyed mid-flight), and
    // a throwing callback must not wedge the lane for everybody else.
    try { fn(result, info) }
    catch (e) { console.warn("note-note: request queue callback threw:", e) }
  }

  // Every caller waiting on this job, answered once and then forgotten — so a
  // second answer is impossible rather than merely unlikely.
  function answer(job, result, info) {
    var waiting = job.settled
    job.settled = []
    for (var i = 0; i < waiting.length; i++) root.call(waiting[i], result, info)
  }

  function cancelHandle(job, settled) {
    if (!job) return
    if (job.settled.length > 1) {
      // This handle had joined an existing job (dedupe): only its own answer
      // goes away, and the job itself carries on for the others.
      var at = job.settled.indexOf(settled)
      if (at >= 0) job.settled.splice(at, 1)
      root.call(settled, null, { superseded: false, cancelled: true, attempts: job.attempts })
      return
    }
    if (Scheduler.cancelJob(root.queue, job)) {
      root.answer(job, null, { superseded: false, cancelled: true, attempts: job.attempts })
      root.bump()
    }
    // Already in flight: not preempted, and its real result answers it.
  }

  function pump() {
    if (root.pumping) { root.pumpAgain = true; return }   // a start() answered inline
    root.pumping = true
    try {
      do {
        root.pumpAgain = false
        var opts = { concurrency: Math.max(1, root.concurrency) }
        var job = Scheduler.nextRunnable(root.queue, Date.now(), opts)
        while (job) {
          root.dispatch(job, Scheduler.markRunning(root.queue, job, Date.now()))
          job = Scheduler.nextRunnable(root.queue, Date.now(), opts)
        }
      } while (root.pumpAgain)
    } finally {
      root.pumping = false
    }
    root.scheduleWake()
    root.bump()
  }

  function dispatch(job, token) {
    if (!job.start) { root.finish(job, token, { error: "nothing to run" }); return }
    var ctx = {
      key: job.key,
      label: job.label,
      attempts: job.attempts,
      done: function(result) { root.finish(job, token, result) }
    }
    try {
      job.start(ctx)
    } catch (e) {
      console.warn("note-note: request queue start threw:", e)
      root.finish(job, token, { error: "" + e })
    }
  }

  function finish(job, token, result) {
    if (job.token !== token) return       // a repeated or late done(): already handled
    var decided = Scheduler.onResult(root.queue, job, result, Date.now())
    if (decided.action === "deliver")
      root.answer(job, result, { superseded: false, cancelled: false, attempts: job.attempts })
    root.bump()
    root.pump()
  }

  function scheduleWake() {
    var at = Scheduler.wakeAt(root.queue, Date.now())
    if (at <= 0) { waker.stop(); return }
    waker.interval = Math.max(50, at - Date.now())
    waker.restart()
  }

  onPausedChanged: {
    var dropped = Scheduler.setPaused(root.queue, root.paused)
    for (var i = 0; i < dropped.length; i++)
      root.answer(dropped[i], null, { superseded: false, cancelled: true,
                                      attempts: dropped[i].attempts })
    root.bump()
    if (!root.paused) Qt.callLater(root.pump)
  }

  // Fires when the park (or a transient job's backoff) is over. `cooldownUntil`
  // is wall-clock, so hiding and reopening the window never drifts it.
  Timer { id: waker; repeat: false; onTriggered: root.pump() }

  // While parked, the remaining time is on screen and has to count down.
  Timer {
    id: ticker
    interval: 1000
    repeat: true
    running: root.cooling
    onTriggered: root.bump()
  }
}
