# Note Note

Notes for the Omarchy shell, in the shape of Toolroll: a searchable sidebar of
notebooks on the left, the note on the right — always editable, autosaved.
Local Markdown notebooks, your Microsoft Sticky Notes and your OneNote
notebooks all live in the same list.

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
QML plus a small Python bridge (`lib/msgraph.py`, standard library only) that
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
`~/.local/state/omarchy/note-note-ms-token.json` plus the caches under
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
as Markdown. `Ctrl+B` / `Ctrl+I` / `Ctrl+U` toggle bold / italic / underline
on the selection, or for the text you type next. Underline has no standard
Markdown form; Qt stores it as `_text_` (and italic as `*text*`).

The search field filters notes by title and body. **Detach** turns the overlay
into an ordinary window you can keep open beside your work; **Overlay** brings
it back. Collapsed notebooks and the detached choice are remembered in
`~/.local/state/omarchy/note-note.json`.

## Microsoft Sticky Notes

A virtual "Microsoft Sticky Notes" notebook sits at the end of the list.
Sticky Notes sync into your Outlook mailbox; Note Note reads and writes them
there through Microsoft Graph (`lib/msgraph.py`, Python standard library only)
and keeps only a small cache in `~/.cache/omarchy/note-note-sticky.json`.
Tokens live in `~/.local/state/omarchy/note-note-ms-token.json` (owner-only).

Users just choose `Sign in to Microsoft…` — no setup on their side. The plugin
carries its own app registration (`CLIENT_ID` in `lib/msgraph.py`), made once
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

If you signed in before OneNote support existed, the OneNote notebook shows
`Sign in again to enable OneNote…` — it signs out and back in so the token
gains the `Notes.ReadWrite` scope.

## What it accesses, and why

- **Your notes on disk**: `~/Notes` (or `NOTE_NOTE_DIR`) — read and written as plain Markdown files; nothing else on the filesystem beyond its own state and cache under `~/.local/state/omarchy/` and `~/.cache/omarchy/`.
- **Microsoft account, only after you choose *Sign in***: delegated Graph permissions `Mail.ReadWrite` (Sticky Notes are stored as items in your mailbox's *Notes* folder — Graph has no narrower scope for them), `Notes.ReadWrite` (OneNote) and `User.Read` (to show which account is signed in). The token is stored owner-only at `~/.local/state/omarchy/note-note-ms-token.json`; *Sign out* deletes it. The plugin talks to `login.microsoftonline.com` and `graph.microsoft.com` and nowhere else — no telemetry, no third-party servers.
- The app registration it signs in through is this project's own public client; you can point it at your own registration via `~/.config/omarchy/note-note.json` if you prefer.

## Keys

| Key | Action |
|---|---|
| `Esc` | clear search, else close (saves first) |
| `Ctrl+N` | new note in the current notebook |
| `Ctrl+Shift+N` | new notebook |
| `Ctrl+K` | search |
| `Ctrl+D` | delete current note |
| `Ctrl+B` / `Ctrl+I` / `Ctrl+U` | bold / italic / underline |
| `Ctrl+↓` / `Ctrl+J` | next note |
| `Ctrl+↑` | previous note |
