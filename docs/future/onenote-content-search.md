# OneNote content search

*Status: idea, not a plan. The measurements here are real; the implementation
is not designed yet.*

OneNote is the one provider whose notes are searched by title and preview
alone. Everything a user actually wrote — a phone number, a price, a URL, the
line they remember but cannot name — is invisible. On the account this was
measured against, of the 21 pages containing `http`, 18 are reachable *only*
through their body; `kg`, `euro`, `telefon` and `email` are 100% body-only.
Today a search for any of them returns nothing, and the user has no way to
know the note is there.

## The backend will never answer this

`providers/onenote/Provider.qml` leaves `search()` out and says why: Graph's
pages endpoint has no content-search parameter. That is correct, and the
reason is worse than a gap in the API. Microsoft **had** this endpoint for
consumer notebooks, deprecated it, and decommissioned it on **5 May 2024**
so that it deliberately returns `400`. Their own announcement: *"We do not
currently have a replacement for this endpoint for OneNote."* The 400 is the
feature working as designed. It is not coming back, and it is not worth
re-testing.

Everything else that looks like a way in was tried against a live personal
account and is also closed:

| Route | What happens |
|---|---|
| `?search=` / `?$search=`, on `v1.0` **and** `beta` | `400`, code 20108, "unsupported OData query parameters" — all four combinations |
| `$filter=contains(title,…)` | `400`, code 20266 — a 39-section account is already over the cross-section limit |
| Microsoft Search API, `POST /search/query` | `400` — *"This API is not supported for MSA accounts"*. On work accounts it works, but returns the `.one` **section file** as a `driveItem`, never a page |
| `GET /me/drive/root/search(q=…)` | `401` — needs a `Files.Read` scope we do not ask for, and would still only resolve to a section file |
| Legacy `www.onenote.com/api/v1.0` | `401` (wrong token audience), and it is the very endpoint that was retired |
| The OneNote Feed, via the Outlook substrate | Searched the mailbox for a word that exists in a page body: five hits, all ordinary mail in Sent Items, no OneNote items. No OneNote-bearing folder exists, hidden or not. The Feed is a *recency* stream — Microsoft: *"Any pages that you've **recently edited** in OneNote appear in your OneNote feed"* — so it cannot hold a whole notebook, and it is first-party UI on internal endpoints besides |

The conclusion to draw is that no server-side content search exists. The
conclusion **not** to draw is that OneNote therefore cannot have content
search.

## The idea: index once, search locally

`PROVIDERS.md` rejects content search for Notion on the grounds that
"fetching every page's blocks per keystroke is not a search". True — but that
is not the only shape available. Fetching every page **once**, into an index
the provider keeps, is a search, and for OneNote it is far cheaper than the
per-keystroke framing suggests.

The thing that changes the economics is that **`/$batch` carries OneNote page
content, twenty pages per HTTP request**. Measured end-to-end on a real
account of 268 pages across 39 sections:

- a cold index of everything: **51 seconds, 14 HTTP requests**
- **83 KB of plain text in total** — around 327 characters a page, less than
  one of the images we already cache
- **0.3 ms** to scan the whole index per keystroke, in process
- **zero `429`s**, despite 268 inner requests in 51 s — see the open question
  below
- 8 × `503`, every one of which succeeded on a single retry, and 1 × `404`
  that was a genuinely deleted page still sitting in our listing cache

The refresh is close to free, because we already have the change signal.
`cmd_onenote_list` selects `id,title,lastModifiedDateTime` per page
(`onenote.py:113`) and persists it. So a re-index knows *which* pages changed
without spending a request to find out; only those pages are re-fetched. The
steady state is a handful of pages, not 268.

Sketched, and no further than sketched: page text lives beside the existing
`ONENOTE_CACHE`, keyed by page id with its `modified` stamp; the cold fill and
the top-ups run as a background trickle through the existing `graph-onenote`
rate lane, never on the keystroke path; `search()` then answers from memory.
This fits the contract as it already stands (`PROVIDERS.md:114`) — the host
asks once the typing pauses, folds the answer into its own title matching, and
treats it as best-effort, which is exactly what a partially-filled index is.
A page not yet indexed simply does not match, and the host already says
nothing either way.

## What is still open

Enough is unknown that this is an idea and not a plan.

**Batch throttle accounting contradicts itself.** Microsoft documents that
"requests in a batch are evaluated individually against the applicable
throttling limits", but 268 inner requests in 51 seconds — a sustained
315/min against a documented 120/min limit — drew no `429` at all. So OneNote
is demonstrably not counting them individually today. That is undocumented
behaviour and could change without notice. Whatever gets built should pace as
if each batch carried its twenty against `RATE_WINDOWS`, and treat the
observed generosity as luck rather than budget.

**Is `lastModifiedDateTime` trustworthy per page?** `PROVIDERS.md:140`
already calls OneNote's change marker untrustworthy, which is why `poll()`
re-reads the open note. If a content edit can leave the stamp untouched, the
index goes stale silently — the one failure mode a user would never diagnose.
A periodic full re-index is the cheap insurance at 51 seconds, but the
question deserves a real answer before it is relied on.

**`$batch` returns non-JSON bodies base64-encoded.** Page HTML arrives as
base64 inside the batch response. This cost an afternoon during the
investigation, when the extracted "text" was gibberish and every query
silently returned nothing. Whoever implements this should expect it.

**Inner failures need their own retry.** A batch of twenty can come back `200`
with individual `503`s inside it. `ratelimit.attempt_loop` only ever sees the
outer status, so per-item retry has to be written; the eight seen here all
cleared on one attempt.

**The index is decrypted note text at rest.** It belongs under the same
`save_private` treatment as the token file, and it needs a line in
`security.md` before it ships. Worth deciding, too, whether it is dropped on
sign-out along with `bodies` and the image cache — it should be.

**Scale.** At the provider's own `MAX_PAGES = 3000` ceiling this is roughly
150 batch requests and about 1 MB of text: still fine, but the cold fill stops
being a 51-second event and becomes something the user can notice, which
argues for the trickle rather than a blocking first run.

## Not worth revisiting

Work and school accounts are a partial exception — SharePoint does crawl
OneNote content, and `/search/query` is available there. It is still only a
route to the `.one` section file, so it narrows to a section and no further,
and it does nothing for the personal accounts this plugin mostly serves.
Building on it would mean a second code path that is worse than the index and
covers fewer users.
