#!/usr/bin/env python3
"""Cross-process request pacing for Note Note's provider scripts.

Every HTTP request this plugin makes happens inside a short-lived `python3`
process: the host spawns one per operation, and one operation can be forty
requests. Nothing in such a process outlives it, so the only place a budget
can be kept is a file. This module keeps one per *rate key* — a small JSON
document guarded by `flock` — and admits requests against it.

The division of labour with the QML side is the point (docs/engine-notes.md).
This layer paces individual *requests* and sleeps **short** waits only, up to
`PACE_TIMEOUT`. A longer wait is never slept out here: a script blocked for
ten minutes is a process the host cannot answer for, and the user cannot
close. It becomes a `Throttled`, which the script reports as
`{"kind":"throttled","retryAfter":N}`, and the queue in the host parks that
provider's lane until the wait is over. Two layers, one wait, never both.

Admission is by **sliding-window count**, not by a fixed gap: while the
rolling counts are under budget every request goes straight through, so a
cold listing runs at full speed and only a genuinely heavy hour is paced. A
separate **concurrency** cap bounds how many requests one key may have in
flight across every process at once — Microsoft allows five per app+user.

Standard library only, and importable by an external provider:

    import ratelimit
    with ratelimit.slot("my-api", [(60, 100)]):
        ...one request...
"""
import contextlib
import errno
import fcntl
import json
import os
import tempfile
import time
import uuid

HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "omarchy")
# One directory, two files per key: <key>.json (the state) and <key>.lock (the
# flock). Overridable so the selftest never touches the real budget.
DEFAULT_DIR = os.path.join(CACHE_DIR, "note-note-rate")

# How long a request may wait *inside* the script before the wait becomes the
# host's problem instead. Twenty seconds is under every timeout above us and
# far under the tens of minutes a throttled Graph account stays throttled.
PACE_TIMEOUT = 20.0
# What a 429 without a `Retry-After` costs. OneNote's usually carry none, and
# a throttled account is throttled for far longer than a backoff guesses, so
# the honest answer is a real cooldown rather than three quick retries that
# spend budget to learn nothing.
DEFAULT_COOLDOWN = 60.0
# A blip (503, a dropped connection) is worth one short wait in-process.
SHORT_RETRY = 5.0

# Microsoft allows 5 concurrent requests per app+user; 4 leaves headroom for
# a request already in flight from another process we cannot see.
MAX_CONCURRENT = 4
# A slot holder whose process died mid-request would otherwise hold its slot
# for ever. Holders are reaped by pid *and* by age: 90 s is longer than any
# request this plugin makes (the longest read deadline is 60 s).
STALE_HOLDER = 90.0
# While the concurrency cap is full there is nothing to compute a wait from —
# a slot frees when someone else finishes — so that one case polls.
CONCURRENCY_POLL = 0.1
# The state file is bounded like everything else here: stamps outside the
# widest window are dropped on every admission, and this is the hard stop.
MAX_STAMPS = 5000


class Throttled(Exception):
    """The wait is longer than this process should sit on. `retry_after` is
    how many seconds the caller (ultimately the queue in the host) should
    wait before trying again."""

    def __init__(self, retry_after=DEFAULT_COOLDOWN, message=""):
        self.retry_after = float(retry_after)
        Exception.__init__(self, message or "throttled for %.0fs" % self.retry_after)


class Retry(Exception):
    """One attempt asked to be repeated after `after` seconds. Raised by the
    `once()` body of `attempt_loop`, never seen by its callers: the loop
    either sleeps it out or turns it into a `Throttled`."""

    def __init__(self, after):
        self.after = float(after)
        Exception.__init__(self, "retry in %.1fs" % self.after)


# ---------------------------------------------------------------- state files

def _dir():
    return os.environ.get("NOTE_NOTE_RATE_DIR") or DEFAULT_DIR


def _safe(key):
    """A rate key is a file name, and an external provider chooses it."""
    out = "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(key))
    return (out or "key")[:64]


def state_path(key):
    return os.path.join(_dir(), _safe(key) + ".json")


class _State(dict):
    """The key's state, with a flag saying whether it needs writing back."""
    dirty = False


