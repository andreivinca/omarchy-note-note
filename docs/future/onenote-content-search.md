# OneNote content search

*Status: investigated on 2026-09-08; background text caching is now implemented
on branch `1.0.13`. See [implemented behavior](../onenote-search.md). OneDrive
section narrowing works, but reading its 24 candidate pages took 12 seconds
and left four transient failures. [The web-search investigation](onenote-web-search-investigation.md)
found server search code paths, but a successful authenticated request and
a maintainable sign-in path have not been demonstrated.*

Before this implementation, OneNote notes were searched by title and preview
alone. Everything a user actually wrote — a phone number, a price, a URL, the
line they remember but cannot name — is invisible. On the account this was
measured against, of the 21 pages containing `http`, 18 are reachable *only*
through their body; `kg`, `euro`, `telefon` and `email` are 100% body-only.
Those body-only searches returned nothing, with no way to
know the note was there.

The important distinction is when content is read. Fetching pages after
the user types makes search slow. Reading them in the background, retaining
the extracted text across restarts, and refreshing it makes subsequent
searches local. OneNote for Windows also caches opened cloud notebooks;
Microsoft documents that behavior in its
[storage guidance](https://support.microsoft.com/en-us/onenote/manage-notebook-storage-in-onenote).

A text cache does need an initial content read for every page it covers.
It does not need to download image or attachment resources. The earlier
measurement below reported 51 seconds for 268 pages and 83 KB of extracted
text; this was not repeated during the latest investigation and is not a
promised sync time. The alternatives below explain why a faster online
search route has not yet replaced that recommendation.

## What is closed, and why

The provider previously omitted `search()` because Graph's
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

No supported page-level content search for personal accounts was found.
This does not prove that local caching is the only possible approach:
OneDrive can narrow candidate sections, and the first-party web client
contains separate server search paths. Neither currently gives Note Note
a verified, responsive page-search integration.

## Route 1 — OneDrive can narrow, but candidate reads are too slow

*Verified on one personal account; unsuitable by itself for interactive
search. See the [measurements and limits](onenote-web-search-investigation.md#why-the-onedrive-narrowing-route-is-insufficient-by-itself).*

Graph's drive search, `GET /me/drive/root/search(q='…')`, is documented for
personal accounts with `Files.Read`, and its `q` is documented as matched
*"across several fields including filename, metadata, and file content"*.
A consumer notebook is a folder in OneDrive and each section is a `.one`
file inside it, so if OneDrive's index reads `.one` content the way it reads
a `.docx`, one request can return the **sections** that hold the words.
The live `telefon` test returned two known sections and confirmed two
page-body matches. Coverage, freshness and behavior on other accounts are
not established.

Two things reduce the number of requests. The ids already line up: a
personal account's section id, `0-1E92922A0811E22E!358707`, is the
OneDrive item id `1E92922A0811E22E!358707` with `0-` in front, and a
notebook id has the same shape over the notebook's folder — so a drive hit
maps to a section in the listing cache by string comparison, no request
spent. That is read off the id format, not a documented guarantee, which is
why a provider must validate it. And the section is the natural unit to read
next: pages are already listed per section (`onenote.py`,
`section_pages_url`), and `/$batch` carries twenty pages' content per
request. The batch count depends on how many pages the matching sections
contain. Those bodies could land in the provider's existing `bodies` cache.
This saves repeated reads, but does not solve the measured delay on the
first search of a section.

If OneDrive only names the **notebook** (Graph exposes a notebook as one
`package` item, and its `.one` children may not be searchable one by one),
the same shape narrows to a notebook instead of a section — on this account
17 sections at worst, still a fraction of the 39.

The cost is the scope. `Files.Read` is read access to the whole OneDrive,
not just notebooks; there is no narrower scope the endpoint accepts. The
existing optional section-order integration already uses that permission,
so no additional consent was needed for these probes. Any implementation
must handle accounts that have not granted it. Background page-text
caching can use the provider's existing OneNote permission instead.

The previously referenced `probe-onedrive-search.py` is absent from this
repository. The 2026-09-08 checks used ad hoc read-only requests with the
existing sign-in, which already had `Files.Read` from section ordering.
Finding candidate sections is evidence for narrowing, not an acceptance
test for search performance or completeness.

## Web-client route — return matching page identities from the server

Microsoft's public OneNote web scripts contain a notebook search GET to
`OneNoteS2SHandler.ashx?action=search` and a section search POST to
`OneNote.ashx`. Their response handlers consume page results and
`PageIdsWithHits`, respectively. These avoid the candidate-page download
step in the client.

They use Office web's configured service and request manager, which can
supply document access tokens, canaries and session/routing headers. The
existing browser sign-in did provide a fresh document token and loaded
the web app, but notebook search was disabled in its current settings.
Notebook-search replay returned error HTML; section-search replay returned
a protocol error. No successful search was demonstrated. This route needs
more research before implementation. The
[investigation](onenote-web-search-investigation.md) records the versioned
source, authentication flow, request shapes and remaining checks.

## Route 2 — work and school accounts have an index already

On a work account the Microsoft Search API answers `driveItem` queries over
OneDrive and SharePoint, whose source is documented as *"files, folders,
pages, and news"*, and a OneNote hit is the notebook item. That is the same
narrowing as route 1 at notebook grain, through a different request, with
`Files.Read.All` or `Sites.Read.All`. It is not a separate design: the hit
→ container → batch shape is one code path with two ways of getting the
hit, and could share its implementation. The measured candidate-read delay
means neither is currently recommended as the normal interactive path.

The Copilot Retrieval API is the only endpoint found that returns OneNote
*text* without a download. It is gated on a Copilot licence and a tenant, so
it stays a note here until a user with such a tenant asks for it.

## Route 3 — ask Microsoft

The retirement post says there is no replacement and points at a forum.
Nobody appears to have asked the question there in a form that can be
voted on: searches of Microsoft Q&A, the Tech Community ideas board and the
Graph docs repository found no tracked request to restore the endpoint. So
the request could be made there. The previously referenced
`onenote-search-request-to-microsoft.md` is absent from this repository.
The argument would be the one this page makes: without a public search endpoint,
every third-party client copies every page of every user to search two
words, which is worse for Microsoft's servers, worse for the user's
privacy, and worse for the throttling budget Microsoft itself set. The
web client's server-search code paths are evidence that Microsoft has
implemented another mechanism; successful live behavior and its underlying
index were not established by this investigation.

There is no known response timeline, so this should not hold up a usable
search implementation.

## Recommended design — background text cache

Read the pages in the configured search scope gradually in the background,
starting with the active notebook. Store page IDs and extracted searchable
text on disk so progress survives a restart. Fetch HTML for extraction;
leave image and attachment resources to the existing on-demand loaders.
Full coverage of the selected scope requires eventually reading every
accessible page in that scope.

Search the available text immediately. Show how much of the scope is
indexed while the initial sync is incomplete, and retain failed pages as
pending work. A missing hit during indexing must not look like a complete
search with no matches. Refresh text when a page is read or saved, reconcile
additions and deletions from successful listings, and periodically revisit
older entries because OneNote's modified stamps can miss changes.

Reuse the existing request queue and rate limiter. Background reads must
yield to opening and saving notes, retry transient per-page failures, and
resume unfinished work. Keep the cache private, separate it by account,
and clear it on sign-out through the existing cache-cleanup path.

The current `search(query, cb)` contract accepts exactly one callback;
the earlier suggestion to stream batches of hits is incompatible with it.
Implement local search within that contract. If completing background work
should update an already displayed query, define that invalidation path
explicitly in the host rather than calling the callback repeatedly.

The implementation follows this design for all listed pages and shows
coverage in the search panel. A working web integration could later
complement this cache.

## Earlier full-account batch measurement

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

**A batch does not bypass throttling.** Microsoft documents that
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
not move when the page did will match the old text. Opening the page fixes
only that entry. A persistent search cache also needs a bounded periodic
refresh policy; change stamps alone cannot guarantee fresh results.

**Whatever is read is decrypted note text.** The `bodies` cache is
in-memory today. If any route writes bodies to disk it goes under
`save_private`, is dropped on sign-out with the image cache, and gets its
line in `security.md` first.

## Order of work

1. Implemented in `1.0.13`: background text caching, incomplete-coverage UI
   and periodic refresh. See [current behavior](../onenote-search.md).
2. Implemented: request-queue scheduling, private cache storage and sign-out
   cleanup, with isolated Python and QML regression tests.
3. Keep the web route as a separate research option. Its acceptance criteria
   are a successful search, verified result IDs and latency, and context
   that the app can obtain and renew. A copied browser request alone does
   not establish a maintainable integration.
4. Treat work-account integration separately once a satisfactory search
   design exists. A request to Microsoft can be drafted independently;
   posting it requires the user's authorization.
