# Asking Microsoft for OneNote content search in Graph

The retirement post for `get-pages?search` (Microsoft 365 Developer Blog,
5 April 2024) says *"We do not currently have a replacement for this
endpoint for OneNote"* and sends questions to the Q&A Notes forum. No
tracked request to bring it back was found on any Microsoft channel as of
September 2026, so this is the first one. Post the idea where it can be
voted on, ask the question where the post told developers to ask, and link
each to the other.

## Where

1. **Microsoft 365 Developer Platform Ideas** —
   https://techcommunity.microsoft.com/idea/microsoft365developerplatform
   The votable board Microsoft's Graph program managers triage. Needs a
   Microsoft account, no support plan. Post the *idea text* below.
2. **Microsoft Q&A, tag "Microsoft Graph Notes API"** —
   https://learn.microsoft.com/en-us/answers/ (ask a question, pick the
   tag). This is the forum the retirement post points at. Post the
   *question text* below, and link the idea so votes land in one place.
3. **Microsoft Feedback Portal, OneNote forum** —
   https://feedbackportal.microsoft.com/feedback/forum/c06dcc30-2e1c-ec11-b6e7-0022481f8472
   The end-user side. A one-paragraph version of the idea, phrased as
   "third-party apps cannot search my notes", reaches the OneNote team
   rather than the Graph team, which is the team that owns the index.

A paid Azure support ticket is not needed for a feature request and would
be answered with "post it on the ideas board" anyway.

## Idea text (Tech Community)

**Title:** Restore server-side content search for OneNote pages in
Microsoft Graph, for personal accounts too

We build an open-source OneNote client for Linux desktops on Microsoft
Graph, using only delegated `Notes.ReadWrite`. Since `get-pages?search`
was decommissioned on 5 May 2024 there is no supported way for an app to
find the OneNote pages that contain a word. `$search` on
`/me/onenote/pages` returns 400 (code 20108), the Microsoft Search API is
"not supported for MSA accounts", and the Copilot Retrieval API needs a
Copilot licence on a work tenant. For a personal account, the only thing
left is to download every page.

We measured what that costs on one ordinary account of 268 pages in 39
sections: 268 page reads through `/$batch`, 14 HTTP requests, 51 seconds,
and the full text of every note written to the user's disk — per app, per
user, per device, repeated to stay fresh. That is 268 requests against the
120-per-minute OneNote budget you set, to answer a search that would be one
request against an index you already have: OneNote for the web searches a
notebook stored in OneDrive server-side today. It is worse for your
servers, worse for the user's privacy, and it is what every third-party
client is now forced to build.

What we ask for, in order of preference:

1. A content search on the pages collection — `GET
   /me/onenote/pages?$search="term"` or `POST /me/onenote/pages/search` —
   returning page ids and titles, for personal accounts as well as work
   accounts, under `Notes.Read`. Snippets and highlights would be welcome
   but ids alone are enough.
2. Failing that, `GET /me/drive/root/search(q=…)` documented to index the
   content of `.one` section files on consumer OneDrive, so an app can at
   least narrow to the section and read only that.
3. Failing that, the Microsoft Search API opened to personal accounts for
   `driveItem`.

A pointer to any of these already existing would do just as well. Thank
you.

## Question text (Microsoft Q&A)

**Title:** Is there any supported way to search OneNote page content
through Microsoft Graph for a personal account?

The April 2024 post retiring `get-pages?search` for consumer notebooks
said there was no replacement and to ask here. Two years on, is that still
the position? Specifically:

- Does any Graph endpoint, v1.0 or beta, return the OneNote pages whose
  content matches a query, for a personal Microsoft account? `$search` on
  `/me/onenote/pages` returns 400 code 20108 and `/search/query` refuses
  MSA.
- Is `GET /me/drive/root/search(q=…)` expected to match text inside `.one`
  section files on consumer OneDrive? The docs say `q` matches "file
  content" but do not say which file types are indexed.
- If neither, is a replacement planned? We have posted the request as an
  idea here: *(link to the Tech Community idea)*.

Without one, an app must read every page of every user to answer a search,
which we have measured at 268 page reads for an ordinary account — and
which seems the opposite of what the OneNote throttling limits are for.
