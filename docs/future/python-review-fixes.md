# What the Python review found, and the order to fix it

*Status: **built, on 1.0.8**. Every finding below was read in the source and,
where the claim was about behaviour rather than shape, re-checked against this
machine; the two blocking items were verified, not inferred. Implementing them
turned up three places where this write-up was itself wrong, corrected in
place below and listed here so nobody re-derives them:*

- *§2's Verify line predicted the pre-fix order `80, 100, 9`. With three notes
  the text key sorts `"100" < "80" < "9"`, so it is **`100, 80, 9`**. The
  two-element example earlier in §2 was right; only the three-element
  prediction was wrong.*
- *§3a said the OneNote title 500 "currently reaches the user as a hard save
  failure they must retry by hand". It does not — `cmd_onenote_update` already
  puts it in a `warning` and still answers `{"ok": true}`. Following the
  instruction literally would have been a regression: that 500 arrives **every
  time** on the affected pages, so `kind="transient"` would have re-run a save
  that had already succeeded, three times, before failing it. That one call
  site passes `transient_5xx=False`; every other caller gets the new
  behaviour.*
- *§4's `imagesize` fix ("normpath plus a containment check against `base`")
  breaks for a relative `base`, and misses a sharper case than the one it
  names: the `startswith(("/", "data:"))` guard tests the **un-unquoted** url,
  so `%2Fetc%2Fpasswd` walks straight past it and `os.path.join` then discards
  `base` entirely. The relative half is normalised and checked instead.*

