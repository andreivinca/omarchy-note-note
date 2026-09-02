# OneNote content search

*Status: routes under test, none built. The measurements here are real. The
one thing this document no longer proposes is downloading every page.*

OneNote is the one provider whose notes are searched by title and preview
alone. Everything a user actually wrote — a phone number, a price, a URL, the
line they remember but cannot name — is invisible. On the account this was
measured against, of the 21 pages containing `http`, 18 are reachable *only*
through their body; `kg`, `euro`, `telefon` and `email` are 100% body-only.
Today a search for any of them returns nothing, and the user has no way to
know the note is there.

An earlier draft of this page answered with "fetch every page once into a
local index". That works — it was measured, and the numbers are kept below
because two of the routes that follow reuse them — but it makes the plugin
copy a whole account's notes to disk to answer a two-word search, and it is
rejected as the plan. What follows is every way found to search without
that, in the order they should be tried.

## What is closed, and why

`providers/onenote/Provider.qml` leaves `search()` out and says why: Graph's
pages endpoint has no content-search parameter. Microsoft **had** this for
consumer notebooks, deprecated it, and decommissioned it on **5 May 2024**
so that it deliberately returns `400`. The announcement — *OneNote
get-pages?search API deprecation*, Microsoft 365 Developer Blog, 5 April
2024 — says, in full: *"Today, we are announcing the deprecation of the
OneNote get-pages?search API endpoint supporting consumer Notebooks"*,
*"the endpoint will return a 400 bad request response"*, and *"We do not
currently have a replacement for this endpoint for OneNote."* Questions are
directed to the Microsoft Q&A *Notes* forum. The docs page lost its `search`
row in a pull request the same month with no reason given beyond the
removal. Nothing in the Graph changelog since has reversed it, as of
September 2026.

Everything else that looks like a way in was tried against a live personal
account and is also closed:

| Route | What happens |
|---|---|
| `?search=` / `?$search=`, on `v1.0` **and** `beta` | `400`, code 20108, "unsupported OData query parameters" — all four combinations. Graph's `$search` reference lists message, person and directoryObject collections; pages are not among them |
| `$filter=contains(title,…)` | `400`, code 20266 — a 39-section account is already over the cross-section limit, and it would only see titles anyway |
| Microsoft Search API, `POST /search/query` | `400` — *"This API is not supported for MSA accounts"*. The permissions table still reads *"Delegated (personal Microsoft account): Not supported"* in its July 2025 revision. On work accounts it works, and OneNote hits come back as the notebook's `driveItem` (a `package`), not a page |
| Legacy `www.onenote.com/api/v1.0` | `401` (wrong token audience), and it is the very endpoint that was retired |
| The OneNote Feed, via the Outlook substrate | Searched the mailbox for a word that exists in a page body: five hits, all ordinary mail. The Feed is a *recency* stream of recently edited pages, on first-party endpoints besides |
| `GET /me/onenote/pages/{id}/preview` | Needs the page id already; 300 characters of one known page, not a search |
| Copilot Retrieval API, `POST /beta/copilot/retrieval` | Public preview, August 2026. It **does** index `.one` files for semantic and hybrid retrieval and returns text chunks with no download — but it needs a Microsoft 365 Copilot licence on a work tenant, and *"user-level data sources such as OneDrive aren't available"* on pay-as-you-go. Nothing for personal accounts |

The conclusion to draw is that Microsoft exposes no page-level content
search for personal accounts. The conclusion **not** to draw is that the
plugin therefore has to read every page: the routes below each let a server
say *where* to look, and read only that.

## Route 1 — let OneDrive's search narrow, read only what it names

*Personal accounts. Untested; the probe beside this file settles it.*

Graph's drive search, `GET /me/drive/root/search(q='…')`, is documented for
personal accounts with `Files.Read`, and its `q` is documented as matched
*"across several fields including filename, metadata, and file content"*.
A consumer notebook is a folder in OneDrive and each section is a `.one`
file inside it, so if OneDrive's index reads `.one` content the way it reads
a `.docx`, one request returns the **sections** that hold the words. Whether
it does is the unknown: no Microsoft page says either way, and no report
found settles it.

Two things make the route cheap if it works. The ids already line up: a
personal account's section id, `0-1E92922A0811E22E!358707`, is the
OneDrive item id `1E92922A0811E22E!358707` with `0-` in front, and a
notebook id has the same shape over the notebook's folder — so a drive hit
maps to a section in the listing cache by string comparison, no request
spent. That is read off the id format, not a documented guarantee, which is
why the probe checks it first. And the section is the natural unit to read
next: pages are already listed per section (`onenote.py`,
`section_pages_url`), and `/$batch` carries twenty pages' content per
request, so a search that lands on three sections costs one drive request
and one or two batches, and the bodies land in the `bodies` cache the
provider already keeps. Nothing is fetched before the user asks, and nothing
is kept beyond what the search read.

If OneDrive only names the **notebook** (Graph exposes a notebook as one
`package` item, and its `.one` children may not be searchable one by one),
the same shape narrows to a notebook instead of a section — on this account
17 sections at worst, still a fraction of the 39.

The cost is the scope. `Files.Read` is read access to the whole OneDrive,
not just notebooks; there is no narrower scope the endpoint accepts. So
this is an opt-in — a setting under the OneNote provider, off by default,
that asks for the extra scope at the next sign-in and says plainly why —
and a line in `security.md` before it ships.

