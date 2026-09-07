export const meta = {
  name: 'review-1.0.9',
  description: 'Review the two 1.0.9 commits for hacks, workarounds, duplication, dead code and bugs; adversarially verify every finding; design the proper fix for survivors',
  phases: [
    { title: 'Find', detail: 'eight dimension reviewers over the diff and surrounding code' },
    { title: 'Dedup', detail: 'merge duplicate findings across dimensions' },
    { title: 'Verify', detail: 'three lenses per finding: code trace, design intent, senior reviewer' },
    { title: 'Fix', detail: 'the proper fix for each confirmed finding' },
    { title: 'Critic', detail: 'completeness pass, then the same verification' },
  ],
}

const SP = '/tmp/claude-1000/-home-andrei-Projects-note-note/090228a1-a826-4879-8072-37692cbe5308/scratchpad'
const CTX = `
CONTEXT (read fully before doing anything)
Repository: /home/andrei/Projects/note-note — a QtQuick/QML notes app for the Omarchy shell (Notes.qml is the host, ui/*.qml the widgets, providers/*/Provider.qml the note backends, services/markdown a Python Markdown<->Qt-HTML converter run as a subprocess).
Under review: the two commits on branch 1.0.9, which is also master HEAD: c89fece (save state / provider-owned save schedule / converter JSON framing / list flicker) and a11ea72 (a tab reopens on the note last open in it; OneNote keeps its own per notebook; version 1.0.9). Full patches are saved at ${SP}/c89fece.patch and ${SP}/a11ea72.patch (combined: ${SP}/1.0.9.diff); \`git show c89fece\` / \`git show a11ea72\` work too. The commit messages explain the intent — read them.
Project rules (CLAUDE.md): no spaghetti, no hacky code, no workarounds; if a proper fix requires touching more code, do the proper fix; clean code that is easy to read, understand and change; every if/else/for/while must use braces. NOTE: the existing codebase overwhelmingly uses brace-less single-line ifs; report that discrepancy ONCE as a single style finding if you cover style, never as a per-line list.
Design docs to consult BEFORE calling something a smell (a deliberate, documented decision is not a hack unless it is also wrong): docs/decisions.md (both commits added sections there), providers/PROVIDERS.md (the provider contract), docs/business-requirements.md, docs/technical-requirements.md, docs/testing.md.
Orientation rule from this repo's hooks: run \`graphify query "<your question>"\` once at the start for orientation (it may return little for QML; that is fine), then read the raw files.
Already established (do not re-run): services/markdown/qthtml/selftest.py, providers/local/selftest.py and lib/ratelimit_selftest.py are all green; py_compile ok; qmllint clean; ruff is not installed; \`to-html\` now emits {"html": "..."} including {"html": ""} for empty input.
Findings already in the pool (do NOT re-report these; you may report something adjacent only if it is a distinct defect):
 S1 dead \`readonly property int saveDebounce: 500\` in providers/local/Provider.qml:31 with a near-duplicate comment above the Timer.
 S2 Notes.qml: activeSection starts "" and is only set by setActiveSection/loadState, so openDefaultNote's \`if (key !== root.activeSection) return\` never answers for a user who never switched tabs.
 S3 providers/onenote/Provider.qml noteOpened(): returns before persistRequested() when the page is unchanged, so a changed lastNotebook is not persisted by the provider.
 S4 Notes.qml onRenderFailed is a third copy of the load-failure state transition (reloadCurrent ~L940 and selectPath ~L1124 hold the other two).
 S5 Notes.qml ~L1005: the search auto-pick of the first hit goes through selectPath, so it counts as a real selection (clears defaultOwed, records lastNotes, writes the state file per keystroke, defeating persist:false on L1003).
 S6 double state-file write on an OneNote selection (provider persistRequested -> saveState, then host noteWasOpened -> saveState).
 S7 ui/NoteEditor.qml replaceDoc: \`then\` is never called when the conversion fails; callers at L796/L913/L944 pass one.
 S8 Notes.qml cancelPendingSave comment says "or its provider is going" but only confirmDelete calls it.
 S9 two generation counters for one concept: NoteEditor.noteToken and Notes.noteLoadSeq.
 S10 lastNotes is written for tabs whose provider answers defaultNote itself (never read back) and is never pruned.
STANDARD: report only what you verified by reading the code at HEAD. Every finding must cite file and line at HEAD, quote the code, state the concrete defect (bug, race, hack, workaround, duplication, dead code, comment rot, docs mismatch, naming, design) and either a concrete failure scenario or the concrete cleaner shape. Precision over recall: no speculation, no "consider", no restating the commit's own documented trade-offs as problems. Do not report untouched pre-existing code unless the commit made it worse or a proper fix of what the commit did would have had to include it. Your final output is data for a program, not prose for a person.
`