*Also built: `lib/provider_io.py` (§4's shared helpers, plus `fail_throttled`,
which the write-up's duplication list missed), and regression suites at
`providers/local/selftest.py`, `providers/notion/selftest.py` and
`services/microsoft/selftest.py` — see docs/testing.md.*

Two reviews were run over the 6,535 lines of hand-written Python — a general
Python review and a security review. `services/markdown/mistune/` was excluded
from both; it is vendored.

The security review came back with **no confirmed vulnerability**. That result
is worth stating plainly rather than burying, because the parts most likely to
be wrong are right: the device-code flow needs no redirect URI and no PKCE, so
there is no authorization-code interception surface to get wrong; tokens are
written through `mkstemp` (0600) inside a 0700 directory and moved with
`os.replace`, which is atomic and cannot be redirected by swapping a symlink
into the destination; a token is accepted only when its `client_id` matches the
provider's current registration, so a changed registration asks for a sign-in
instead of failing a refresh; and `image_allowed` in `onenote.py:276` blocks the
one attack that actually threatens this design — a note body carrying
`<img src="https://evil/…">` to walk the bearer token out — with an https-only,
`graph.microsoft.com`-only, no-query, no-fragment, no-redirect allowlist.
`providers/local/` and `lib/readfile.py` are stronger still: `O_NOFOLLOW` plus
`O_NONBLOCK` plus an `fstat` regular-file check plus a wall-clock deadline is
the correct shape for reading an untrusted path, and it is used consistently.

What follows is what is actually wrong.

## 1. A Notion update destroys the page before it knows what replaces it

`providers/notion/notion.py:263-272`. `cmd_update` deletes every existing
top-level block, and only then calls `notion_md.markdown_to_blocks` to build
the replacement and PATCH it back:

```python
old, _ = fetch_children(page_id, [MAX_BLOCKS + 1])
for b in old:
    status, res = api("DELETE", "/blocks/" + b["id"])
    ...
new = notion_md.markdown_to_blocks(payload.get("body", ""))
for i in range(0, len(new), 100):
    status, res = api("PATCH", "/blocks/%s/children" % page_id, ...)
```

There is a window, spanning a conversion and one HTTP round trip per hundred
blocks, in which the user's page exists and is empty. Anything that ends the
run inside that window ends it with the note gone.

The window is not theoretical. `api()` at line 129 promotes only `{429, 502,
503}` to a retryable `Retry`. Every other non-2xx — a `400` because a converted
block broke a Notion schema constraint, a `500`, a dropped connection mid-loop —
reaches `fail()` with no `kind`, and `providers/PROVIDERS.md` is explicit about
what the host does with that: *anything else — delivered as it stands*. It is
shown to the user once and never retried. The page stays empty, visibly, on
every device that has it open. Killing the app mid-save does the same thing
with no error at all.

**The fix is to reverse the order, not to add a rollback.** Build `new` first
and let a conversion failure abort before anything is touched. Insert the new
blocks. Only once every PATCH has returned 200 delete the old ones. The
worst-case failure then becomes a page with its content twice — ugly, obvious,
and something the user can fix — instead of a page with nothing.

A detail that makes the reordering safe: Notion appends children, so the new
blocks land after the old ones, and deleting the recorded `old` ids afterwards
cannot touch what was just written. Capture `old` ids before inserting.

**Verify:** point `cmd_update` at a page, force the insert to fail (a stubbed
`api` returning 400 on the first PATCH), and confirm the page still holds its
original content.

## 2. Local notes are not ordered by birth time, and never have been

`providers/local/list.py:93`:

```python
born = int(getattr(st, "st_birthtime", 0) or 0)
```

`os.stat()` does not expose `st_birthtime` on Linux. Checked on this machine,
Python 3.14.7, on btrfs — a filesystem that does record it:

```
$ python3 -c "import os; print(hasattr(os.stat('CLAUDE.md'), 'st_birthtime'))"
False
$ stat CLAUDE.md | grep Birth
 Birth: 2026-09-02 17:52:41.311886912 +0300
```

The birth time is there; `coreutils` reads it through `statx`. Python's
`os.stat()` does not surface it, so the `getattr` default fires for every note,
`born` is `0` for every note, and the primary sort key never discriminates.

Sorting then falls to the tie-break, which is a **string**:

```python
notes.append((born, "%s\t%s\t%s" % (st.st_size, int(st.st_mtime), entry.name), ...))
```

so it compares as text. A 9-byte note sorts after an 80-byte note, because
`'8' < '9'`:

```
$ python3 -c "print([n[1].split(chr(9))[0] for n in sorted([(0,'9\t1000\ta.md'),(0,'80\t1\tb.md')])])"
['80', '9']
```

The order is therefore neither birth time nor modification time nor name. It is
size-as-text, and it reshuffles whenever a note's length crosses a digit
boundary — a note reorders itself as you type into it. The module's own
docstring promises "oldest-first by birth time", and the comment about
same-second ties breaking "the way `sort -n` used to" describes an intent the
string comparison defeats.

**The fix is a product decision before it is a code change.** Three options:

- **Use `st_mtime`.** One line, correct, portable, and the tie-break becomes a
  numeric tuple `(int(st.st_mtime), entry.name)` rather than a formatted string.
  Changes what "oldest" means: a note edited today moves. Fix the docstring.
- **Read the real birth time through `statx`.** `ctypes` against libc, or
  `os.statx` if a future Python exposes it. Honest to the current docstring,
  and the only option that survives a note being edited. Costs a syscall
  wrapper and a fallback path for filesystems that do not record it.
  **← chosen.** The ordering is the fallback for notes not named in `.order`,
  so a note keeping its place while it is typed into is the property worth
  paying a syscall wrapper for. `AT_SYMLINK_NOFOLLOW` is passed, so the birth
  time is not the one lookup in that module that follows a link; where no
  birth time is recorded, `st_mtime` stands in.
- **Keep an explicit order file.** `.order` already exists in this directory
  and is already read; birth time stops mattering.

Whichever is chosen, **the tie-break must stop being a string**. That bug is
independent of the birth-time question and would still bite under `st_mtime`
if the format-then-compare shape were kept.

**Verify:** create three notes of sizes 9, 80 and 100 bytes in a known order
and assert the listing matches that order rather than `100, 80, 9`.

## 3. The `"transient"` retry exists everywhere except in the code that needs it

This is the finding that ties the next two together. `PROVIDERS.md` documents a
`kind` of `"transient"` — *re-run this job only, after 2.5s, 5s, 10s*. The host
implements it. `fail()` in `msgraph.py:57` takes a `kind` argument and its
docstring explains what `"transient"` does. And **no script in this repository
ever emits it**:

```
$ grep -rn 'transient' providers/ services/ lib/ --include=*.py | grep -v mistune
services/microsoft/msgraph.py:62:    passed and then re-runs the job, "transient" re-runs the job a few times
```

One hit, in a docstring. The mechanism was built and never wired up. Both
findings below are that gap seen from two sides.

### 3a. 500, 502 and 504 are delivered as permanent failures

`msgraph.py:206` and `onenote.py:76` promote only `{429, 503}`. Notion's
`api()` promotes `{429, 502, 503}`. Neither covers `500` or `504`, and the two
sets disagree with each other for no stated reason.

Graph returns transient 500s in normal operation — `onenote.py:763` already
carries a comment about pages that answer a title replace with a 500 *Transient
error*. That response currently reaches the user as a hard save failure they
must retry by hand, in a module whose docstring says "One Graph request, paced
and retried".

**Fix:** settle on `{429, 500, 502, 503, 504}` in all three call sites. Route
`429` and `503` to `Throttled` as today, since those carry `Retry-After` and
should park the lane; route `500`, `502` and `504` to `fail(..., kind="transient")`,
which re-runs the one job three times and then delivers whatever it says. The
distinction matters: a 500 on one page should not park every other OneNote
request behind it.

### 3b. A revoked token is never recognised as revoked

`msgraph.py:235` refreshes on the locally stored `expires_at` with a 60-second
buffer, and on nothing else. If Microsoft revokes the token server-side —
consent withdrawn, admin action, a conditional-access change — the local expiry
still looks fine, so no refresh is attempted, every request returns 401, and
`graph_err()` hands the user a raw Graph error string. The dead token stays on
disk. Every subsequent attempt fails the same way, and nothing tells the user
the actual remedy is to sign in again.

**Fix:** on a 401 from `graph()`/`graph_raw()`, force one refresh and retry the
request once. If the refresh itself fails, delete the token file and fail with
the same "not signed in" error the app already shows when no token exists, so
the UI offers a sign-in instead of an error string. This composes with the
existing registration-mismatch path at `msgraph.py:224`, which already handles
"the registration changed" — this handles "the registration is fine but the
grant is gone".

## 4. Smaller corrections

**`services/markdown/qthtml/imagesize.py:13-22`** joins a relative image URL to
`base` with no normalisation, so `../../x.png` reads a header outside the note's
folder. Both reviews found it and both rated it low: it is reachable only from
a path the user typed into their own note, pointing at a file they can already
read as themselves, and the exposure is a handful of header bytes parsed into a
width integer. Not a trust-boundary bug. Still worth `os.path.normpath` plus a
containment check against `base`, because the cost is three lines and the
property "an image reference cannot escape the note's directory" is easier to
keep than to re-derive later.

**`providers/onenote/onenote_md.py:285-287`** is unreachable — `block()` already
returns on `t == "img"` at line 217 — and contains `Node(..., children_of=None)`,
which is not a parameter `Node.__init__` accepts. The `if False` is the only
thing keeping it from raising `TypeError`. Refactor leftover; delete it.

**`providers/notion/notion.py`** does not `urllib.parse.quote` `page_id`,
`block_id` or the pagination `cursor` before putting them in request paths
(lines 219, 238, 254, 259, 265, 270, 291), where `onenote.py` quotes
consistently. Not exploitable — these values come from Notion's own API — but
the inconsistency is the kind that stops being safe quietly, and matching
`onenote.py` costs nothing.

**`services/markdown/qthtml/writer.py:268`** relies on `%` binding tighter than
the conditional expression. It is correct and it reads as though it might not
be. Parenthesise it.

**Duplicated helpers.** `notion.py` carries its own verbatim copies of `out()`,
`fail()`, `load_json()`, `save_private()` and `read_payload()` rather than
importing them the way `onenote.py` and `sticky.py` import from `msgraph`. The
bodies are identical today, which is exactly why the next fix to one of them —
the atomic-write logic in `save_private`, say — will be applied once and
believed to be applied everywhere. Lift them into a shared module. This is a
prerequisite for item 3a, which otherwise has to be written twice.

## 5. The project has no Python tooling at all

`ruff`, `mypy`, `black`, `isort`, `bandit`, `pylint` and `pytest` are all
absent, and there is no `pyproject.toml`, no `requirements.txt`, no declared
minimum Python version. Both reviews were done by reading, because there was
nothing to run.

Nothing here needs a dependency — the code is stdlib-only and should stay that
way — but the absence has a concrete cost beyond style. `getattr(st,
"st_birthtime", 0)` is precisely the shape a type checker flags, and the bug in
item 2 has been shipping for as long as the file has existed. A `pyproject.toml`
declaring `requires-python` and a `ruff` configuration would cost one file and
no runtime dependency. Worth doing after the blocking items, not before.

## Order of work

1. **Notion delete-then-insert (§1).** Self-contained, one function, stops the
   only finding that destroys user data.
2. **Local note ordering (§2).** Needs the product decision on what "oldest"
   means; the string tie-break can be fixed immediately regardless.
3. **Shared helpers (§4).** Small, and it makes the next item one change
   instead of three.
4. **Retry and 401 handling (§3).** Wire up the `"transient"` kind that already
   exists on the other side of the contract.
5. **The rest of §4**, then **tooling (§5)**.

Items 1, 2 and 4 each want a regression test, and there is no test runner — but
the repo already has a working pattern for this in `lib/ratelimit_selftest.py`,
`cpp/selftest.py` and `services/markdown/qthtml/selftest.py`. Follow it rather
than introducing `pytest`.

## What implementing it then found

A review of the implementation turned up four things the original write-up did
not anticipate, all of them created by §3a rather than found by it. They are
recorded because each is a way the fix could have been worse than the bug.

**A retry is only safe for a request that may be repeated.** §3a says to route
500, 502 and 504 to `kind="transient"`, and `"transient"` re-runs *the whole
job* three times. Applied at the HTTP layer that also covered `POST /pages` in
both providers, the section create, and the multipart save that carries pasted
images — and a 502 or a 504 is precisely the gateway losing the *answer* to a
request that may well have been carried out. One bad gateway would have left
the user with the same new note three times, or the same picture uploaded
three times onto a page that already had it. Every request helper now takes a
`transient_5xx` flag, on by default because most traffic here is reads and
replaces, and shut at each site where running twice is not the same as running
once. `providers/onenote/selftest.py` reads those flags off the calls, so a
create added later without one fails a test rather than duplicating a note.

**The sign-in flow must never be re-run.** The device-code request and its
polling loop went through the same helper, so a 500 mid-poll would have
re-run the login job and minted a *different* code while the user was still
reading the first one off the screen.

**`forget_token()` needed a guard.** Before §3b nothing but an explicit logout
removed the token file; afterwards any 401 could reach it. A lane runs up to
four processes (`lib/ratelimit.py`), and Entra rotates the refresh token on
every use — so two processes meeting a 401 together would see the second told
`invalid_grant` about a token that was merely no longer current, and delete
the good one the first had just written. It now deletes only while the file
still holds the token whose refresh failed, and a process that lost that race
takes the winner's token instead of reporting a sign-out that is not true.

**`cmd_login`'s account probe was deliberately survivable and stopped being
so.** It reads `/me` and shrugs off a failure (`... if s == 200 else ""`).
Routed through the new `graph()`, a 401 there — Entra replication lag right
after a redemption is real — would have forced a refresh and, failing that,
deleted the sign-in the user had just completed. It asks with the token in
hand now, through `http()`, and cannot reach that path.

Two smaller ones: a transient failure raised from inside the listing's thread
pool skipped the `listing.save(False)` that the throttle path does, throwing
away every section already fetched and letting a worker write JSON over three
others' stdout; and one Notion test asserted a property the code does not have
(it left the title unchanged, so the write it claimed to forbid was never
attempted at all).

## Read and found sound

Stated so a later reader knows these were examined rather than skipped:
`lib/ratelimit.py` in full — the sliding-window admission maths, the
`flock`-guarded read-modify-write, stale-holder reaping, the
monotonic-increase-only cooldown, and the decision to hold the lock only across
the state update and never across the request. Its one debatable choice, wall
clock rather than `time.monotonic()`, is the defensible one: a monotonic clock
would not survive the reboot that `cooldownUntil` is meant to outlive.
Also sound: the `qthtml` reader/writer escaping, including the round-trip
`_loses_text` check that re-parses its own output and compares visible text;
`clipboard.py`'s argv-list subprocess calls; and `sticky.py`, which performs one
atomic call per operation and has no equivalent of §1.
