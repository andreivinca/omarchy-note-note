# OneNote section order

Status: **HIGH-RISK WORKAROUND**, implemented and live-verified on 2026-09-05.
This is not a supported Graph section-order API. Local/manual ordering is
explicitly outside the solution.

## Risk classification

High compatibility and maintenance risk. The implementation relies on:

- OneDrive continuing to expose the notebook's `.onetoc2` metadata.
- A custom, partial parser of documented binary formats, including the cloud
  download envelope observed during testing.
- An observed personal Graph/OneDrive ID mapping that is **not guaranteed by
  an API contract**. Successful checks on this account do not establish
  support for every account or future Microsoft behavior.

Microsoft-side changes can cause incorrect ordering or make custom ordering
unavailable without any change to this code. Bounds, validation and regression
tests do not eliminate that compatibility risk. The workaround reads metadata
only; this classification is not a claim of a known security vulnerability or
a remote note-writing operation. Detected failures sort the affected notebook
alphabetically and report a warning; no stale custom sequence is retained.

Keep the workaround visibly marked at its entry point, parser and ID mapping.
Replace it with a supported section-order API if one becomes available; do not
broaden the inferred mapping or guess unsupported binary encodings.

The reference clipboard image shows Family Notebook in this order:
Welcome, Household, Food, Vacation, Health. Graph's section endpoint returns
an alphabetical sequence; OneDrive's remote TOC supplies the missing order.

## Live results

Read-only checks used the existing OneNote sign-in and Family Notebook.

| Request | Result |
| --- | --- |
| `/v1.0/me/onenote/notebooks/{id}/sections` | Food, Health, Household, Vacation, Welcome |
| Same endpoint with `$orderby=order` | 400: property `order` does not exist on `microsoft.graph.onenoteSection` |
| `/beta` equivalent with `$orderby=order` | Same 400 |
| Notebook with `$expand=sections` | Same alphabetical sequence |
| Sections with `$select=id,displayName,order` | 400: unknown property |
| Sections with `pagelevel=true` | 502; inconclusive |
| Sections without `$select` | No position/order field in the returned objects |
| Legacy `www.onenote.com/api/v1.0` and `/api/beta` sections | 401 with the Graph token; cannot evaluate ordering with this authorization |
| Token request for `https://onenote.com/Notes.Read` using existing refresh grant | 400 `invalid_scope` (AADSTS70011) |
| `/me/drive/items/{inferred-notebook-item-id}` | 403 `accessDenied` with current `User.Read Notes.ReadWrite` scopes |

Creation timestamps also do not reproduce the reference order.

## The actual stored order

Microsoft's file-format specification defines
[`NotebookElementOrderingID`](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-one/016ed9d8-8393-471e-a4d2-146d092fa6fa)
as the section's order number. It belongs to each
[`jcidPersistablePropertyContainerForTOCSection`](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-one/6c1dd264-850b-4e46-af62-50b4dba49b62)
in the notebook's `.onetoc2` table of contents. Entries also carry the
section's file identity, filename and color.

After the user consented to `Files.Read`, the notebook package exposed an
`Open Notebook.onetoc2` file. Its current TOC entries give Welcome 1,
Household 2, Food 3, Vacation 4 and Health 5: exactly the reference image.
It also contains historical/deleted entries, so sorting the TOC alone is
incorrect. The provider joins filenames to live OneDrive children, whose
IDs match the live Graph section IDs after adding the personal `0-` prefix.