const FINDINGS = {
  type: 'object', required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'line', 'title', 'category', 'severity', 'claim', 'evidence', 'scenario', 'fix'],
        properties: {
          file: { type: 'string', description: 'repo-relative path' },
          line: { type: 'integer', description: '1-indexed line at HEAD' },
          title: { type: 'string', description: '<= 80 chars, the claim alone' },
          category: { type: 'string', enum: ['bug', 'race', 'hack', 'workaround', 'duplication', 'dead-code', 'comment-rot', 'docs-mismatch', 'naming', 'style', 'design'] },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          claim: { type: 'string' },
          evidence: { type: 'string', description: 'quoted code and the trace that shows it' },
          scenario: { type: 'string', description: 'concrete inputs/state -> wrong outcome, or "n/a" for a pure cleanliness finding' },
          fix: { type: 'string', description: 'the proper fix, not a patch-over' },
        },
      },
    },
  },
}

const DIMENSIONS = [
  { key: 'save-state', prompt: `Dimension: the save state machine in Notes.qml (autosave section ~L1355-1480: onEdited, saveTimer, defaultSaveDebounce, saveEpoch, savesPending, saveRevision, noteLoadSeq, markSaving, cancelPendingSave, flushSave, saveFailed, reportSave), the provider connect block ~L389-400 (saveRequested/noteChanged), selectPath, reloadCurrent, confirmDelete, close(), open(), applyProviderDiff (provider removal), and onRenderFailed. Questions: is every markSaving(+1) balanced on every way out including a provider whose save() throws or never calls back, a provider removed mid-save, a converter that never starts (Markdown.qml run() proc === null path)? Is noteLoadSeq bumped on every load path? Are saveFailed's four conditions each necessary and sufficient — trace the cases: same note reloaded by noteChanged, newer flush, delete, read-only? Does dirty=true after a failed save ever get flushed again without a keystroke (docs say the next flush carries it — is there one)? Can saveTimer (host default) and a provider's own Timer both fire for one edit after switching notes between providers? Any counter that can go negative, any stale entry left in saveEpoch/savesPending for a deleted note? Is anything here a workaround for a problem that has a root fix?` },
  { key: 'converter-framing', prompt: `Dimension: the converter's failure channel. Files: services/markdown/Markdown.qml (toHtml, toMarkdown, run), services/markdown/qthtml/__main__.py, services/markdown/qthtml/selftest.py (does any test drive to-html through __main__ and parse the JSON frame, or is the framing untested?), ui/NoteEditor.qml (requestMarkdown, setNote, showBody, renderFailed, replaceDoc and its callers, atomic, plainText), ui toolbar code that calls toMarkdown/replaceDoc, Notes.qml onRenderFailed. Questions: every caller of toHtml/toMarkdown updated for the new callback shape? Is the identical parse-and-warn block in toHtml and toMarkdown duplication that a shared helper should own? Does run()'s \`callback("")\` for a failed createObject reach both callers correctly? On renderFailed, is the editor left in a consistent state (title set, body empty, readOnly true, noteToken, settingText)? Does the next selectPath reset readOnly and loadFailed? Does the reloadCurrent path (noteChanged) handle a render failure the same way? Is the JSON framing itself the proper fix or a workaround (compare with an exit-code/stderr based channel — the Process type in this shell: what does converter's Component expose; read the Component at the bottom of Markdown.qml)?` },
  { key: 'provider-schedule', prompt: `Dimension: the provider-owned save schedule. Files: providers/local/Provider.qml, providers/notion/Provider.qml, providers/onenote/Provider.qml, providers/sticky/Provider.qml, examples/hello/Provider.qml, providers/PROVIDERS.md, docs/decisions.md ("The host says a note changed"), Notes.qml onEdited/saveTimer/flushSave and the saveRequested connect. Questions: the four providers carry an identical signal+function+Timer block — given how this repo already shares code across providers (services/microsoft, services/requests, lib/), is a shared component (e.g. a SaveSchedule item in services/ or ui/) the proper shape, or is per-provider copy the deliberate contract for copyable external providers? Judge against the repo's own precedent, and cite it. Does examples/hello need the block or a mention? Does PROVIDERS.md describe the contract exactly as the host implements it (which note is answered, what happens to a late request, the 1500 ms default, "the four-line Timer at the head of any Provider.qml")? Is the guard style consistent (\`if (p.saveRequested)\` vs \`typeof p.noteEdited === "function"\`) with how the host treats other optional members? Any comment rot in the touched providers (local's two near-identical comments)? Is there a path where a provider that implements noteEdited still gets the host's saveTimer (e.g. saveTimer running from a previous provider's note)?` },
  { key: 'rows-flicker', prompt: `Dimension: the list flicker fix in Notes.qml rebuildRows (~L800-925) and ui/NoteList.qml. Questions: what do rows contain — could JSON.stringify over them be expensive (do rows carry bodies, previews, notes arrays, images?) given it now runs on every rebuild (six per open)? Is a stringify comparison the proper fix or a workaround for rebuildRows being called six times when nothing changed (should the callers — provider refresh, cached read, listing, account refresh — be coalesced, or should rows be derived from a change signal)? Is the tabs comparison it mirrors the same shape? Is \`keep\` (scroll offset) captured and restored correctly now that restoration is conditional — trace the case where rows changed but the offset should not move, and the case of a tree toggle? Is \`revision\` still doing a job (it is read at L1556/L1600/L1601 as \`root.revision < 0 ? "" : ...\` — a binding-dependency trick) and is rowWrites named/placed well? Is the DelegateModel claim in the comment true (read ui/NoteList.qml)? Any ordering issue: rows compared before sourceName/sourceLogo/sourceBase are updated — can those go stale when rows are equal but the tab colour changed?` },
  { key: 'default-note-host', prompt: `Dimension: the host side of "a tab opens on the note you left in it" in Notes.qml: lastNotes, defaultOwed, noteWasOpened, defaultNoteFor, openDefaultNote, setActiveSection, rebuildRows' call to openDefaultNote, selectPath's defaultOwed/noteWasOpened lines, saveState/loadState version 4, debugState. Also every caller of selectPath and setActiveSection (grep them) — classify each as a user choice or an automatic selection, and check which of the automatic ones now wrongly count as "the user picked" (defaultOwed=false, lastNotes written): search auto-pick (~L1005), confirmDelete's \`selectPath(next)\` (deleting the open note auto-selects a neighbour — is that then remembered as the tab's note?), the noteChanged/vanished path \`selectPath("")\`, moveSelection, revealCurrent, the "home" jump at ~L1220. Questions: the startup case when activeSection is "" (S2 is already in the pool — but check what the proper fix is: should the resolved tab be committed to activeSection on first rebuild, or should openDefaultNote compare against the persisted intent differently?). Re-entrancy: openDefaultNote runs inside rebuildRows and calls selectPath -> flushSave/noteWasOpened/saveState — any state the rest of rebuildRows then reads stale (rows, currentPath, the vanished-note check on the next line)? Is \`String(key)\` coercion needed? Is \`split("/")[0]\` the inverse of sectionKey() written a second time — is there an existing helper? Does loadState validate lastNotes values (strings) consistently with how it validates active/listWidth? Is defaultOwed left true forever for a tab that never lists — any cost beyond a comparison?` },
  { key: 'default-note-onenote', prompt: `Dimension: providers/onenote/Provider.qml: noteOpened, defaultNote, lastNotebook, lastPages, restoreState, saveState, and how sections/keys are built (~L140-185: notebookTabs on -> one section per notebook with key b.id; off -> one section key "onenote"), pageAt, sectionAt, revealPath, expanded/toggleTree, persistRequested. Questions: is \`sectionKey.substring(root.id.length + 1)\` the right inverse of the host's sectionKey() (host: p.id + "/" + s.key) — and does the provider anywhere else already parse or build these keys (a helper it should reuse)? With notebookTabs off, defaultNote ignores its argument — is the argument then a misleading interface, or fine? Does the host's revealCurrent (deferred by openDefaultNote) actually unfold the notebook and section holding the page — read revealPath — and is the "unfolded to show it" promise in the commit message and docs/testing.md met for both tab shapes? Are lastPages entries for deleted notebooks/pages ever pruned, and does a stale path cause anything worse than an empty tab (host checks noteExists)? Is restoreState's validation consistent with the rest of the provider? Does noteOpened's early return skip persisting a changed lastNotebook (S3 is in the pool — confirm and describe the correct minimal shape)? Is the state written twice per selection (S6 in pool — confirm which call orders and how many writes)? Also check providers/PROVIDERS.md's description of noteOpened/defaultNote against this implementation and the host.` },
  { key: 'style-comments-docs', prompt: `Dimension: cleanliness of the two commits as text: naming, comments, docs. Read every hunk of both patches with these questions. (1) Comments that narrate history ("used to", "This is where the app used to decide the opposite", "the two used to be the same number") — comment rot risk; list them with the line and say what the comment should say instead (present-tense intent). (2) Duplicated or near-duplicated comment paragraphs (the same schedule paragraph in four providers; local's two). (3) Names: defaultOwed, noteWasOpened (host) vs noteOpened (provider), markSaving, rowWrites, saveEpoch vs noteLoadSeq vs noteToken — are they clear and consistent with the repo's naming? (4) docs/testing.md and providers/PROVIDERS.md and docs/decisions.md: every concrete claim (numbers, function names, "at the head of any Provider.qml", "500 ms for a local note", "the host never falls back", "asked on every rebuild") checked against the code at HEAD; report mismatches. (5) The CLAUDE.md braces rule vs the codebase's convention: report once, with a count of brace-less control statements added by these two commits (use grep on the patches' added lines) and a count in the pre-existing Notes.qml, so the user can decide. (6) Any debug-only surface (debugState fields) that leaks implementation detail unnecessarily. Category for (1)-(2) is comment-rot/duplication, (3) naming, (4) docs-mismatch, (5) style.` },
  { key: 'hack-hunter', prompt: `Dimension: you are the reviewer whose one question is "is this a workaround for a problem whose root should have been fixed?" Read both patches and the code around every hunk. Candidates to judge (do not report them just because they are listed; report only those you conclude are workarounds, with the root fix): JSON.stringify equality on rows and tabs instead of fixing why rebuildRows runs six times; defaultOwed re-asked on every rebuild (polling on rebuild) instead of answering when the tab's provider finishes listing; Qt.callLater in openDefaultNote and rebuildRows; the epoch + noteLoadSeq + loadHandle.cancel() + editor.noteToken layering — four mechanisms for "is this answer still the one we want"; a dirty flag re-raised by saveFailed with nothing scheduled to flush it; the host keeping a saveTimer at all now that providers own the schedule (is the default-path Timer the proper shape or should the host wrap the default into the same contract); the JSON frame as a failure channel versus the process exit code; the \`|| null\` on loadHandle; the \`if (p.saveRequested)\` feature test; \`String(key)\`. For each reported item give the root cause, the proper fix, and honestly whether the proper fix is proportionate (CLAUDE.md says do it even if it touches more code, but it must still be the right design for this app — read docs/decisions.md and docs/technical-requirements.md first).` },
]

