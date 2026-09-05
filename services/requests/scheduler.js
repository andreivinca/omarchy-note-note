.pragma library

// The request queue's logic, as pure functions over a plain state object.
//
// Nothing here touches QML, a timer or a process — `RequestQueue.qml` owns all
// of that and calls in here to decide *what* should happen next. That split is
// the point: the awkward parts (per-key ordering, coalescing, priority, the
// throttle park) are then testable without a shell, which is what
// services/requests/selftest.py does.
//
// The vocabulary, once:
//
//   key       what may not overlap itself. Two saves of one page share a key
//             and run strictly in order; a save and a listing do not.
//   mode      what a newcomer does to a queued job of the same key —
//             "append" (nothing), "replace" (supersede it), "dedupe" (join it).
//   priority  0 interactive, 1 background. 0 dispatches first, and a
//             background job never takes the lane's last slot.
//   flush     a write. It keeps draining while the window is hidden; a read
//             does not.
//
// ES5 only: this is the QML engine (docs/engine-notes.md).

// A throttle that named no wait of its own: how long to park, growing while it
// keeps happening. Capped low because a park is re-entered, never slept
// through — if the service is still busy it simply says so again.
var THROTTLE_BACKOFF = [10000, 20000, 40000, 60000]
// A transient failure is one job's problem, not the lane's: only that job
// waits, and only so many times.
var TRANSIENT_BACKOFF = [2500, 5000, 10000]
var MAX_TRANSIENT = 3

function makeState() {
  return {
    seq: 0,              // ids, and the dispatch token that makes done() idempotent
    jobs: [],            // queued, in arrival order
    running: [],         // dispatched, waiting to be answered
    owners: [],          // owner objects, for the round-robin (index, not identity)
    lastRun: {},         // owner index -> the seq it last dispatched at
    cooldownUntil: 0,    // wall-clock ms: the whole lane is parked until then
    throttles: 0,        // consecutive throttles, for THROTTLE_BACKOFF
    paused: false
  }
}

function ownerIndex(state, owner) {
  if (owner === null || owner === undefined) {
    return -1
  }
  // Owners are QML objects, and an object cannot be a key: `{}` stringifies
  // every one of them to the same thing, which would make the round-robin a
  // single queue. So they are numbered instead.
  var at = state.owners.indexOf(owner)
  if (at < 0) {
    at = state.owners.length
    state.owners.push(owner)
  }
  return at
}

// The *last* queued job of a key: the newest statement of that intent, which
// is the one a replace should overwrite and a dedupe should join.
function lastQueuedIndexOf(state, key) {
  for (var i = state.jobs.length - 1; i >= 0; i--) {
    if (state.jobs[i].key === key) {
      return i
    }
  }
  return -1
}

// -> { job, superseded, joined }. Exactly one of `job` and `joined` is set;
// `superseded` is a job whose start will now never run and whose caller must
// be answered straight away.
function enqueue(state, opts) {
  var mode = opts.mode || "append"
  var job = {
    id: ++state.seq,
    key: opts.key || ("job:" + state.seq),
    mode: mode,
    priority: opts.priority === 1 ? 1 : 0,
    owner: opts.owner === undefined ? null : opts.owner,
    ownerId: ownerIndex(state, opts.owner),
    flush: opts.flush === true,
    label: opts.label || opts.key || "",
    start: opts.start || null,
    settled: opts.settled ? [opts.settled] : [],
    attempts: 0,
    notBefore: 0,
    token: 0
  }
  var at = lastQueuedIndexOf(state, job.key)
  if (at >= 0 && mode === "replace") {
    // The newer job strictly contains the older one's intent (a save of the
    // same page, a delete of it). An in-flight job is never preempted, so
    // this only ever supersedes something that has not started.
    var old = state.jobs[at]
    state.jobs[at] = job
    return { job: job, superseded: old, joined: null }
  }
  if (at >= 0 && mode === "dedupe") {
    var existing = state.jobs[at]
    if (opts.settled) {
      existing.settled.push(opts.settled)
    }
    return { job: null, superseded: null, joined: existing }
  }
  state.jobs.push(job)
  return { job: job, superseded: null, joined: null }
}

function beats(state, a, b) {
  if (a.priority !== b.priority) {
    return a.priority < b.priority
  }
  var la = state.lastRun[a.ownerId] || 0, lb = state.lastRun[b.ownerId] || 0
  if (la !== lb) {
    return la < lb  // round-robin: whoever has waited longest
  }
  return a.id < b.id                 // then simply whoever asked first
}