def _load(key):
    st = _State(stamps=[], holders=[], cooldownUntil=0.0)
    try:
        with open(state_path(key)) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return st
    if not isinstance(raw, dict):
        return st
    stamps = raw.get("stamps")
    if isinstance(stamps, list):
        st["stamps"] = [float(s) for s in stamps if isinstance(s, (int, float))][-MAX_STAMPS:]
    holders = raw.get("holders")
    if isinstance(holders, list):
        st["holders"] = [h for h in holders if isinstance(h, list) and len(h) == 3][:64]
    cd = raw.get("cooldownUntil")
    if isinstance(cd, (int, float)):
        st["cooldownUntil"] = float(cd)
    return st


def _save(key, st):
    d = _dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = state_path(key)
    fd, tmp = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"stamps": st["stamps"], "holders": st["holders"],
                       "cooldownUntil": st["cooldownUntil"]}, f)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


@contextlib.contextmanager
def _locked(key):
    """The key's state, read and (if the body dirtied it) written back, with
    an exclusive lock held across the whole read-modify-write. The lock file
    is separate from the state file because the state file is replaced by
    rename — locking a file that is about to be unlinked locks nothing.

    Held for a read-modify-write and nothing more. In particular it is *not*
    held while a request runs: `slot()` takes it to admit, releases it, and
    takes it again to release the concurrency slot. That is what lets several
    threads of one process hold slots at once — `flock` counts two
    descriptors on one file as two holders even inside a single process, so a
    lock held across the body would deadlock a thread against itself.
    """
    d = _dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(d, _safe(key) + ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        st = _load(key)
        yield st
        if st.dirty:
            _save(key, st)
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


# ---------------------------------------------------------------- admission

def _alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OverflowError, ValueError, TypeError):
        # Not ours to signal, or not a pid at all: err towards "in use", and
        # let the age check reap it.
        return True
    except OSError as e:
        return e.errno != errno.ESRCH
    return True


def _reap(st, t):
    """Drop holders whose process is gone or whose slot is older than any
    request can legitimately be, and stamps no window can still see."""
    kept = [h for h in st["holders"] if (t - _num(h[1])) <= STALE_HOLDER and _alive(h[0])]
    if len(kept) != len(st["holders"]):
        st["holders"] = kept
        st.dirty = True
    if st["cooldownUntil"] and st["cooldownUntil"] <= t:
        # The cooldown ran out: forget it here, so the next process to look
        # does not have to. (A still-throttled account simply reports another.)
        st["cooldownUntil"] = 0.0
        st.dirty = True


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _trim(st, windows, t):
    span = max([w[0] for w in windows] or [0])
    stamps = [s for s in st["stamps"] if s > t - span]
    if len(stamps) > MAX_STAMPS:
        stamps = stamps[-MAX_STAMPS:]
    if len(stamps) != len(st["stamps"]):
        st["stamps"] = stamps
        st.dirty = True


def window_wait(stamps, windows, t):
    """How long until one more request fits every window. 0 means now.

    A window is (span seconds, budget requests). While fewer than `budget`
    stamps fall inside the last `span` seconds the answer is 0 — which is why
    a burst runs at full speed — and once the window is full the answer is
    when its oldest relevant stamp leaves it.
    """
    wait = 0.0
    for span, budget in windows:
        if budget <= 0 or span <= 0:
            continue
        inside = sorted(s for s in stamps if s > t - span)
        if len(inside) >= budget:
            wait = max(wait, inside[len(inside) - budget] + span - t)
    return wait


def _acquire(key, windows, now, sleep):
    deadline = now() + PACE_TIMEOUT
    token = "%d-%s" % (os.getpid(), uuid.uuid4().hex[:8])
    while True:
        with _locked(key) as st:
            t = now()
            _reap(st, t)
            _trim(st, windows, t)
            if st["cooldownUntil"] > t:
                raise Throttled(st["cooldownUntil"] - t, "rate cooldown is active")
            wait = window_wait(st["stamps"], windows, t)
            if wait <= 0 and len(st["holders"]) < MAX_CONCURRENT:
                st["stamps"].append(t)
                st["holders"].append([os.getpid(), t, token])
                st.dirty = True
                return token
            # The concurrency cap has no deadline to compute: a slot frees
            # when another process finishes, so this is the one poll here.
            if wait <= 0:
                wait = CONCURRENCY_POLL
        if now() + wait > deadline:
            raise Throttled(max(wait, SHORT_RETRY), "paced out")
        sleep(wait)