const VERDICT = {
  type: 'object', required: ['refuted', 'confidence', 'reasoning', 'severity'],
  properties: {
    refuted: { type: 'boolean', description: 'true if the finding is wrong, not a real defect, or deliberate-and-defensible' },
    confidence: { type: 'number', description: '0..1' },
    reasoning: { type: 'string', description: 'the trace or the doc citation that decides it' },
    severity: { type: 'string', enum: ['high', 'medium', 'low', 'none'] },
    corrected_claim: { type: 'string', description: 'the claim as it should be stated if it survives (may equal the original)' },
  },
}

const LENSES = [
  { key: 'trace', effort: 'high', prompt: (f) => `Lens: CODE TRACE. Try to REFUTE this finding by tracing the code at HEAD line by line. Does the defect actually exist as stated? Reproduce the scenario mentally with concrete state; if the scenario cannot happen, or the code already handles it, or the cited lines say something else, refute. Default to refuted=true if you cannot confirm it from the code.\n\nFINDING\n${JSON.stringify(f, null, 2)}` },
  { key: 'intent', effort: 'high', prompt: (f) => `Lens: DESIGN INTENT. Try to REFUTE this finding by reading docs/decisions.md, providers/PROVIDERS.md, docs/business-requirements.md, docs/technical-requirements.md, CLAUDE.md and the two commit messages. Is the reported behaviour a deliberate, documented decision that is also defensible for this app? If yes, refute. If it is deliberate but the decision itself is wrong or contradicts another stated rule, do not refute — say which rule. Also judge severity as this project would (it promises never to lose a note; a state-file oddity is low, a wrong note opening is medium, a lost or blanked note is high).\n\nFINDING\n${JSON.stringify(f, null, 2)}` },
  { key: 'senior', effort: 'high', prompt: (f) => `Lens: SENIOR REVIEWER. You are reviewing this PR for a codebase whose rules are: no hacks, no workarounds, no spaghetti; do the proper fix even if it touches more code; code easy to read and change. Read the cited code and enough around it. Would you ask for a change here, and is the finding's proposed fix the proper one or itself a patch-over? Refute if you would let the code through as is (a matter of taste with no concrete defect, or a fix that is worse than the code). Do not refute merely because the defect is small — small dead code and comment rot are still changes you would ask for.\n\nFINDING\n${JSON.stringify(f, null, 2)}` },
]

