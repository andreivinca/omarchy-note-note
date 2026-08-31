#!/usr/bin/env python3
"""Tests for lib/ratelimit.py — the cross-process request pacer.

Two halves, because the module has two jobs.

The **window and cooldown math** runs on a fake clock: `slot()` takes its
`now` and `sleep` from the caller, so a sixty-second wait costs nothing here
and every case is exact rather than approximately timed.

The **locking** cannot be faked, so the second half really does start eight
processes that hammer one key at once, and then checks the two invariants
that matter against what the state file actually recorded: the rolling window
count was never exceeded, and the concurrency cap was never exceeded.

    python3 lib/ratelimit_selftest.py [-v]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ratelimit  # noqa: E402

FAILURES = []


def check(name, ok, detail=""):
    if ok:
        return 0
    FAILURES.append(name + (": " + detail if detail else ""))
    return 1


class Clock:
    """A clock that only moves when something sleeps on it."""

    def __init__(self, t=1000.0):
        self.t = t
        self.slept = 0.0

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.slept += seconds
        self.t += seconds


def fresh(directory, key="k"):
    for suffix in (".json", ".lock"):
        try:
            os.remove(os.path.join(directory, ratelimit._safe(key) + suffix))
        except OSError:
            pass
    return key


def read_state(key):
    with open(ratelimit.state_path(key)) as handle:
        return json.load(handle)


# ---------------------------------------------------------------- fake clock

def test_windows(directory, verbose):
    failures = 0
    key = fresh(directory)
    windows = [(60, 5)]

    # A burst under budget is admitted with no wait at all — this is the
    # property that keeps a cold listing as fast as it is today.
    clock = Clock()
    for i in range(5):
        with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
            pass
    failures += check("burst admitted", clock.slept == 0, "slept %.1fs" % clock.slept)
    failures += check("burst recorded", len(read_state(key)["stamps"]) == 5)

    # The sixth needs the first to leave the window: a full minute, which is
    # longer than this process may sit on, so it becomes the host's problem.
    try:
        with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
            failures += check("over budget raises", False, "admitted a sixth request")
    except ratelimit.Throttled as t:
        failures += check("over budget retryAfter", abs(t.retry_after - 60.0) < 0.001,
                          "%.1f" % t.retry_after)

    # Near the edge of the window the wait is short, so it is slept here.
    clock.t += 45
    with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
        pass
    failures += check("near-cap wait slept", abs(clock.slept - 15.0) < 0.001,
                      "slept %.1fs" % clock.slept)

    # Two windows: whichever is tighter decides.
    key = fresh(directory, "two")
    clock = Clock()
    both = [(60, 100), (3600, 3)]
    for i in range(3):
        with ratelimit.slot(key, both, now=clock.now, sleep=clock.sleep):
            pass
    try:
        with ratelimit.slot(key, both, now=clock.now, sleep=clock.sleep):
            failures += check("hour window binds", False, "admitted a fourth")
    except ratelimit.Throttled as t:
        failures += check("hour window wait", abs(t.retry_after - 3600.0) < 0.001,
                          "%.1f" % t.retry_after)

    # Stamps outside every window are dropped, so the file cannot grow.
    key = fresh(directory, "trim")
    clock = Clock()
    for i in range(4):
        with ratelimit.slot(key, [(60, 100)], now=clock.now, sleep=clock.sleep):
            pass
    clock.t += 120
    with ratelimit.slot(key, [(60, 100)], now=clock.now, sleep=clock.sleep):
        pass
    failures += check("stamps trimmed", len(read_state(key)["stamps"]) == 1,
                      "%d left" % len(read_state(key)["stamps"]))
    print("windows and stamps")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_cooldown(directory, verbose):
    failures = 0
    key = fresh(directory, "cool")
    clock = Clock()

    ratelimit.report_throttle(key, 300, now=clock.now)
    start = time.time()
    try:
        with ratelimit.slot(key, [(60, 100)], now=clock.now, sleep=clock.sleep):
            failures += check("cooldown fails fast", False, "admitted during a cooldown")
    except ratelimit.Throttled as t:
        failures += check("cooldown retryAfter", abs(t.retry_after - 300.0) < 0.001,
                          "%.1f" % t.retry_after)
    failures += check("cooldown is instant", time.time() - start < 1.0)
    failures += check("cooldown slept nothing", clock.slept == 0, "slept %.1f" % clock.slept)

    # A worse cooldown extends it; a milder one does not shorten it.
    ratelimit.report_throttle(key, 60, now=clock.now)
    failures += check("cooldown never shortens",
                      abs(ratelimit.cooldown_remaining(key, now=clock.now) - 300.0) < 0.001)

    ratelimit.clear_throttle(key)
    with ratelimit.slot(key, [(60, 100)], now=clock.now, sleep=clock.sleep):
        pass
    failures += check("clear_throttle admits again", True)

    # A cooldown that simply ran out is forgotten by the next admission.
    ratelimit.report_throttle(key, 10, now=clock.now)
    clock.t += 11
    with ratelimit.slot(key, [(60, 100)], now=clock.now, sleep=clock.sleep):
        pass
    failures += check("expired cooldown cleared", read_state(key)["cooldownUntil"] == 0)
    print("cooldowns")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_concurrency(directory, verbose):
    failures = 0
    key = fresh(directory, "conc")
    clock = Clock()
    windows = [(60, 1000)]

    held = []
    for i in range(ratelimit.MAX_CONCURRENT):
        cm = ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep)
        cm.__enter__()
        held.append(cm)
    failures += check("cap holders recorded",
                      len(read_state(key)["holders"]) == ratelimit.MAX_CONCURRENT)

    # One more has nothing to wait for but another process finishing, so it
    # polls to the pacing timeout and then hands the wait upwards.
    try:
        with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
            failures += check("cap holds", False, "admitted past MAX_CONCURRENT")
    except ratelimit.Throttled as t:
        failures += check("cap retryAfter", t.retry_after == ratelimit.SHORT_RETRY,
                          "%.1f" % t.retry_after)
        failures += check("cap polled to the timeout",
                          abs(clock.slept - ratelimit.PACE_TIMEOUT) < ratelimit.CONCURRENCY_POLL * 2,
                          "slept %.2f" % clock.slept)

    held.pop().__exit__(None, None, None)
    failures += check("release frees a slot",
                      len(read_state(key)["holders"]) == ratelimit.MAX_CONCURRENT - 1)
    with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
        pass
    for cm in held:
        cm.__exit__(None, None, None)
    failures += check("all released", read_state(key)["holders"] == [])

    # A process that died holding a slot: reaped by its pid being gone.
    gone = subprocess.Popen(["true"])
    gone.wait()                                  # reaped, so its pid is free again
    dead = gone.pid
    clock = Clock()
    ratelimit._save(key, ratelimit._State(
        stamps=[], cooldownUntil=0.0,
        holders=[[dead, clock.now(), "dead-%d" % i] for i in range(ratelimit.MAX_CONCURRENT)]))
    with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
        pass
    failures += check("dead holder reaped", clock.slept == 0, "slept %.1f" % clock.slept)

    # A slot held by a live process (this one) that never released: reaped by
    # age, so a crash between the acquire and the release heals on its own.
    clock = Clock()
    ratelimit._save(key, ratelimit._State(
        stamps=[], cooldownUntil=0.0,
        holders=[[os.getpid(), clock.now() - ratelimit.STALE_HOLDER - 1, "old-%d" % i]
                 for i in range(ratelimit.MAX_CONCURRENT)]))
    with ratelimit.slot(key, windows, now=clock.now, sleep=clock.sleep):
        pass
    failures += check("stale holder reaped", clock.slept == 0, "slept %.1f" % clock.slept)
    print("concurrency slots")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_attempt_loop(directory, verbose):
    failures = 0
    key = fresh(directory, "loop")
    clock = Clock()
    windows = [(60, 1000)]

    tries = [0]

    def flaky():
        tries[0] += 1
        if tries[0] < 3:
            raise ratelimit.Retry(2.0)
        return "ok"

    got = ratelimit.attempt_loop(key, windows, flaky, now=clock.now, sleep=clock.sleep)
    failures += check("attempt_loop retries", got == "ok" and tries[0] == 3, "%r" % got)
    failures += check("attempt_loop slept the short waits", abs(clock.slept - 4.0) < 0.001,
                      "slept %.1f" % clock.slept)
    failures += check("a success records no cooldown", read_state(key)["cooldownUntil"] == 0)

    # A long wait is never slept here: it is recorded and handed upwards.
    key = fresh(directory, "loop2")
    clock = Clock()

    def throttled():
        raise ratelimit.Retry(300.0)

    try:
        ratelimit.attempt_loop(key, windows, throttled, now=clock.now, sleep=clock.sleep)
        failures += check("long wait raises", False, "returned")
    except ratelimit.Throttled as t:
        failures += check("long wait retryAfter", abs(t.retry_after - 300.0) < 0.001)
    failures += check("long wait slept nothing", clock.slept == 0, "slept %.1f" % clock.slept)
    failures += check("long wait recorded",
                      abs(ratelimit.cooldown_remaining(key, now=clock.now) - 300.0) < 0.001)

    # Every attempt exhausted, each asking for a short wait: still a cooldown.
    key = fresh(directory, "loop3")
    clock = Clock()
    count = [0]

    def always():
        count[0] += 1
        raise ratelimit.Retry(1.0)

    try:
        ratelimit.attempt_loop(key, windows, always, now=clock.now, sleep=clock.sleep)
        failures += check("exhausted raises", False, "returned")
    except ratelimit.Throttled as t:
        failures += check("exhausted attempts", count[0] == 3, "%d attempts" % count[0])
        failures += check("exhausted retryAfter", t.retry_after == 1.0)

    # No key: the token endpoint must never wait behind a Graph cooldown.
    ratelimit.report_throttle("loop3", 600, now=clock.now)
    failures += check("unpaced ignores cooldowns",
                      ratelimit.attempt_loop(None, windows, lambda: "free",
                                             now=clock.now, sleep=clock.sleep) == "free")
    print("attempt_loop")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def test_retry_after(verbose):
    failures = 0
    import email.utils

    cases = [
        ({"Retry-After": "12"}, 12.0),
        ({"Retry-After": " 3.5 "}, 3.5),
        ({"Retry-After": "not a number"}, None),
        ({}, None),
    ]
    for headers, want in cases:
        got = ratelimit.retry_after_of(headers)
        failures += check("retry_after_of %r" % headers, got == want, "%r" % got)
    failures += check("retry_after_of(None)", ratelimit.retry_after_of(None) is None)

    stamp = email.utils.formatdate(time.time() + 30, usegmt=True)
    got = ratelimit.retry_after_of({"Retry-After": stamp})
    failures += check("retry_after_of an HTTP date", got is not None and 25 < got < 35, "%r" % got)
    print("retry_after_of")
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


# ---------------------------------------------------------------- real locks

HAMMER = r"""
import json, os, sys, time
sys.path.insert(0, %(lib)r)
import ratelimit
key, rounds = sys.argv[1], int(sys.argv[2])
windows = json.loads(sys.argv[3])
log = []
for i in range(rounds):
    with ratelimit.slot(key, windows):
        held_from = time.time()
        time.sleep(0.02)                 # long enough for the cap to bind
        log.append([held_from, time.time()])
