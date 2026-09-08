# OneNote web search investigation

Investigated on 2026-09-08. **Server search paths found in Microsoft's web
client; successful authenticated replay not yet established.** No provider
implementation was added.

## Finding

OneNote web contains notebook search code that sends a query to an Office
web endpoint and expects page results back. Its section search also calls
a server and expects matching page IDs. There is therefore a concrete
alternative to local indexing, although notebook search was disabled in
the live boot settings for this account.

This establishes what the client requests and consumes. It does not
establish that these endpoints accept Note Note's Graph authentication,
or that the server successfully handles a complete search for this account.
The browser sign-in and web-app launch were reproduced, but no successful
live search response or useful search timing was obtained from either web
endpoint in this pass.

## Source evidence

Public script URLs were identified in the existing Firefox cache. Fresh
copies were then downloaded directly from Microsoft's public CDN:

- [OneNoteDS.box4.dll2.js](https://res.public.onecdn.static.microsoft/officeonline/o/s/h49F8FF6F5203DAFC_App_Scripts/OneNoteDS.box4.dll2.js)
  contains the notebook and section search managers, request construction,
  response handling and result UI.
- [OneNoteDS.js](https://res.public.onecdn.static.microsoft/officeonline/o/s/h49F8FF6F5203DAFC_App_Scripts/OneNoteDS.js)
  contains the shared request manager, authentication header construction,
  service configuration and notebook ID conversion.

The downloaded files' SHA-256 hashes, respectively:

```
a0aece21da9a1d0dd3ed2ac737fbc8072e8611bed992332a4f7ec9a005ec6452
49f8ff6f5203dafc8ec23e1fa5cb3bd2e41dea2a8e9cfe2decc080e2890d9e9c
```

These are versioned implementation artifacts, not supported API contracts.
The relevant symbols are identifiable by their registered names even
though many local identifiers are minified.

### Notebook search

`NotebookSearchManager` debounces a query for 500 ms, then makes a GET to:

```
{WebServiceBase}OneNoteS2SHandler.ashx?action=search&searchquery={query}&fileid={notebookId}
```

It reads `Responses[0]`, checks `StatusCode`, and passes `Results` to the
search UI. The result cache and UI use `PageId` and `PageName`. This code
does not fetch each page's HTML to identify hits.

The manager receives its notebook ID from `App.XVb()`, which calls the
client's provider/file-ID conversion. Mapping returned page identities to
Graph page IDs still needs verification with actual results.

### Section search

`Box4.Search.SearchManager` makes a POST to:

```
{WebServiceBase}OneNote.ashx
```

It builds a `GetCellsRequest` using the section's internal file identity
and encryption-session value, then sets `SearchQuery` and
`NextPageToSearch`. The response handler reads `PageIdsWithHits` and
continues when the response supplies another `NextPageToSearch`.

This is part of Office web's document protocol. It is not equivalent to
posting a Graph section ID and a string to that URL. The complete request
serialization and current session context must be established before a
replay can be considered valid.

## Authentication and live checks

`WebServiceBase` comes from the web app's boot settings. The shared request
manager can attach `X-AccessToken`, `X-AccessTokenTtl`, `X-Key` (canary),
`X-UserSessionId`, routing/build headers, and, depending on feature flags,
`X-WOPISrc` and `X-AADToken`. A bare URL copied from the search manager
therefore omits context the running client can supply.

Read-only requests tested the notebook search handler with no credentials,
with Note Note's Graph bearer, and with partial existing web-session
context, including a variant with the relevant browser cookies. None
returned search results. Direct checks returned redirects to
`/o/error/error.html`; following that redirect produced HTTP 200 containing
an error HTML page. **That 200 is not a successful search.**

These failures do not prove that a complete live browser request would
fail, or identify the missing authentication component. No intact current
browser search request was captured. The existing browser was not exposed
through a debugging connection.

### Follow-up with fresh web authentication

The existing Firefox session did allow a read-only reproduction of the
OneDrive web launch flow:

1. Follow the notebook's Graph-provided web link to the OneDrive host page.
2. Follow the host script's silent sign-in flow for Microsoft's OneDrive
   web client, using `onedrive_implicit.access`. The existing browser
   session returned a web token without another sign-in prompt.
3. Read the notebook item from `api.onedrive.com/v1.0` with `action=view`
   and `$select=id,openWith`. Its `openWith.wac` supplied a document access
   token, expiry, application URL and WOPI source. The corresponding
   request through Graph with Note Note's token returned an empty
   `openWith` object instead.
4. POST the document token to the supplied `onenoteframe.aspx` URL. This
   returned the OneNote application HTML and current boot settings,
   including the canary and session context. The boot access token matched
   the document token returned by the launch API.

The public host implementation is
[wacodcowlhostwebpack.js](https://res-1.cdn.office.net/files/odsp-web-prod_2026-07-10.002/wacodcowlhostwebpack.manifest/wacodcowlhostwebpack.js),
SHA-256 `dbc8448f77dd1bb94b3228b415993c6be840ba6f613387c258b5f0dc6e696895`.
This uses Microsoft's first-party web client and an existing browser
session; it is not a demonstrated sign-in flow for Note Note's registered
application.

The live settings had `OneNoteNotebookSearchIsEnabled` and the alternative
notebook-search flags disabled. A notebook-search replay with the fresh
document token, canary, WOPI source and session/build headers still led to
error HTML. This does not establish that the handler is universally dead.

Section-search replay reached `OneNote.ashx` and received protocol JSON,
but with `StatusCode: 6` (`invalidFileID`) and no cells. The file identity
was constructed from the notebook's WOPI source and a known section item,
so this is not evidence that an actual browser section search would fail.
A root metadata request using the boot-provided `RootFileId` returned
`StatusCode: 14` (`unspecifiedFailure`). Neither is a successful search.
Initialization, section identity and any additional runtime token
requirements remain unresolved.

The request format derived from the client is a JSON group with
`Mode: 1` and `srs: [[1, getCellsRequest]]`; `SearchQuery` is a token array
(for the probe, `["telefon"]`). The service returned UTF-8 JSON prefixed
by a byte-order mark, which must be stripped before parsing. Shared header
helper `dX` removes CR/LF; it does not URL-encode token or canary headers.

Microsoft's [WOPI access-token documentation](https://learn.microsoft.com/en-us/microsoft-365/cloud-storage-partner-program/rest/concepts#access-token)
describes resource-specific tokens supplied by the storage host; a Graph
token must not be assumed interchangeable with one. Graph's
[preview action](https://learn.microsoft.com/en-us/graph/api/driveitem-preview?view=graph-rest-1.0),
which might otherwise provide an Office web launch URL, explicitly does
not support personal accounts.

No notebook content, browser cookies or access tokens were written to
investigation files. Public scripts were saved under `/tmp`.

## Why the OneDrive narrowing route is insufficient by itself

The earlier live test of Graph drive search did find known `.one` sections
for `telefon`, `euro` and `http`. For `telefon`, the two known sections
contained 24 of the account's 268 listed pages. The term was absent from
their filenames, section/notebook names and page titles. Reading the
candidates confirmed two page-body matches.

However, two batches of candidate page reads took **12.07 seconds**:
20 reads succeeded and four returned `503`. This excludes the OneDrive
search and any retries. That is too slow as the normal interactive search
path. A later OneDrive search took **1.88 seconds**, but supplied no page
IDs or snippets; the returned `searchResult` objects were empty.

Reading the two section files directly is also unproven as a speedup.
Search metadata advertised 431,933 and 307,763 bytes, but actual download
range responses reported **2,348,502 and 4,975,879 bytes**. Full downloads
were not completed or parsed. Note Note's existing TOC reader explicitly
does not parse arbitrary page content.

Other limits observed during the probes:

- Common words produced more than 200 drive hits, so pagination is required.
- A request scoped to the notebook returned the same 62 hits as the root
  search for `telefon`; notebook scoping must not be assumed effective.
- Neither completeness nor indexing freshness was established.

## What Windows does

OneNote for Windows maintains local copies of opened cloud notebooks and
syncs changes. Microsoft documents removing that cache by closing a
notebook and restarting, and optionally downloading files and images only
when their pages are opened. Its default search scope is the notebooks
currently open in the app. See
[notebook storage](https://support.microsoft.com/en-us/onenote/manage-notebook-storage-in-onenote)
and [search navigation](https://support.microsoft.com/en-us/onenote/onenote-help-and-learning/navigate-your-notes-with-onenote).

A background text cache is consequently the recommended design for
Note Note. It would move the initial read out of the search interaction
and retain extracted text rather than full notebook files. It still needs
an initial content read, refresh/deletion handling and visible coverage
while incomplete; it is not a way to discover unseen text without reading
it. Implementation was outside this investigation.

## Recommendation and remaining web research

Proceed with the [background text-cache design](onenote-content-search.md#recommended-design--background-text-cache)
for implementation planning. The earlier full-account measurement in that
plan reported 51 seconds to read 268 pages and 83 KB of extracted text.
That is an initial background-sync cost, not the cost of each search;
periodic refresh is still necessary.

If web research continues separately, capture a successful section search
from the running client first. Establish initialization, exact file IDs,
response identities, authentication dependencies and latency. Notebook-wide
search needs an enabled, functioning client path before it can be relied
on. Then determine whether the app can obtain and renew the context without
depending on another browser's existing sign-in.

Do not select query-time page downloads merely because section narrowing
works. Do not promise the internal endpoint as a solution until a complete
search and repeatable sign-in path have both been demonstrated.