const FIX = {
  type: 'object', required: ['fix_summary', 'files', 'sketch', 'risk', 'scope'],
  properties: {
    fix_summary: { type: 'string' },
    files: { type: 'array', items: { type: 'string' } },
    sketch: { type: 'string', description: 'the code as it should read after the fix, per file, enough to apply' },
    risk: { type: 'string', description: 'what could regress and how to check it (cite docs/testing.md checklists where they apply)' },
    scope: { type: 'string', enum: ['local', 'touches-more-code'] },
  },
}

const seeds = [
  { id: 'S1', file: 'providers/local/Provider.qml', line: 31, title: 'Dead saveDebounce property left beside the Timer that replaced it', category: 'dead-code', severity: 'medium', claim: '`readonly property int saveDebounce: 500` is read by nothing (grep: only this line and a docs/decisions.md paragraph that REJECTS the idea). The comment above it is a near copy of the comment above `signal saveRequested`, so the number 500 and its rationale live twice.', evidence: 'providers/local/Provider.qml L28-31 and L33-43; grep -rn saveDebounce shows no reader.', scenario: 'n/a — the Timer interval and the property can drift apart silently.', fix: 'Delete the property and its comment; keep the one comment over the Timer.' },
  { id: 'S2', file: 'Notes.qml', line: 688, title: 'Remembered note never opens at startup for a user who never switched tabs', category: 'bug', severity: 'medium', claim: 'activeSection is "" until setActiveSection or loadState sets it; a user who only ever used the first (fallback) tab persists active:"" and lastNotes keyed by activeKey() (the resolved key). openDefaultNote requires activeKey() === activeSection, which is never true for "", so the note they left open is never reopened.', evidence: 'Notes.qml L688 `if (key !== root.activeSection) return`; L701 `property string activeSection: ""`; only writers L741 and L1502; noteWasOpened L52 keys by activeKey().', scenario: 'Fresh install, local provider only, open note X, restart: the tab opens empty although lastNotes["local/…"] = X.', fix: 'Commit the resolved tab once it is known (or compare against the resolved intent) — decide the clean shape.' },
  { id: 'S3', file: 'providers/onenote/Provider.qml', line: 205, title: 'noteOpened skips persisting a changed lastNotebook when the page is unchanged', category: 'bug', severity: 'low', claim: 'lastNotebook is assigned before the early return `if (root.lastPages[sec.notebookId] === path) return`, so when the page was already the remembered one for its notebook but lastNotebook changed, persistRequested() is not emitted.', evidence: 'providers/onenote/Provider.qml noteOpened().', scenario: 'notebookTabs on: open page X in notebook A, page Y in notebook B, then X again; the host writes nothing either (lastNotes["onenote/A"] already X). Flip notebookTabs off later: the tree tab opens Y (B) instead of X (A).', fix: 'Return early only if neither value changed.' },
  { id: 'S4', file: 'Notes.qml', line: 1725, title: 'onRenderFailed is a third hand-written copy of the "note could not be opened" transition', category: 'duplication', severity: 'medium', claim: 'reloadCurrent (L940) and selectPath (L1124) each set loadingNote=false, loadFailed=true (and one shows status); onRenderFailed adds a third variant with dirty=false and readOnly=true. Three places encode one state transition with slightly different fields.', evidence: 'Notes.qml L940, L1124, L1720-1730.', scenario: 'n/a — the next change to what a failed load means must be made in three places.', fix: 'One function (e.g. noteUnavailable(message)) that all three call.' },
  { id: 'S5', file: 'Notes.qml', line: 1005, title: 'Search auto-pick counts as a user choice: clears defaultOwed, records lastNotes, writes state per keystroke', category: 'bug', severity: 'medium', claim: 'The search landing selects the first hit automatically via selectPath, which now sets defaultOwed=false and calls noteWasOpened -> saveState(). This records a note nobody chose as the tab\'s remembered note and writes the state file on each keystroke that changes the first hit — the very cost persist:false on L1003 exists to avoid.', evidence: 'Notes.qml L1000-1006, L1093-1099, noteWasOpened L49-60.', scenario: 'Type a query whose first hit is Z; clear the search; restart: the tab opens on Z although the user never opened it.', fix: 'Separate "the user chose" from "a note was shown" — e.g. selectPath(path, chosen) or a distinct entry point for automatic selections.' },
  { id: 'S6', file: 'Notes.qml', line: 49, title: 'Two state-file writes per OneNote selection', category: 'design', severity: 'low', claim: 'noteWasOpened calls owner.noteOpened(path) which emits persistRequested (-> root.saveState()), then updates lastNotes and calls saveState() again.', evidence: 'Notes.qml L49-60, provider connect L388 `p.persistRequested.connect(function() { root.saveState() })`, providers/onenote/Provider.qml noteOpened.', scenario: 'Every OneNote page selection rewrites the state file twice.', fix: 'Order the two so one write covers both, or let the host write once after the provider was told.' },
  { id: 'S7', file: 'ui/NoteEditor.qml', line: 438, title: 'replaceDoc never calls `then` when the conversion fails', category: 'bug', severity: 'low', claim: '`if (!ok) return` skips both the document replacement and the continuation; callers that pass `then` (L796, L913, L944) may be left waiting.', evidence: 'ui/NoteEditor.qml L435-445 and callers.', scenario: 'Converter fails during a toolbar block operation: whatever the continuation was meant to do (selectBlock, focus) never happens, and the user is told nothing.', fix: 'Decide: report the failure via statusRequested and/or call then(false); verify what each caller needs.' },
  { id: 'S8', file: 'Notes.qml', line: 1409, title: 'cancelPendingSave comment promises a caller (provider going) that does not exist', category: 'comment-rot', severity: 'low', claim: 'The comment says the function is for a note "being deleted, or its provider is going"; only confirmDelete calls it. applyProviderDiff / provider removal does not cancel pending conversions.', evidence: 'grep cancelPendingSave: L1275 (confirmDelete) and the definition.', scenario: 'A provider removed via settings while a conversion for its note is running: the conversion answers, epoch matches, p.save is called on a provider object that is being destroyed.', fix: 'Either call it where providers are removed (and verify that is safe) or fix the comment.' },
  { id: 'S9', file: 'Notes.qml', line: 1394, title: 'Two generation counters for one concept: NoteEditor.noteToken and Notes.noteLoadSeq', category: 'design', severity: 'low', claim: 'The editor already numbers loads (noteToken, "a newer note won the race"); the host adds noteLoadSeq for the same purpose at its own layer. Two counters bumped in different places for one question.', evidence: 'ui/NoteEditor.qml L141-169, Notes.qml L936/L1107/L1394/L1424/L1470.', scenario: 'n/a — a future load path that bumps one and not the other silently breaks saveFailed\'s guard.', fix: 'Decide whether one layer should own it (expose the editor\'s token, or have the editor take the host\'s) or document why two.' },
  { id: 'S10', file: 'Notes.qml', line: 55, title: 'lastNotes stores entries it will never read and never prunes', category: 'design', severity: 'low', claim: 'noteWasOpened writes lastNotes[key] for every tab including OneNote\'s, whose defaultNote answers instead so the host entry is never read; nothing removes entries for tabs that no longer exist (notebookTabs toggles create new keys).', evidence: 'Notes.qml L49-68.', scenario: 'State file grows with dead keys; harmless but untidy.', fix: 'Skip recording when the provider answers itself, or prune to live section keys at save time — or document why not.' },
]

