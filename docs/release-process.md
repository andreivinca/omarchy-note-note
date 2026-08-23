# Release process and marketplace

## Identity

- Repository: <https://github.com/andreivinca/omarchy-note-note> (public, MIT)
- Plugin id: `io.github.andreivinca.note-note` — **permanent**; the
  marketplace never reuses ids, and the id appears in every install command
  and keybind.
- This is a personal project: commits are authored as
  `Andrei Vinca <andrei.vinca@outlook.com>`, with no co-author trailers and no
  reference to any employer.

## Cutting a release

1. Work is committed **only when the author asks for it**.
2. Bump `version` in `manifest.json` (semver: breaking layout/contract change
   → major, feature → minor, fix → patch).
3. `omarchy plugin validate .` must pass.
4. Commit, push to `master`.
5. `gh release create vX.Y.Z --title "Note Note X.Y.Z" --notes "…"` — notes
   are written for users: what changed and what it means, not a commit log.
6. Users update with `omarchy plugin update io.github.andreivinca.note-note`.

Keep the README, `providers/PROVIDERS.md` and `docs/` in the same commit as
the behaviour they describe.

## Marketplace (omarchyplugins.com)

Listing lives in issue
[HANCORE-linux/omarchy-plugin-marketplace#1569](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/1569).

**Flow**

1. A submission issue is filed once with a fixed template (repository URL,
   category, 1–3 tags from their list, maintainer notes, five checklist
   items). Ours: category *Productivity*, tags *quickshell*, *hyprland*,
   suggested tag *notes*. **Never open a second submission** — duplicates are
   rejected.
2. A bot validates the repository structure and Quattro compatibility, and
   runs an automated security baseline, both **at an exact commit**.
3. Human reviewers read the code and post findings, again pinned to a commit
   SHA. The issue carries `needs-fixes` until they clear it.
4. After pushing a fix: reply on the issue with the **new full SHA** and a
   short, factual description of what changed and where. Editing the issue
   body re-triggers the bot.
5. Publication requires a maintainer's `approved-and-verified` label, bound to
   the exact scanned commit. Later updates go through their "verify a newer
   upstream commit" form.

**How to answer a reviewer**

- Short, specific, no marketing. Name the files, name the mechanism.
- Fix the *class* of problem, not the one line they pointed at: three of the
  six findings were the same mistake elsewhere in the code
  ([security.md](security.md)).
- Say what you did not do, if anything, and why.
- Do not argue about severity; their bar is the price of the listing.

Template:

> Addressed at `<full sha>` (vX.Y.Z). `<what changed, mechanism, files>`.
> `<anything intentionally not changed, and why>`.

## Release history

| Version | Substance |
|---|---|
| 1.0.0 | first release: local Markdown notebooks, Sticky Notes, OneNote |
| 1.1.0 | OneNote line breaks and gaps; remote notebooks collapsed by default |
| 2.0.0 | **provider architecture**; per-provider Microsoft sign-in; external providers |
| 2.0.1–2.3.2 | marketplace review fixes: bounded reads, atomic private writes, stdin payloads, image SSRF and decode limits |
| 2.1.0 | Notion provider |
| 2.4.0 | formatting toolbar, word count, empty-checkbox and table fixes |
| 2.5.0 | toolbar keeps undo history; image fetch budget and cache pruning |
| 2.6.0 | create OneNote sections from the sidebar |