// The next job to dispatch, or null. opts: { concurrency }.
function nextRunnable(state, nowMs, opts) {
  var concurrency = Math.max(1, (opts && opts.concurrency) || 1)
  if (state.running.length >= concurrency) {
    return null
  }
  if (state.cooldownUntil > nowMs) {
    return null  // parked: nothing at all runs
  }
  var busy = {}, i
  for (i = 0; i < state.running.length; i++) {
    busy[state.running[i].key] = true
  }
  var seen = {}, best = null
  for (i = 0; i < state.jobs.length; i++) {
    var job = state.jobs[i]
    // Per-key FIFO is absolute, across priorities: only the oldest queued job
    // of a key is a candidate, and none of them while one is in flight.
    if (seen[job.key]) {
      continue
    }
    seen[job.key] = true
    if (busy[job.key]) {
      continue
    }
    if (state.paused && !job.flush) {
      continue
    }
    if (job.notBefore > nowMs) {
      continue
    }
    // A background job never takes the last slot, so an interactive one never
    // waits behind a lane full of polls.
    if (job.priority > 0 && state.running.length >= concurrency - 1) {
      continue
    }
    if (best === null || beats(state, job, best)) {
      best = job
    }
  }
  return best
}

// Move a job from queued to in-flight. Returns the dispatch token: an answer
// carrying any other token is a late one from an attempt already accounted
// for, and is dropped. This is what makes ctx.done() idempotent.
function markRunning(state, job, nowMs) {
  var at = state.jobs.indexOf(job)
  if (at >= 0) {
    state.jobs.splice(at, 1)
  }
  state.running.push(job)
  job.attempts++
  job.token = ++state.seq
  state.lastRun[job.ownerId] = state.seq
  return job.token
}

// -> { action: "deliver" | "park" | "retryAt", at }
function onResult(state, job, result, nowMs) {
  var at = state.running.indexOf(job)
  if (at >= 0) {
    state.running.splice(at, 1)
  }
  job.token = 0
  var kind = (result && typeof result === "object") ? result.kind : ""

  if (kind === "throttled") {
    var asked = result.retryAfter
    var wait = (typeof asked === "number" && isFinite(asked) && asked > 0)
      ? Math.round(asked * 1000)
      : THROTTLE_BACKOFF[Math.min(state.throttles, THROTTLE_BACKOFF.length - 1)]
    state.throttles++
    state.cooldownUntil = Math.max(state.cooldownUntil, nowMs + wait)
    job.notBefore = state.cooldownUntil
    // Back to the head, not the back: it was first, and nothing it was ahead
    // of has become more urgent by the service saying no.
    state.jobs.unshift(job)
    return { action: "park", at: state.cooldownUntil }
  }

  if (kind === "transient" && job.attempts < MAX_TRANSIENT) {
    var pause = TRANSIENT_BACKOFF[Math.min(job.attempts - 1, TRANSIENT_BACKOFF.length - 1)]
    job.notBefore = nowMs + pause
    state.jobs.unshift(job)
    return { action: "retryAt", at: job.notBefore }
  }

  // An answer that is not a throttle says the lane is working — but only if
  // it did not arrive from a job that was already in flight when the park
  // began, which would otherwise reset an escalation that is still true.
  if (state.cooldownUntil <= nowMs) {
    state.throttles = 0
  }
  return { action: "deliver", at: 0 }
}

// Hiding the window: reads and polls are dropped (they are re-requested by
// the next open()), writes keep draining. Returns the jobs dropped, for their
// callers to be told.
function setPaused(state, paused) {
  state.paused = paused === true
  if (!state.paused) {
    return []
  }
  var kept = [], dropped = []
  for (var i = 0; i < state.jobs.length; i++) {
    if (state.jobs[i].flush) {
      kept.push(state.jobs[i])
    } else {
      dropped.push(state.jobs[i])
    }
  }
  state.jobs = kept
  return dropped
}

// A provider being destroyed. In-flight jobs are left to finish — the process
// is already running and its callbacks travel with it — and only what has not
// started is dropped. Returns the dropped jobs.
function cancelOwner(state, owner) {
  var kept = [], dropped = [], i
  for (i = 0; i < state.jobs.length; i++) {
    if (state.jobs[i].owner === owner) {
      dropped.push(state.jobs[i])
    } else {
      kept.push(state.jobs[i])
    }
  }
  state.jobs = kept
  var at = state.owners.indexOf(owner)
  if (at >= 0) {
    state.owners[at] = null  // stop holding a destroyed object
  }
  return dropped
}

function cancelJob(state, job) {
  var at = state.jobs.indexOf(job)
  if (at < 0) {
    return false  // in flight: not preempted
  }
  state.jobs.splice(at, 1)
  return true
}

function depth(state) { return state.jobs.length + state.running.length }
function cooling(state, nowMs) { return state.cooldownUntil > nowMs }
function remaining(state, nowMs) { return Math.max(0, state.cooldownUntil - nowMs) / 1000 }

// When something could next become runnable on its own, or 0 for "nothing is
// waiting on the clock". While the lane is parked that is the only answer
// there is, since nothing else can run before it.
function wakeAt(state, nowMs) {
  if (state.cooldownUntil > nowMs) {
    return state.cooldownUntil
  }
  var at = 0
  for (var i = 0; i < state.jobs.length; i++) {
    var nb = state.jobs[i].notBefore
    if (nb > nowMs && (at === 0 || nb < at)) {
      at = nb
    }
  }
  return at
}