**To run the probe** (five minutes, read-only, its own token file so the
app's sign-in is untouched):

```
python3 docs/future/probe-onedrive-search.py login
python3 docs/future/probe-onedrive-search.py search kg euro telefon http --verify
python3 docs/future/probe-onedrive-search.py logout
```

Read the result like this. *Sections in the listing, and `--verify` finds
the term in their pages*: the route works at section grain, build it.
*Notebooks only*: it works at notebook grain, build it with the notebook as
the unit. *Nothing for terms that are certainly in page bodies* (the four
above are): OneDrive does not index `.one` content, and the route is closed
— write that into the table above and move on to route 3.

## Route 2 — work and school accounts have an index already

On a work account the Microsoft Search API answers `driveItem` queries over
OneDrive and SharePoint, whose source is documented as *"files, folders,
pages, and news"*, and a OneNote hit is the notebook item. That is the same
narrowing as route 1 at notebook grain, through a different request, with
`Files.Read.All` or `Sites.Read.All`. It is not a separate design: the hit
→ container → batch shape is one code path with two ways of getting the
hit, and it should be built as one, once route 1 has shown the shape is
worth building.

The Copilot Retrieval API is the only endpoint found that returns OneNote
*text* without a download. It is gated on a Copilot licence and a tenant, so
it stays a note here until a user with such a tenant asks for it.

## Route 3 — ask Microsoft

The retirement post says there is no replacement and points at a forum.
Nobody appears to have asked the question there in a form that can be
voted on: searches of Microsoft Q&A, the Tech Community ideas board and the
Graph docs repository found no tracked request to restore the endpoint. So
the first ask is ours to make. The text is ready in
`onenote-search-request-to-microsoft.md`, with where to post it. The
argument it makes is the one this page makes: without a search endpoint,
every third-party client copies every page of every user to search two
words, which is worse for Microsoft's servers, worse for the user's
privacy, and worse for the throttling budget Microsoft itself set — and
OneNote for the web already searches a notebook stored in OneDrive
server-side, so the index exists.

Even a good answer is months away, so this runs alongside routes 1 and 4,
not instead of them.

## Route 4 — if every door stays shut: search where the user is looking

Reading pages is unavoidable then, but reading *all* of them is not. The
host asks `search()` once the typing pauses and treats the answer as
best-effort. The provider can answer for the scope the user is in — with
notebook tabs on, the open notebook; otherwise the sections the user has
expanded — by batching only those pages' content on demand, streaming hits
back as batches land, and keeping the bodies in the existing `bodies`
cache under the page's `modified` stamp so a second search of the same
place is free. A "Search all notebooks…" action row can offer the rest, as
an explicit act the user pays for knowingly. Nothing is fetched before a
search, nothing is written to disk beyond what the app already caches, and
the batch findings below apply as they stand.

## What the batch measurement taught, kept for routes 1 and 4

`/$batch` carries OneNote page content, twenty pages per HTTP request.
Measured end-to-end on a real account of 268 pages across 39 sections:

- everything, cold: **51 seconds, 14 HTTP requests**
- **83 KB of plain text in total** — around 327 characters a page, less than
  one of the images we already cache
- **0.3 ms** to scan that much text per keystroke, in process
- **zero `429`s**, despite 268 inner requests in 51 s
- 8 × `503`, every one of which succeeded on a single retry, and 1 × `404`
  that was a genuinely deleted page still sitting in our listing cache

The things whoever builds a batch path must know:

**Batch throttle accounting contradicts itself.** Microsoft documents that
"requests in a batch are evaluated individually against the applicable
throttling limits", but 268 inner requests in 51 seconds — a sustained
315/min against a documented 120/min limit — drew no `429` at all. That is
undocumented behaviour and could change without notice. Pace as if each
batch carried its twenty against `RATE_WINDOWS`, and treat the observed
generosity as luck rather than budget.

**`$batch` returns non-JSON bodies base64-encoded.** Page HTML arrives as
base64 inside the batch response. This cost an afternoon, when the
extracted "text" was gibberish and every query silently returned nothing.

**Inner failures need their own retry.** A batch of twenty can come back
`200` with individual `503`s inside it. `ratelimit.attempt_loop` only ever
sees the outer status, so per-item retry has to be written; the eight seen
here all cleared on one attempt.

**`lastModifiedDateTime` is the cache key, and it is not fully trusted.**
`PROVIDERS.md` already calls OneNote's change marker untrustworthy, which is
why `poll()` re-reads the open note. A body cached under a stamp that did
not move when the page did will match the old text. For routes 1 and 4 the
consequence is a missed hit until the page is opened again, which is the
same best-effort the host already expects, not a silently stale index.

**Whatever is read is decrypted note text.** The `bodies` cache is
in-memory today. If any route writes bodies to disk it goes under
`save_private`, is dropped on sign-out with the image cache, and gets its
line in `security.md` first.

## Order of work

1. Run the probe. It decides between route 1 and route 4 for personal
   accounts, and it is the only step that costs nothing to build.
2. Post the request to Microsoft. It costs an afternoon once and nothing
   after.
3. Build the hit → container → batch path for whichever grain the probe
   found, as an opt-in that asks for `Files.Read`; or, if OneDrive does not
   index notebooks, route 4 at the open notebook's scope with no new scope
   at all.
4. Fold work accounts in through the Microsoft Search API once the path
   exists.
