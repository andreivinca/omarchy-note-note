# Note Note — project documentation

These documents are written for whoever works on Note Note next — including
the author six months from now. They record *why* things are the way they
are, and the mistakes that are expensive to repeat.

| Document | Read it when |
|---|---|
| [Business requirements](business-requirements.md) | deciding what the product should or should not do |
| [Technical requirements](technical-requirements.md) | changing the architecture, adding a provider, touching the host |
| [Security rules](security.md) | writing any code that reads a file, spawns a process, or talks to a network — **and before every release** |
| [Engine notes](engine-notes.md) | fighting Qt, QML, Markdown, Graph or Notion; check here before debugging |
| [Testing](testing.md) | verifying a change without a keyboard and without touching real notes |
| [Release process](release-process.md) | cutting a release or answering the marketplace |
| [Decisions](decisions.md) | wondering "why wasn't this done the obvious way?" |

The user-facing documentation is [`../README.md`](../README.md); the provider
contract is [`../providers/PROVIDERS.md`](../providers/PROVIDERS.md).

## The short version

Note Note is an Omarchy shell plugin: a summoned overlay (or a detached
window) with a sidebar of notebooks and one always-editable note. Notes come
from **providers** — local Markdown folders, Microsoft Sticky Notes, OneNote,
Notion, and anything a user drops into
`~/.config/omarchy/note-note/providers/`. The host knows nothing about any
backend; providers know nothing about the UI.

Three rules that everything else follows from:

1. **The user's notes are the product.** Never lose, duplicate or corrupt
   them. When in doubt, open read-only rather than risk a bad write.
2. **Every input is bounded and untrusted** — file, HTTP body, page content.
   See [security.md](security.md).
3. **A provider owns its backend**: its own setup, credentials, caches,
   limits and quirks. The host owns the window, the list and the editor.