Graph documents [listing children of package items](https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0),
and OneNote notebooks have a [package facet](https://learn.microsoft.com/en-us/graph/api/resources/package?view=graph-rest-1.0).
The endpoint requires `Files.Read` at minimum, which
covers the user's OneDrive files, not only notebooks.

Delegated [dynamic consent](https://learn.microsoft.com/en-us/entra/identity-platform/consent-types-developer#incremental-and-dynamic-user-consent)
allows the application to request this scope during sign-in without a manual
app-registration permission edit (tenant consent policies still apply).

## Implementation and limits

- `providers/onenote/toc.py`: standard-library reader for the TOC's
  [packaged file format](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-onestore/a2f046ea-109a-49c4-912d-dc2888cf0565),
  including the desktop-header envelope seen in live OneDrive downloads.
  Reads the current revision, inherits unchanged older objects and rejects
  malformed, unsupported, cyclic or excessive structures.
- `providers/onenote/section_order.py`: verifies personal notebook package
  identity, walks ordered section-group folders, and joins only live IDs.
  Downloads metadata from signed Microsoft URLs without the bearer token,
  redirects or logging credentials. Parsed entries are reused by TOC eTag;
  no note bodies or manual order are stored by this feature.
- `onenote.py` preserves parsed metadata through partial listing checkpoints.
  Its independent alphabetical fallback wraps even the optional imports and
  initialization. It accepts only a permutation of the original Graph sections;
  optional code cannot replace section data or membership. Graph remains
  authoritative for page order. The previous fallback cache policy is invalidated.
  Optional stdout is discarded so even a print-then-exit failure cannot corrupt
  the provider's JSON reply or expose its exception payload.
- `section_order.py` requires a position for every live child and matching
  IDs/names for every Graph section. Order numbers may repeat or skip, as the
  web client writes both; equal numbers keep the order the TOC lists them in,
  since OneNote's own tie-break is undocumented. A failed notebook, malformed
  response, parser error or unexpected exception produces alphabetical order
  and a warning. Failed metadata is discarded, not reused as a stale fallback.
- OneDrive metadata has its own rate budget and a 45-second pass budget. It
  receives an existing token snapshot and never refreshes or invalidates the
  normal OneNote sign-in. A metadata throttle does not park the note request lane.
- `Provider.qml` requires only `Notes.ReadWrite`. **Enable custom section order…**
  requests optional `Files.Read` consent without signing out first. Declining,
  cancelling or losing that permission leaves notes accessible alphabetically.
  Token renewal retries required scopes if previously granted optional scopes
  become unavailable; other Microsoft providers retain their existing behavior.
- Synthetic tests cover package encoding, inherited revisions, duplicate
  historical entries, truncation, cycles, groups, deleted sections, cache
  invalidation/pruning, checkpoint page-order preservation, repeated and
  skipped order numbers, several TOC files and URL safety.
  Failure-injection tests cover changed/partial ID mappings, missing positions,
  malformed responses/caches, broken optional imports, unexpected exceptions,
  throttles and loss of consent. QML runtime tests verify that optional consent
  does not hide notes or sign out the account.

Family Notebook matches the screenshot; Family Room also exposes a unique
readable TOC. One older notebook contains both `.onetoc2` and a localized
`Deschidere blocnotes.onetoc2`. Reordering it in the web app (2026-09-08)
rewrote only `.onetoc2`; the localized file is a desktop-client leftover
untouched since 2025. When a folder holds several TOC files the provider
therefore reads the most recently modified one, and reports ambiguity only
when no single newest file exists. Single-section notebooks need no ordering lookup.
Work/school and shared notebooks whose OneDrive item cannot be identified by
the personal-ID mapping use alphabetical section order with an explanatory warning.

## Other interfaces

The [OneNote JavaScript API](https://learn.microsoft.com/en-us/office/dev/add-ins/onenote/onenote-add-ins-programming-overview)
operates inside OneNote's Office add-in runtime. It is not a standalone
REST endpoint the current provider can call. Its section collection is a
potential route to investigate with an add-in, not a verified solution here.

The [desktop Application interface](https://learn.microsoft.com/en-us/office/client-developer/onenote/application-interface-onenote)
exposes the notebook hierarchy through OneNote on Windows. That requires a
running Windows OneNote host outside this Linux provider.

OneNote on the web also has internal browser-session APIs. No authenticated
browser debugging endpoint was available during this investigation, so those
requests and their ordering payloads have not been inspected.
