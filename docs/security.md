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
- Applies to files (`head -c "$cap" -- "$file"`), HTTP bodies
  (`read(max + 1)`), and process output.
- `FileView` in QML has no bounded read: it is **write-only** in this project.
  Local notes and the state file are read through a bounded `head -c`.
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

### 7. Anything that decodes untrusted data gets limits and a timeout

ImageMagick is invoked with
`-limit memory 128MiB -limit map 256MiB -limit area 50MP -limit width 16000
-limit height 16000 -limit time 20`, on the **first frame only** (`file[0]`),
with `subprocess.run(..., timeout=…)`, and a remotely declared width clamped
to a sane maximum before it is used.

### 8. Shell commands take arguments, never interpolation

`["sh", "-c", 'head -c "$2" -- "$1"', "sh", path, String(cap)]` — the path is
an argument, never spliced into the script text. `--` ends option parsing so a
file named `-rf` is a file.

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

Pattern worth noticing: **three of the six were the same mistake in a new
place.** After fixing one, grep for the shape of it everywhere else before
replying to the reviewer.

---

## Pre-release checklist

- [ ] Every new file read goes through a bounded single read (no `stat` + open,
      no `FileView` read).
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
- [ ] `omarchy plugin validate .` passes; `README` "Limits" and this file are
      updated if the numbers changed.
- [ ] Nothing new runs while the window is hidden.

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