def _release(key, token):
    with _locked(key) as st:
        kept = [h for h in st["holders"] if h[2] != token]
        if len(kept) != len(st["holders"]):
            st["holders"] = kept
            st.dirty = True


@contextlib.contextmanager
def slot(key, windows, now=time.time, sleep=time.sleep):
    """Admit one request against `key`'s budget, and hold a concurrency slot
    for as long as the body runs.

    Raises `Throttled` immediately when a cooldown is recorded, and when the
    projected wait is longer than `PACE_TIMEOUT`. `now`/`sleep` are injected
    so the selftest can run a fake clock.
    """
    token = _acquire(key, windows, now, sleep)
    try:
        yield
    finally:
        try:
            _release(key, token)
        except OSError:
            pass    # a released slot that cannot be written is reaped by age


def report_throttle(key, retry_after=DEFAULT_COOLDOWN, now=time.time):
    """Record that the service said no. Every process that starts during the
    cooldown then fails fast, without touching the network."""
    until = now() + max(float(retry_after), 1.0)
    with _locked(key) as st:
        if until > st["cooldownUntil"]:
            st["cooldownUntil"] = until
            st.dirty = True
    return until


def clear_throttle(key):
    """Forget a recorded cooldown — a request got through, so it is over."""
    with _locked(key) as st:
        if st["cooldownUntil"]:
            st["cooldownUntil"] = 0.0
            st.dirty = True


def cooldown_remaining(key, now=time.time):
    """Seconds left on the recorded cooldown; 0 when there is none."""
    with _locked(key) as st:
        return max(0.0, st["cooldownUntil"] - now())


def retry_after_of(headers):
    """`Retry-After` as seconds — a count or an HTTP date — or None.

    Graph's OneNote 429s usually carry no such header at all, which is why
    every caller has to decide what a missing one means (see DEFAULT_COOLDOWN).
    """
    if headers is None:
        return None
    try:
        raw = headers.get("Retry-After")
    except AttributeError:
        return None
    if raw is None:
        return None
    raw = str(raw).strip()
    try:
        return max(0.0, float(raw))
    except ValueError:
        pass
    try:
        from email.utils import parsedate_to_datetime
        import datetime
        when = parsedate_to_datetime(raw)
        if when is None:
            return None
        if when.tzinfo is None:
            when = when.replace(tzinfo=datetime.timezone.utc)
        return max(0.0, (when - datetime.datetime.now(datetime.timezone.utc)).total_seconds())
    except (TypeError, ValueError, OverflowError, ImportError):
        return None


# ---------------------------------------------------------------- retry loop

@contextlib.contextmanager
def _maybe_slot(key, windows, now, sleep):
    if key:
        with slot(key, windows, now=now, sleep=sleep):
            yield
    else:
        yield


def attempt_loop(key, windows, once, attempts=3, now=time.time, sleep=time.sleep):
    """Run `once()` under the pacer, repeating what it asks to repeat.

    `once()` returns whatever the caller wants back, or raises `Retry(after)`
    to say the attempt failed in a way that is worth trying again — which is
    where every 429/503 in this plugin ends up. A short `after` is slept here
    and the attempt is repeated; a long one (or one arriving on the last
    attempt) is recorded as this key's cooldown and raised as `Throttled`,
    because a wait that long belongs to the queue in the host, not to a
    process holding a slot.

    `key` may be None — the token endpoint is deliberately unpaced, so that
    signing in never waits behind a Graph cooldown.
    """
    last = None
    for attempt in range(max(1, attempts)):
        retry = None
        with _maybe_slot(key, windows, now, sleep):
            try:
                return once()
            except Retry as r:
                retry = r
        last = retry
        wait = retry.after
        if attempt + 1 >= attempts or wait > PACE_TIMEOUT:
            break
        sleep(wait)
    wait = last.after if last else DEFAULT_COOLDOWN
    if key:
        report_throttle(key, wait, now=now)
    raise Throttled(wait)