phase('Find')
const found = await parallel(DIMENSIONS.map(d => () =>
  agent(`${CTX}\n\nYOUR DIMENSION\n${d.prompt}\n\nReturn every verified finding for this dimension. An empty list is a valid answer.`, { label: `find:${d.key}`, phase: 'Find', schema: FINDINGS })
))
let pool = seeds.slice()
found.filter(Boolean).forEach((r, i) => {
  (r.findings || []).forEach((f, j) => pool.push(Object.assign({ id: `${DIMENSIONS[i].key}-${j + 1}` }, f)))
})
log(`Find: ${pool.length - seeds.length} new findings from ${found.filter(Boolean).length}/${DIMENSIONS.length} finders, plus ${seeds.length} seeds`)

const DEDUP = {
  type: 'object', required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['ids', 'file', 'line', 'title', 'category', 'severity', 'claim', 'evidence', 'scenario', 'fix'],
        properties: {
          ids: { type: 'array', items: { type: 'string' }, description: 'the input ids merged into this one' },
          file: { type: 'string' }, line: { type: 'integer' }, title: { type: 'string' },
          category: { type: 'string' }, severity: { type: 'string' },
          claim: { type: 'string' }, evidence: { type: 'string' }, scenario: { type: 'string' }, fix: { type: 'string' },
        },
      },
    },
  },
}

