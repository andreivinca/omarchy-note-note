# Security rules and review history

This plugin runs **unsandboxed inside the user's shell process**, holds OAuth
tokens for their mailbox and notebooks, and parses content that arrives from
the network. The marketplace reviewers read the code carefully and found five
distinct classes of problem. Each one is written down here with the rule it
produced, so it does not come back.

**Read the checklist at the bottom before every release.**

---

## The rules

### 1. Bound every input at the moment you read it

Not after. A size check followed by a separate open is **not** a bound — the
file can change in between (the reviewer's exact words: *"A same-user writer
can replace or grow either file between the check and load"*).

- Read `cap + 1` bytes once, and use *those bytes*. Over the cap → reject.
- Applies to files (`lib/readfile.py`, which also enforces rule 9), HTTP
  bodies (`read(max + 1)`), and process output.
- `FileView` in QML has no bounded read: it is **write-only** in this project.
  Local notes and the state file are read through `lib/readfile.py`.
- Bound collections too, not only bytes: number of notes, sections, pages,
  blocks, images.

### 2. Never write through a predictable temp path

- Use `tempfile.mkstemp(dir=<target dir>)` — a fresh `O_CREAT|O_EXCL`, 0600
  file that cannot be an existing file or a symlink — then `os.replace()` onto
  the target. `open(path + ".tmp", "w")` is how a symlink attack redirects a
  truncation.
- Credential and cache directories are created `0700`, files `0600`. Anything
  another program produced for us (e.g. an ImageMagick output) gets an
  explicit `chmod 0600` before it is kept.

### 3. Secrets and payloads never travel through a shared directory

- Note bodies and the Notion integration secret are passed to the provider
  scripts **over stdin** (`-` as the path argument). Nothing goes through
  `/tmp` or `$XDG_RUNTIME_DIR`.
- The QML sequence is fixed and must not be reordered:
  ```qml
  proc.stdinEnabled = true     // 1. writable pipe exists before the process runs
  proc.running = true          // 2. start
  proc.write(payload)          // 3. bounded payload
  proc.stdinEnabled = false    // 4. close → the script sees EOF
  ```

### 4. Never let remote content choose a URL you attach a credential to

Page content is attacker-controlled. An `<img src>` inside a OneNote page is
*not* a trustworthy fetch target.

- Allow-list the exact endpoint: scheme `https`, host equal to
  `graph.microsoft.com`, path matching the resource pattern, no query, no
  fragment. Compare the **whole host** (`graph.microsoft.com.evil.example`
  must fail).
- Refuse redirects (a custom `HTTPRedirectHandler` returning `None`), so a
  302 cannot move a bearer token to another origin.
- Anything not allowed is never requested; it is rendered as text.

OneNote section ordering additionally reads remote `.onetoc2` metadata with
optional delegated `Files.Read`. This permission is broader than notebook access, but
the implementation probes only the personal notebook's verified OneDrive
package and its children. It never downloads `.one` section bodies. Graph
pagination stays under `https://graph.microsoft.com/v1.0/me/drive/items/`;
redirects are refused. TOC downloads accept only HTTPS Microsoft file-host
suffixes listed in the README, with no userinfo, fragment or nonstandard port.
They carry the short-lived signed URL, **not** the Graph bearer token. Neither
URLs nor raw TOCs are written to the provider cache or error messages.

Each metadata response is limited to 512 KiB and 30 seconds (10-second socket
timeout, wall-clock checks around each `read1`). An ordering pass allows at
most 160 requests and 64 notebook/group folders, with a 45-second wall-clock
budget checked before requests and reads (the shared pacer can delay completion).
Each folder listing is capped at 1,000 items. The binary
reader caps stream objects, references and tree visits at 8,192 and nesting at
32; it validates package/schema IDs, lengths, revision inheritance and cycles.
The parsed-order cache is versioned, pruned to live notebooks, bounded to 1 MiB
and stored with the existing private listing cache. Deleted TOC records are
joined only to live drive children and live Graph sections, never resurrected.
Incomplete or mismatched live positions/identities are rejected. Failed ordering
uses a deterministic alphabetical section sequence, never stale custom ranks.

The optional transport receives an already-issued token and cannot refresh or
delete the shared sign-in. Its separate `graph-onenote-section-order` rate key
keeps metadata throttles out of the normal note lane. Optional imports, parser
errors and unexpected exceptions are contained by the listing's alphabetical
fallback; error text from unexpected failures is not exposed. `Files.Read`
does not gate note access, and failed optional-scope renewal retries required
scopes before declaring the sign-in unusable. Optional consent never signs
out the working account first.

### 5. What goes *out* is bounded too

Pasting a picture sends bytes to someone else's service, so the same care
applies in reverse (`services/clipboard/clipboard.py`,
`providers/onenote/onenote.py`).

- The clipboard is read with a ceiling, into a file opened `O_EXCL` with mode
  `0600` under the user's own cache — never a predictable shared path (rule 2).
- Only real image types are accepted, by an allow-list of media types, and the
  suffix written is ours rather than anything the clipboard suggested.
- An upload is capped per image, per request and in count. Over the cap the
  save **fails loudly**; it never drops the picture quietly.
- A page whose images could not all be fetched refuses to save at all, so a
  half-loaded note can never overwrite a full one.
- An unchanged image is **never sent back in any form** — not even as its own
  resource URL: OneNote copies a referenced resource, and the copy of one it
  has not materialised yet is empty forever. A save that had to touch every
  image (a page being restructured) uploads the bytes we hold, or fails
  loudly; it never asks the service to copy them.
- Staged pastes are pruned by age and count: a directory that only grows is a
  disk-fill waiting to happen.

### 6. Bound time and disk, not only single responses

- A socket timeout bounds one read, not the transfer: a drip-fed response can
  hold a connection open forever. Use a **wall-clock deadline** across all
  reads (`time.monotonic()`), and one shared budget per page for many fetches.
- Cap how many items a single operation may fetch (40 images per page).
- Prune caches by count *and* by total bytes (400 files / 200 MiB), oldest
  first.

OneNote content search stores decrypted, normalized page text in
`~/.cache/omarchy/note-note-onenote-search.json`. The cache is limited to
3,000 listed pages, 128 KiB of UTF-8 text per page and 16 MiB of serialized
JSON. Cache reads take at most the cap plus one byte. Oversized pages are
left pending and reported in search coverage; text is never silently
truncated and counted as complete. Search does not load image or attachment
resources, execute HTML, or follow links. Indexing reads page HTML through
the existing bounded Graph transport and OneNote permission.

The cache uses `save_private` (0600 atomic replacement) and a separate
0600 `flock` file for transactions between provider processes. A random
`cacheSession` in the provider's token file scopes text and listing caches
to one sign-in; refresh retains it and a new sign-in replaces it. Late jobs
verify their session and page revision before committing. Parallel workers
claim different pages under that lock; claims record the worker PID and a
bounded lease, so a stopped worker cannot block indexing indefinitely. Sign-out removes
the text cache under the lock; late reads cannot recreate it, and delayed
cleanup for an old session cannot delete a new session's cache. Token updates
and logout also share a lock; an in-flight refresh cannot restore a signed-out
account or overwrite a newer sign-in. Saves hold
their cached text for at least 60 seconds against eventually consistent
reads. The index does not copy token-file fields, image bytes or image/object
resource attributes. User-authored text and links remain searchable.

### 7. Anything that decodes untrusted data gets limits and a timeout

ImageMagick is invoked with
`-limit memory 128MiB -limit map 256MiB -limit area 50MP -limit width 16000
-limit height 16000 -limit time 20`, on the **first frame only** (`file[0]`),
with `subprocess.run(..., timeout=…)`, and a remotely declared width clamped
to a sane maximum before it is used.

### 8. Shell commands take arguments, never interpolation

`["sh", "-c", '… "$1" …', "sh", path]` — the path is an argument, never
spliced into the script text. `--` ends option parsing so a file named `-rf`
is a file.

### 9. A path is not a file: open without following, check the type, race a deadline

`head`/`open()` on a user-writable path follows symlinks (a link in ~/Notes
would read out any file the user can) and blocks on a FIFO (the reader hangs
until a writer appears). The safe shape is `lib/readfile.py`, used for every
local-file read:

- one `os.open()` with `O_NOFOLLOW` (the kernel refuses a symlink) and
  `O_NONBLOCK` (a FIFO's open returns instead of waiting);
- `fstat` **the descriptor** and refuse anything that is not a regular file;
- read at most cap+1 bytes from that same descriptor (rule 1) against a
  `time.monotonic()` deadline, so nothing here can hang the caller.

The listing applies the same policy to what it shows at all: a symlinked note
or notebook is not listed (`providers/local/list.py`).

---

## Review history (marketplace issue #1569)

Reviewers: **HANCORE-linux**, **ryanrhughes**. Every finding was reported
against an exact commit; each fix shipped as a release.

| # | Finding (paraphrased) | Fixed in | Rule |
|---|---|---|---|
| 1 | Local note/state files materialised wholesale through `FileView`; Graph JSON/HTML/error bodies and images read with no byte ceiling; results retained again by `StdioCollector`s | v2.0.1 (`e5fcace`) | 1 |
| 2 | The local fix was still *check-then-reopen*: `stat` then hand the mutable path to `FileView` | v2.2.0 (`fdf0758`) | 1 |
| 3 | Credential writers used a predictable `path + ".new"` opened `O_TRUNC` (symlink-redirectable); the Notion secret and save payloads passed through fixed paths falling back to `/tmp` | v2.3.0 (`75aaf49`) | 2, 3 |
| 4 | Sticky Notes started the process and wrote *before* enabling stdin — the reverse of the bounded sequence | v2.3.1 (`7074390`) | 3 |
| 5 | OneNote `<img src>` passed straight to `urllib` **with the bearer token**, no scheme/host/redirect validation (SSRF); image and remote width handed to ImageMagick with no pixel/memory ceiling or timeout | v2.3.2 (`a2b0712`) | 4, 6 |
| 6 | `open(..., timeout=60)` has no wall-clock deadline (drip-feed keeps a fetch alive); image cache had only a per-file cap, no item or total-byte ceiling | v2.5.0 | 5 |
| 7 | Note/state readers ran `head` on mutable paths: a symlink discloses another user-readable file, a FIFO blocks the reader forever | v2.9.0 | 9 |

Pattern worth noticing: **three of the six were the same mistake in a new
place.** After fixing one, grep for the shape of it everywhere else before
replying to the reviewer.

---

## Pre-release checklist

- [ ] Every new file read goes through `lib/readfile.py` (no `stat` + open, no
      `FileView` read, no `head` on a mutable path).
- [ ] Every new HTTP call has a byte ceiling *and* a deadline; every loop over
      pages has a collection cap.
- [ ] Every new file write uses `mkstemp` + `replace`, 0600, in a 0700 dir.
- [ ] No payload, secret or note body is written to `/tmp` or
      `$XDG_RUNTIME_DIR`; scripts receive them on stdin with the four-step
      sequence.
- [ ] No URL derived from remote content is fetched with a credential unless
      it passes an allow-list; redirects refused.
- [ ] Any new subprocess has `timeout=`, resource limits, and arguments passed
      as argv (never string interpolation).
- [ ] New caches are pruned by count and bytes.
- [ ] Any new rate/pacing state under `~/.cache/omarchy/note-note-rate/` keeps
      the same shape as the rest: 0700 dir, 0600 files, `mkstemp` + `replace`,
      and read with a byte ceiling (`ratelimit.MAX_STATE_BYTES`) — a budget
      that cannot be read must fail *open*, never block the request.
- [ ] `omarchy plugin validate .` passes; `README` "Limits" and this file are
      updated if the numbers changed.
- [ ] Nothing new runs while the window is hidden — with the one sanctioned
      exception, a queued **write** draining (see
      [business-requirements.md](business-requirements.md)). Reads, polls and
      listings still stop. A new *read* that survives a hide is a regression;
      a save that does not is also a regression.

## Threat model, briefly

- **Assumed hostile:** note content from any backend (OneNote/Notion/Graph
  responses, page HTML, image bytes, URLs inside them), and anything on disk
  that another process with the same uid can replace.
- **Trusted:** the user, the shell, the operating system, the vendored
  mistune source.
- **Out of scope:** a compromised local account (same uid can read the tokens
  regardless), and the security of Microsoft's or Notion's own services.
- **Blast radius if we get it wrong:** the user's mailbox token, their
  notebooks, and arbitrary file writes as their user. That is the reason for
  the paranoia above.
