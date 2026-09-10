# OneNote content search

OneNote search uses a persistent text cache. Initial indexing runs while the
provider is enabled in the shell, starting with unread pages in the active
notebook. Up to two background jobs each read one page's HTML and extract text
without fetching image or attachment resources. Searches use the cache and
make no Graph requests.

The search panel shows how many listed pages are searchable while indexing
is incomplete. Results update as text arrives. Indexing continues when the
Note Note window is hidden. Shell restarts resume from the saved cache, and
disabling the provider or signing out stops its jobs. Cached search remains
available while Graph requests are throttled.

The initial search scope is all pages in the provider's listing, subject to
the existing 3,000-page listing limit. Notebook tabs show coverage for their
own notebook. A partial or capped listing remains marked incomplete even
when every known page has been indexed. Search covers visible text and link
targets, case-insensitively; it does not add OCR, handwriting recognition or
attachment-content search.

## Refresh and request usage

- Successful page reads and saves update the cached text without another
  request. New pages are added and confirmed deletions remove their text.
  Saves index the validated merged page, including remote edits. An unresolved
  local conflict leaves the index at the fetched remote version. The search
  cache never changes the editor's merge baseline.
- Changed page timestamps trigger another background read. Unchanged entries
  are revisited after seven days because Graph sometimes misses timestamp
  changes. Closed-app time counts toward that interval.
- Failed pages remain pending, with retry delays from five minutes up to one
  day. Existing text survives transient failures; inaccessible or missing
  pages lose their cached text. Incomplete coverage remains visible.
- Indexing yields to interactive queue jobs and runs up to two page jobs at
  a time, leaving the queue's last slot for interactive work. It checks the
  shared request budget with 20 requests reserved in each configured window.
  This reservation pauses indexing alone. Real service throttles still pause
  the provider's normal Graph lane.

Initial download time depends on page count, response times and the available
budget. Indexing accounts for each page request and keeps capacity available
for normal note use.

## Storage and lifecycle

`providers/onenote/search_index.py` owns extraction, cache transactions,
coverage and retry/refresh selection. `SearchCache.qml` schedules work through
the existing request queue and answers searches outside it. Workers claim
distinct pages under the cache lock; abandoned claims become
available when their process exits, with a ten-minute lease as a fallback.
The host uses `searchChanged()` to refresh an open query, with one callback
per search.

The private cache stores only normalized text and index metadata. It is
bounded to 128 KiB of text per page and 16 MiB total JSON. Oversized pages
remain unavailable to full content search rather than being silently cut
short. An account's cache is cleared on sign-out. Token refresh retains it;
a new sign-in starts a new cache. Older unscoped listing caches are rebuilt
once after upgrading. See [security](security.md) for file permissions and
protection against late responses.

`debugState` reports the window state, queue pauses and content-search
counts, worker count and budget delay without exposing note text.