phase('Dedup')
const deduped = await agent(`You are merging code-review findings. Below is a list of findings about the same two commits, produced by different reviewers. Merge findings that describe the SAME defect (same root cause at the same place, even if worded differently or cited at neighbouring lines) into one canonical finding that keeps the best evidence and the strongest scenario, lists all merged ids, and takes the highest severity. Do NOT merge findings that are merely about the same file or the same feature. Do not drop anything, do not add anything, do not soften claims. Keep the seed ids (S1..S10) when they are part of a merge. Output the canonical list.\n\nFINDINGS\n${JSON.stringify(pool, null, 2)}`, { label: 'dedup', phase: 'Dedup', schema: DEDUP, effort: 'medium' })
const canon = (deduped && deduped.findings) ? deduped.findings : pool.map(f => Object.assign({ ids: [f.id] }, f))
log(`Dedup: ${pool.length} -> ${canon.length} findings`)

async function verifyAndFix(findings, tag) {
  return pipeline(findings,
    (f, item, i) => parallel(LENSES.map(l => () =>
      agent(`${CTX}\n\n${l.prompt(f)}\n\nAnswer with the verdict schema. Be concrete: cite lines you read.`, { label: `verify:${tag}${i + 1}:${l.key}`, phase: 'Verify', schema: VERDICT, effort: l.effort })
    )).then(vs => {
      const votes = vs.filter(Boolean)
      const kept = votes.filter(v => !v.refuted).length
      const survives = votes.length > 0 && kept >= 2
      const sev = votes.filter(v => !v.refuted).map(v => v.severity)
      return Object.assign({}, f, { votes, survives, verifiedSeverity: sev.includes('high') ? 'high' : sev.includes('medium') ? 'medium' : sev.includes('low') ? 'low' : 'none' })
    }),
    (v, item, i) => {
      if (!v || !v.survives) { return v }
      return agent(`${CTX}\n\nThis finding was confirmed by adversarial review. Design the PROPER fix per CLAUDE.md (no patch-over; touch more code if that is what the clean shape needs, but stay proportionate and consistent with the repo's own idioms — read the surrounding code and mirror its style, including brace-less single-line ifs since that is the file's convention). Read every line you will change. Do NOT edit any file; return the design only.\n\nFINDING\n${JSON.stringify(Object.assign({}, v, { votes: undefined }), null, 2)}\n\nVERIFIER NOTES\n${JSON.stringify(v.votes.map(x => ({ refuted: x.refuted, reasoning: x.reasoning, corrected_claim: x.corrected_claim })), null, 2)}`, { label: `fix:${tag}${i + 1}`, phase: 'Fix', schema: FIX }).then(fx => Object.assign({}, v, { fixDesign: fx }))
    }
  )
}