sys.stdout.write(json.dumps(log))
"""


def test_hammer(directory, verbose):
    """Eight processes, one key, at once. Nothing here is faked."""
    failures = 0
    key = fresh(directory, "hammer")
    span, budget, rounds, workers = 0.5, 8, 5, 8
    # A wide second window keeps every stamp in the file, so the check below
    # reads exactly what the pacer recorded rather than what survived a trim.
    windows = json.dumps([[span, budget], [3600, 100000]])
    lib = os.path.dirname(os.path.abspath(__file__))
    script = HAMMER % {"lib": lib}

    procs = [subprocess.Popen([sys.executable, "-c", script, key, str(rounds), windows],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=dict(os.environ, NOTE_NOTE_RATE_DIR=directory))
             for _ in range(workers)]
    holds = []
    for proc in procs:
        stdout, stderr = proc.communicate(timeout=180)
        if proc.returncode != 0:
            failures += check("hammer worker", False, stderr.decode()[-400:])
            continue
        holds.extend(json.loads(stdout))

    failures += check("hammer ran every request", len(holds) == workers * rounds,
                      "%d of %d" % (len(holds), workers * rounds))

    # 1. The window, as the state file recorded it: no `span` seconds may hold
    #    more than `budget` admissions.
    stamps = sorted(read_state(key)["stamps"])
    worst = 0
    for i, t in enumerate(stamps):
        inside = sum(1 for s in stamps if t - span < s <= t)
        worst = max(worst, inside)
    failures += check("rolling window never exceeded", worst <= budget,
                      "%d admissions inside %.1fs (budget %d)" % (worst, span, budget))
    failures += check("every request stamped", len(stamps) == workers * rounds,
                      "%d stamps" % len(stamps))

    # 2. The concurrency cap, as the workers experienced it: the held
    #    intervals sit strictly inside the file's own, so an overlap here is a
    #    real one.
    edges = [(a, 1) for a, _ in holds] + [(b, -1) for _, b in holds]
    edges.sort()
    live = peak = 0
    for _, delta in edges:
        live += delta
        peak = max(peak, live)
    failures += check("concurrency cap never exceeded", peak <= ratelimit.MAX_CONCURRENT,
                      "%d held at once (cap %d)" % (peak, ratelimit.MAX_CONCURRENT))
    if verbose:
        print("  peak concurrency %d, busiest window %d/%d" % (peak, worst, budget))
    failures += check("hammer left no holder", read_state(key)["holders"] == [],
                      "%r" % read_state(key)["holders"])
    print("eight processes on one key (%d requests)" % len(holds))
    print("  %d checks failed" % failures if failures else "  all green")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="note-note-rate-selftest-") as directory:
        os.environ["NOTE_NOTE_RATE_DIR"] = directory
        total = 0
        total += test_windows(directory, args.verbose)
        total += test_cooldown(directory, args.verbose)
        total += test_concurrency(directory, args.verbose)
        total += test_attempt_loop(directory, args.verbose)
        total += test_retry_after(args.verbose)
        total += test_hammer(directory, args.verbose)

    if FAILURES:
        print("\n%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  - " + line)
        return 1
    print("\nall green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
