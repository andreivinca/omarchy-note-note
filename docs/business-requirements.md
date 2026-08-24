# Business requirements

## What this is

A notes plugin for the [Omarchy](https://omarchy.org) shell: press a key, the
notes are there, keep typing, press Escape. Local notes are Markdown files you
own; the notes you already keep in Microsoft Sticky Notes, OneNote or Notion
appear in the same list instead of in three other applications.

It is a **personal project** by Andrei Vinca, MIT-licensed, published at
<https://github.com/andreivinca/omarchy-note-note> and submitted to the
community marketplace at <https://omarchyplugins.com>.

## Who it is for

- Omarchy / Hyprland users who want notes without leaving the keyboard.
- People whose notes are already scattered across Microsoft or Notion
  accounts and who do not want a fourth silo.
- Plugin authors who want to add their own note source without forking this
  project.

## Goals

1. **Instant.** Summoned from a keybind into an already-running shell process;
   no cold start, no second application.
2. **Never lose a note.** Autosave, no explicit save button, no modal dialogs
   between the user and their text; a note that cannot be written back safely
   opens read-only with a visible reason.
3. **Your files stay yours.** Local notes are plain Markdown in `~/Notes`,
   readable and editable by any other tool, with no database and no lock-in.
   Removing the plugin leaves the notes untouched.
4. **One list for every source.** Local, Sticky Notes, OneNote, Notion — same
   sidebar, same editor, same shortcuts.
5. **Online notes stay online.** Remote notes are read and written through
   their API; nothing is mirrored to disk beyond a small cache.
6. **Extensible by other people.** A provider is a folder with a
   `Provider.qml`; a `git clone` into the providers directory is an install.
7. **Honest about limits.** When something cannot be represented (an image, a
   OneNote ink stroke, a Notion table), say so in the UI instead of silently
   dropping it.

## Non-goals

- **Not a sync engine.** No offline queue, no conflict resolution, no merge.
  If a save fails, the user is told; the note is not queued for later.
- **Not an Obsidian/Notion replacement.** No backlinks, graph view, tags,
  databases, templates or plugins-inside-the-plugin.
- **Not a rich-text word processor.** Fonts, colours, text size and
  hand-drawn ink are outside what Markdown can carry, so they are not offered.
- **No accounts, telemetry or servers of our own.** The only network traffic
  is to the user's own Microsoft/Notion account, after the user signs in.
- **No image upload.** Reading and displaying images is in scope; inserting
  them is not (see [decisions.md](decisions.md)).

## Product decisions worth remembering

| Decision | Why |
|---|---|
| Local notes are one Markdown file per note, in folders | any editor can read them; folders map to notebooks with no metadata of our own |
| The title lives in a small front-matter block, not the filename | renaming a note must not rename a file the user may have linked elsewhere |
| Note order is a `.order` file per folder; notebook order in `.notebooks` | a move must not rewrite every note; sync tools travel with the order |
| Sticky Notes has no title field | Sticky Notes stores the subject as a copy of the first line — a second field would be a lie |
| Sticky Notes are plain text; OneNote and Notion are Markdown | Sticky Notes has no formatting; the others do |
| One notebook open at a time, picked from a tab rail; the user's own files open first | a flat list of every source is unreadable past a few hundred rows, and a tab is a place you go to, not a fold you undo |
| Highlight is shown as `==text==` markers | the editor cannot round-trip a background colour; markers survive editing, colour would not |
| Every provider signs in separately | signing out of OneNote must not sign out of Sticky Notes |
| The app is silent while hidden | no timers, no watchers, no requests unless the window is open |

## Success criteria

- Opening, editing and closing a note never needs the mouse.
- A note edited elsewhere (phone, file manager, another app) shows up while
  the window is open, without a manual refresh.
- A new provider can be written against
  [`PROVIDERS.md`](../providers/PROVIDERS.md) without reading the host's code.
- The marketplace listing stays approved: every review finding is fixed *and*
  written down in [security.md](security.md) so it does not come back.