phase('Verify')
const round1 = (await verifyAndFix(canon, 'r1-')).filter(Boolean)
const confirmed1 = round1.filter(r => r.survives)
const refuted1 = round1.filter(r => !r.survives)
log(`Round 1: ${confirmed1.length} confirmed, ${refuted1.length} refuted`)

phase('Critic')
const summaryForCritic = round1.map(r => ({ title: r.title, file: r.file, line: r.line, survives: r.survives, severity: r.verifiedSeverity }))
const CRITICS = [
  { key: 'gaps', prompt: `You are the completeness critic. Eight reviewers and an adversarial pass already produced the list below (confirmed and refuted alike). Read both patches in full and the code around every hunk, and find what they MISSED: a hunk nobody commented on, an interaction between the two commits (the save state machine and the default-note opening both run inside selectPath/rebuildRows — trace one startup and one tab switch end to end with a dirty note), a caller of a changed function nobody checked, a doc claim nobody checked. Return only findings that are NOT already in the list below (same defect = skip, even if refuted).` },
  { key: 'runtime', prompt: `You are the runtime critic. Trace these end-to-end scenarios through the code at HEAD and report any defect the scenario exposes that is not already in the list below: (a) app starts with a version-3 state file (no lastNotes), OneNote signed in and slow: which tab shows, what opens, what defaultOwed does over the six rebuilds; (b) user types in a local note, the local provider's 500 ms Timer fires while the converter for a previous flush is still running: count savesPending, dirty, and what is written; (c) user deletes the open note while its save is in the provider (not the converter): what saveFailed does if the provider answers with an error; (d) window is hidden (close()) mid-conversion, then reopened: missedSaveNotice, dirty, flush; (e) Notion provider removed via settings (applyProviderDiff) while its note is open and dirty; (f) notebookTabs flipped while an OneNote page is open: setActiveSection / lastNotes / defaultNote across the recreate. Return only NEW findings.` },
]
const critics = await parallel(CRITICS.map(c => () =>
  agent(`${CTX}\n\n${c.prompt}\n\nALREADY FOUND\n${JSON.stringify(summaryForCritic, null, 2)}`, { label: `critic:${c.key}`, phase: 'Critic', schema: FINDINGS })
))
let extra = []
critics.filter(Boolean).forEach((r, i) => (r.findings || []).forEach((f, j) => extra.push(Object.assign({ id: `${CRITICS[i].key}-${j + 1}`, ids: [`${CRITICS[i].key}-${j + 1}`] }, f))))
log(`Critic: ${extra.length} new candidate findings`)
let round2 = []
if (extra.length > 0) {
  const dd = await agent(`Merge duplicates in this list of code-review findings the same way as before (same defect -> one canonical entry with all ids; never merge merely same-file). Also DROP any entry that restates one of these already-judged findings (list of titles follows) — they are done. Output the canonical list of genuinely new findings.\n\nALREADY JUDGED\n${JSON.stringify(summaryForCritic.map(s => s.title), null, 2)}\n\nNEW FINDINGS\n${JSON.stringify(extra, null, 2)}`, { label: 'dedup:r2', phase: 'Dedup', schema: DEDUP, effort: 'medium' })
  const canon2 = (dd && dd.findings) ? dd.findings : extra
  round2 = (await verifyAndFix(canon2, 'r2-')).filter(Boolean)
  log(`Round 2: ${round2.filter(r => r.survives).length} confirmed, ${round2.filter(r => !r.survives).length} refuted`)
}

const all = round1.concat(round2)
const order = { high: 0, medium: 1, low: 2, none: 3 }
const confirmed = all.filter(r => r.survives).sort((a, b) => order[a.verifiedSeverity] - order[b.verifiedSeverity])
const refuted = all.filter(r => !r.survives)
return {
  confirmed: confirmed.map(r => ({ ids: r.ids, file: r.file, line: r.line, title: r.title, category: r.category, severity: r.verifiedSeverity, claim: r.claim, evidence: r.evidence, scenario: r.scenario, votes: r.votes.map(v => ({ refuted: v.refuted, confidence: v.confidence, severity: v.severity, reasoning: v.reasoning, corrected_claim: v.corrected_claim })), fixDesign: r.fixDesign })),
  refuted: refuted.map(r => ({ ids: r.ids, file: r.file, line: r.line, title: r.title, claim: r.claim, votes: r.votes.map(v => ({ refuted: v.refuted, confidence: v.confidence, reasoning: v.reasoning })) })),
  finderCount: found.filter(Boolean).length,
}