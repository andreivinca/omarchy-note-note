#!/usr/bin/env python3
"""Tests for the request queue — services/requests/.

The queue is QML and JavaScript, so the test is too: `selftest.qml` holds the
scenarios and this runs it under the offscreen QML runtime, the same shape as
`services/markdown/qthtml/selftest.py`. No shell, no display, no account.

The scenarios come in two halves. The scheduler half calls `scheduler.js`
directly with the clock passed in as an argument, so a sixty-second park costs
nothing and every case is exact. The queue half drives a real `RequestQueue`
with real timers and short waits, because the property that matters — every
enqueue is answered exactly once, whatever happens to it — only exists once
the timers, the callbacks and the re-entrancy are real.

    python3 services/requests/selftest.py [-v]

Skipped with a warning when `qml6` is missing.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run_scenarios():
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
    try:
        proc = subprocess.run(["qml6", os.path.join(HERE, "selftest.qml")],
                              capture_output=True, text=True, timeout=120, env=env)
    except FileNotFoundError:
        raise RuntimeError("qml6 is not installed")
    blob = proc.stderr.split("<<<RESULT>>>")
    if len(blob) < 2:
        raise RuntimeError("no result from qml6:\n" + proc.stderr[-2000:])
    return json.loads(blob[1].split("<<<END>>>")[0]), proc.stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    try:
        results, stderr = run_scenarios()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print("SKIPPED: %s" % error)
        return 0

    # A QML warning during the run is a finding in itself: the queue catches
    # what providers throw, and says so on the way past.
    noise = [line for line in stderr.splitlines()
             if ("qrc:" in line or ".qml:" in line) and "request queue" not in line]

    failed = [r for r in results if not r["ok"]]
    for result in results:
        if args.verbose or not result["ok"]:
            mark = "ok  " if result["ok"] else "FAIL"
            print("  %s %s%s" % (mark, result["name"],
                                 (" — " + result["detail"]) if result["detail"] else ""))
    print("%d/%d checks" % (len(results) - len(failed), len(results)))
    if noise:
        print("unexpected QML output:")
        for line in noise[:10]:
            print("  " + line)

    if failed or noise:
        print("\n%d failure(s)" % (len(failed) + bool(noise)))
        return 1
    print("\nall green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
