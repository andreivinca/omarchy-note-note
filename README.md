# Note Note

Notes for the Omarchy shell, in the shape of Toolroll: a searchable sidebar of
notebooks on the left, the note on the right — always editable, autosaved.
Local Markdown notebooks, your Microsoft Sticky Notes, OneNote and Notion pages
all live in the same list.

![Note Note showing a OneNote checklist, with local notebooks, Sticky Notes and the OneNote tree down the left](preview.png)

**[Install](#install)** · **[Removal](#removal)** · **[Notebooks](#notebooks)** ·
**[Microsoft Sticky Notes](#microsoft-sticky-notes)** · **[OneNote](#onenote)** ·
**[Keys](#keys)**

## Install

```bash
omarchy plugin add https://github.com/andreivinca/omarchy-note-note.git
omarchy plugin enable io.github.andreivinca.note-note
```

Plugins land disabled so you can read the code before running it. This one is
QML plus small Python scripts (standard library only) that
talks to Microsoft Graph only after you sign in; like every Omarchy plugin it
runs unsandboxed inside your shell.

Then bind it to a key — Omarchy plugins cannot register a shortcut themselves:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + PERIOD", "Note Note", "omarchy-shell shell toggle io.github.andreivinca.note-note")
```

## Removal

```bash
omarchy plugin remove io.github.andreivinca.note-note
```

Your notes stay in `~/Notes/`. Two files are left behind deliberately because
they are yours rather than the plugin's: `~/.local/state/omarchy/note-note.json`
(layout state) and, if you signed in to Microsoft,
`~/.local/state/omarchy/note-note-ms-*.json` (one per signed-in provider) plus the caches under
`~/.cache/omarchy/note-note-*`. Sign out from the sidebar first to drop the
token, or delete those files by hand.

## Notebooks

Notebooks are folders under `~/Notes/` (override with `NOTE_NOTE_DIR`); notes
are Markdown files inside them. Notes sitting directly in `~/Notes/` show up as
a "Notes" notebook. The filename is just an id — the title is kept in a small
front-matter block at the top of the file:

```
---
title: Shopping
---
milk, eggs
```

A note with an empty title shows the first words of its body in the list.

The sidebar groups notes under collapsible notebook headings (click a heading
to fold it). Each notebook ends with a `+ New note…` row; `+ New notebook…` at
the bottom of the sidebar asks for a name and creates the folder. Drag rows to
reorder within a notebook — the order is kept in that folder's `.order`, and
the notebook order in `~/Notes/.notebooks`. Delete a note with the `×` on its
row (asks for confirmation). Rename or remove a notebook by renaming or
removing its folder.

The body renders Markdown live (headings, lists, emphasis) and is saved back
as Markdown. `Ctrl+B` / `Ctrl+I` / `Ctrl+U` / `Ctrl+S` toggle bold / italic / underline / strikethrough
on the selection, or for the text you type next. Highlight is written as `==text==` (shown with the markers; OneNote and Notion
turn it into their real highlight). Strikethrough is stored as `~~text~~`; underline has no standard
Markdown form and is stored as `_text_` (italic as `*text*`).

The search field filters notes by title and body. **Detach** turns the overlay
into an ordinary window you can keep open beside your work; **Overlay** brings
it back. Collapsed notebooks and the detached choice are remembered in
`~/.local/state/omarchy/note-note.json`.

## Microsoft Sticky Notes

A virtual "Microsoft Sticky Notes" notebook sits at the end of the list.
Sticky Notes sync into your Outlook mailbox; Note Note reads and writes them
there through Microsoft Graph (`providers/sticky/sticky.py`, Python standard library only)
and keeps only a small cache in `~/.cache/omarchy/note-note-sticky.json`.
Its token lives in `~/.local/state/omarchy/note-note-ms-sticky.json` (owner-only),
separate from OneNote's.

Users just choose `Sign in to Microsoft…` — no setup on their side. The plugin
carries its own app registration (`CLIENT_ID` in `services/microsoft/msgraph.py`), made once
by the plugin author: Microsoft Entra → App registrations → New registration
with *personal + work accounts*, no redirect URI, *Allow public client flows*
on, and delegated Graph permissions `Mail.ReadWrite`, `User.Read`,
`offline_access`. Registering is free and works with a personal Microsoft
account. (Anyone who prefers their own registration can override it in
`~/.config/omarchy/note-note.json`: `{ "microsoft": { "clientId": "…" } }`.)

Then `Sign in to Microsoft…` shows a device code: open the sign-in page, enter
the code, and the notes appear. Edits autosave online, `New note…` creates a
note in the cloud (stamped as a real sticky note, so the Sticky Notes app picks
it up), and `×` deletes online.

## OneNote

With the same Microsoft sign-in, a single **OneNote** notebook appears in the
sidebar holding your whole OneNote tree: click a notebook to expand its
sections, a section to expand its pages; `New note…` inside a section creates
a page there (`Ctrl+N` on an open page does the same). Expanded items are
remembered. Pages load on demand and are shown as Markdown with real
formatting: checkboxes (OneNote to-do tags — click to toggle), bullet and
numbered lists, headings, bold/italic/underline/strike-through, links, tables,
and OneNote note tags as emoji prefixes (⭐ important, ❓ question, 💡 idea…).
Saving converts the Markdown back to OneNote HTML with the same elements, so
checking a box in Note Note checks it in OneNote. Pages containing images or
attachments are shown (images included) but open read-only ("has images —
edit in OneNote") so a save can never discard them. OneNote colours, fonts and
ink are not represented; links use the editor's default colour. The tree is cached in
`~/.cache/omarchy/note-note-onenote.json` and refreshed in the background (a
full refresh takes ~30 s on an account with dozens of sections).

OneNote has its own sign-in (token in `~/.local/state/omarchy/note-note-ms-onenote.json`),
independent of Sticky Notes. If its token lacks the `Notes.ReadWrite` scope the
notebook shows `Sign in again to enable OneNote…`.

## Notion

A **Notion** notebook lists the pages you share with an integration of your
own: `Set up…` in the sidebar explains the three steps (create an internal
integration at notion.so/profile/integrations, paste its secret, connect pages
to it in Notion). The secret is stored owner-only in
`~/.local/state/omarchy/note-note-notion.json`; `Settings…` changes or removes
it. Pages are shown as Markdown — headings, bullet/numbered lists, to-dos,
quotes, code, dividers, nested blocks, bold/italic/underline/strike/code/links —
and saving replaces the page's blocks. Pages with other block types (images,
tables, databases, embeds…) or more than 300 blocks open read-only. `New note…`
creates a page under the page you are on (Notion's API cannot create top-level
pages); `×` archives a page. Listings are cached for five minutes; `Refresh`
forces a fetch. Limits: 1000 pages, 300 blocks per page, 4 MiB per response.
This provider is new: the API error paths and the block ↔ Markdown conversion
are tested, the full round-trip against a live workspace is not yet — please
report anything odd.

## Providers

Every source of notes is a *provider* — a self-contained folder with a
`Provider.qml` (and whatever scripts it needs) that implements one small
contract: sections and rows for the sidebar, `load` / `save` / `create` /
`remove`, and a few capability flags. The host knows nothing else.

- `providers/local/` — Markdown notebooks on disk
- `providers/sticky/` — Microsoft Sticky Notes (`sticky.py`)
- `providers/onenote/` — OneNote (`onenote.py`, `onenote_md.py`)
- `providers/notion/` — Notion (`notion.py`, `notion_md.py`)
- `services/microsoft/` — the Microsoft sign-in code they share (`Account.qml`,
  `msgraph.py`). Each provider signs in on its own: its own token file and only
  its own scope, so signing out of Sticky Notes leaves OneNote signed in and
  vice versa. Only the code and the app registration are shared.

External providers are picked up from
`~/.config/omarchy/note-note/providers/<id>/Provider.qml` — a plain
`git clone` into that directory is an install. Setup and settings are the
provider's own (it renders its screen in the note pane and keeps its values
and secrets itself). The contract is documented in
[`providers/PROVIDERS.md`](providers/PROVIDERS.md); `examples/hello/` is a
minimal provider to start from.

## Dependencies

Everything ships with a stock Omarchy install:

- `omarchy-shell` (Quickshell) — the plugin is QML loaded by the shell.
- `python3` — standard library only — for the online providers (`services/microsoft/msgraph.py`, `providers/*/*.py`); not used until you sign in. Markdown parsing uses a vendored copy of [mistune](https://github.com/lepture/mistune) (BSD-3-Clause, `services/markdown/mistune/`), so nothing is installed.
- `wl-copy` (copy the sign-in code) and `xdg-open` (open the sign-in page) — used by the two buttons on the sign-in screen.
- ImageMagick (`magick`) — optional; when present, OneNote page images are downscaled to the size OneNote declares. Without it they are shown at full resolution.

No sudo or pkexec is required, no packages are installed, and no user configuration is modified — the plugin writes only its own files under `~/Notes` (your notes), `~/.local/state/omarchy/note-note*` and `~/.cache/omarchy/note-note-*`.

## Staying in sync

Nothing runs while the app is hidden. While it is open:

- Local notebooks are watched with one `inotifywait` process (part of Omarchy's
  base install) — event-driven, no polling, ~4 MB, idle at 0 % CPU. A note
  created, changed or deleted by another program shows up within half a second;
  if it is the note you have open and you have no unsaved edits, it is reloaded
  in place.
- Every 20 s the app asks each online provider to do its cheapest check:
  Sticky Notes re-lists (one request), OneNote re-lists only the sections you
  have expanded (one request each, every 60 s), Notion runs one search (every
  60 s). A page whose modified time moved is fetched again when you open it.
- Opening the app (`SUPER+.`) always re-lists everything that is cheap to
  re-list; the big OneNote listing stays on its ten-minute cache.

## Limits

Each provider bounds what it reads so nothing can balloon the shell's memory:
a local note over 2 MiB is listed but opened read-only with a note saying so;
the folder listing is capped at 4 MiB; Graph responses are read up to 4–8 MiB,
page images up to 20 MiB, lists up to 500 sticky notes / 500 sections / 3000
pages; a sticky note's text is kept to 256 KiB. The plugin's own state file is
ignored if it exceeds 1 MiB. The numbers live at the top of each provider's
files.

## What it accesses, and why

- **Your notes on disk**: `~/Notes` (or `NOTE_NOTE_DIR`) — read and written as plain Markdown files; nothing else on the filesystem beyond its own state and cache under `~/.local/state/omarchy/` and `~/.cache/omarchy/`.
- **Microsoft account, only after you choose *Sign in***: delegated Graph permissions `Mail.ReadWrite` (Sticky Notes are stored as items in your mailbox's *Notes* folder — Graph has no narrower scope for them), `Notes.ReadWrite` (OneNote) and `User.Read` (to show which account is signed in). Each provider keeps its own token, owner-only, under `~/.local/state/omarchy/note-note-ms-<provider>.json`; its *Sign out* deletes only that one. The plugin talks to `login.microsoftonline.com` and `graph.microsoft.com` and nowhere else — no telemetry, no third-party servers.
- The app registration it signs in through is this project's own public client; you can point it at your own registration via `~/.config/omarchy/note-note.json` if you prefer.

## Keys

| Key | Action |
|---|---|
| `Esc` | clear search, else close (saves first) |
| `Ctrl+N` | new note in the current notebook |
| `Ctrl+Shift+N` | new notebook |
| `Ctrl+K` | search |
| `Ctrl+D` | delete current note |
| `Ctrl+B` / `Ctrl+I` / `Ctrl+U` / `Ctrl+S` | bold / italic / underline / strikethrough |
| `Ctrl+Shift+H` | highlight the selection (`==text==`) |
| `Ctrl+↓` / `Ctrl+J` | next note |
| `Ctrl+↑` | previous note |
