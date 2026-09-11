# Editing tools

Each editing tool lives in one QML file in `ui/tools/`. The editor discovers
these files when it starts. Adding a tool does not require changing
`Notes.qml`, `NoteEditor.qml`, the toolbar model, or the shortcut table.
Restart the app after adding or editing a file.

`ui/editing/Tool.qml` defines the contract. `ToolRegistry.qml` creates a
separate set of tool instances for each editor, checks their
metadata, and dispatches actions. `ToolBar.qml` renders buttons, menus and
tool-owned panels. `EditorApi.qml` provides shared document operations; the
editor retains its document, keyboard behavior, conversion and undo machinery.

## Arrange the toolbar

Open **Settings** and edit `editor.toolbar` in the JSON. Each inner array is
a group; array order controls button order, and a gap separates groups. Save
to apply the layout immediately. Existing configurations gain these defaults
in the Settings page; the file is updated when you save it.

The default layout keeps formatting actions directly on the toolbar and groups
the calendar tools under **Insert → Insert month**:

```json
"editor": {
  "toolbar": [
    ["bold", "italic", "underline", "strikeout"],
    ["textColor", "highlight", "code", "heading"],
    ["ul", "ol", "todo", "outdent", "indent"],
    ["quote", "codeblock", "rule", "link"],
    ["table", "addRow", "delRow", "addCol", "delCol"],
    [{ "dropdown": "insert", "items": [
      { "dropdown": "insertMonth", "items": ["currentMonth", "nextMonth", "customMonth"] }
    ] }]
  ]
}
```

To move tools into Insert, remove their direct entries and list them in its
`items` array, in the order you want. For example, this layout puts Italic and
Bold in one group, followed by an Insert dropdown containing Table and Link:

```json
"editor": {
  "toolbar": [
    ["italic", "bold"],
    [{ "dropdown": "insert", "items": ["table", "link"] }]
  ]
}
```

All installed tools omitted from the layout appear in a final group, sorted
by tool ID. A tool already listed in a dropdown is not appended. Unknown IDs
are preserved for tools installed later; they produce no empty buttons. If a
dropdown's QML file is removed, its installed members return to the final
group. An empty toolbar array appends all tools. Omitting `editor.toolbar`
restores the default arrangement.

Dropdown `items` can also contain dropdown objects, using the same structure
at each level. Each submenu displays its tool's label and a right arrow;
hovering, clicking or pressing Right opens its children. Left returns to the
parent, and selecting an action dismisses the menu tree. Use another tool
with `isMenu: true` to define an additional named group.

An empty top-level dropdown is visible but disabled. Provider capabilities and
caret context still determine which actions are available, including inside
submenus. Submenus with no available descendants are hidden. Rearranging an
action does not change its shortcut or behavior. Duplicate IDs (including
across menu levels) and malformed entries are rejected on Save.
If a hand-edited file contains an invalid toolbar, startup uses the default
toolbar while preserving provider settings and leaving the file untouched.
Dropdown objects name a configurable menu tool; strings name executable
tools or tools with their own fixed choices at any level. Incorrectly placed
installed tools fall back to the final group so they stay accessible.

No tool file contains a toolbar order, group or parent menu. A new insertion action
can be implemented as one tool file and then placed inside Insert through
settings. The Insert tool only provides the dropdown; each item generates
its own content.

## Heading

`Heading.qml` provides one dropdown with **Heading 1**, **Heading 2**,
**Heading 3**, and **Normal**, each previewed at its document size. Use
`"heading"` in toolbar settings to move the dropdown as one tool, including
inside another menu. Older layouts naming `h1`, `h2`, `h3`, or `p` display
one Heading dropdown at the first of those positions.

The choices retain their `h1`, `h2`, `h3`, and `p` action IDs for IPC and
provider capabilities. Only supported choices appear; the dropdown hides
when none are supported or the caret is inside a list.

## Text color

Text color opens a six-column palette of twelve compact circular swatches based on
OneNote's phone palette screenshot, omitting Dark brown. Reset color removes only the foreground
format. With a selection the action colors that text; with a caret it sets
the color for subsequent typing until the caret moves. Choosing or resetting
a selection is one undo step, and other inline formatting is preserved.

Colors are saved as `<span style="color:#0070c0;">Mushrooms</span>` in Markdown.
The shared parser accepts these spans, including nested Markdown formatting;
hex, basic CSS names such as `red`, and integer RGB values normalize to hex.
Local notes and OneNote preserve these colors through loading and saving,
including checklists, headings, links and tables. Theme ink for links, quotes
and highlights is drawn separately, so Reset color restores the appropriate
appearance without writing theme colors into the note.

The action requires the native text helper and the `textColor` provider
capability (or unrestricted tools). Code blocks and providers with restricted
formatting, such as Notion, do not offer it. Without the optional native helper,
stored colors still render and save; automatic link, quote and highlight ink
uses the document's ordinary foreground. Build with `sh cpp/build.sh`.

## Calendar tools

`InsertMonth.qml` supplies the `insertMonth` submenu. `InsertCurrentMonth.qml`
supplies `currentMonth`, its first default item. It inserts a month-and-year
label and a seven-column calendar table,
with one row per week and empty cells outside the month. The month comes
from the local clock when the action runs; the inserted table remains ordinary
editable Markdown. The OS locale controls weekday order and localized month
and weekday names through [Qt's locale API](https://doc.qt.io/qt-6/qml-qtqml-locale.html#firstDayOfWeek-prop).

`InsertNextMonth.qml` supplies `nextMonth`, immediately after `currentMonth`.
It inserts the next calendar month using the local date when the action runs,
including January of the following year when run in December. It starts on
day one so dates at the end of a month cannot skip a shorter month.

`InsertCustomMonth.qml` supplies `customMonth`, the last default item in Insert month.
It opens a panel with a localized month dropdown and a year field (1–9999),
initially set to the current month and year. Insert or Enter in the year field
confirms; Cancel or Escape dismisses it without editing. All three tools use
`ui/editing/Calendar.js`, including Gregorian leap-year rules and years 1–99.

These tools use the existing `table` capability, so they are available automatically
for providers that support tables. All calendar actions and Insert a table can
insert inside the current table cell. Insertion uses the shared document
transaction and can be undone in one step.

Nested tables retain cell paragraphs and inner tables as semantic HTML in the
Markdown file; ordinary tables keep their pipe syntax. Local notes and OneNote
preserve this structure when saved and reloaded. The native text helper makes
row/column actions and double Enter operate on the innermost table at the caret.

Saved custom layouts keep their arrangement. To group the month tools in an
existing Insert dropdown, replace their entries with
`{ "dropdown": "insertMonth", "items": ["currentMonth", "nextMonth", "customMonth"] }`,
retaining the other entries and removing any direct entries for these tools.
As with all tools, omitting a tool from a custom layout puts it in the final
toolbar group.

## Add a tool

For example, save this as `ui/tools/InsertGreeting.qml`:

```qml
import QtQuick
import "../editing"

Tool {
  toolId: "greeting"
  label: "Insert greeting"
  icon: "+"
  shortcutKey: Qt.Key_G
  shortcutModifiers: Qt.ControlModifier | Qt.ShiftModifier
  shortcutLabel: "ctrl+shift+g"

  function execute() {
    editor.insertHtml("Hello")
  }
}
```

Its button, tooltip, shortcut and keyboard-help entry come from this file.
Its button initially appears in the final group. To put it in Insert, add
`"greeting"` to the dropdown's `items` array in settings.
The example uses HTML already supported by the document converters. A tool
that introduces new document syntax also needs converter support and, where
applicable, provider support so its content survives saving and reloading.

## Tool properties

| Property | Meaning |
| --- | --- |
| `toolId` | Unique action ID. Existing IDs such as `bold`, `h1` and `addRow` remain stable for IPC. |
| `label`, `icon` | Button tooltip/menu text and icon glyph. |
| `capability` | Provider capability required; defaults to `toolId`. All four table alteration tools require `table`. |
| `available` | Reactive context condition, such as `editor.inTable`. Controls both presentation and execution. |
| `shortcutKey`, `shortcutModifiers`, `shortcutLabel` | Optional key, modifiers and human-readable shortcut. Used for dispatch, tooltips and help. |
| `isMenu` | This entry opens a menu; automatically true when `options` are provided. |
| `options` | Fixed executable `Tool` choices owned by this file, as in `Heading.qml`. They retain individual action IDs and capabilities but move together in the toolbar. Bind their `editor` and availability to the owning tool. |
| `previewScale`, `previewBold` | Optional menu-label styling, used by headings. |
| `panelPopup` | Render the tool panel as a dropdown anchored to its toolbar button. |
| `panel`, `panelOpen` | Optional QML component rendered below the toolbar and whether it is open. |
| `panelContext` | Note, document revision and selection captured by `openPanel()`. Cleared when the panel closes. |

Implement `execute()` with the tool's specific behavior. Simple tools call a
shared operation; complex tools can keep additional functions, state and a
panel in the same file. `InsertLink.qml` and `InsertCustomMonth.qml` demonstrate panels, and `Insert.qml`
defines the dropdown container. Any executable tool can become a dropdown item.

Input tools call `openPanel()` from `execute()` after setting their initial
values. This captures the insertion context and opens their `panel` component.
On confirmation, validate the form and call `submitPanel(function() { ... })`
with the edit. It rechecks availability, provider support and the captured
context, closes the panel, then applies the edit and restores editor focus.
It returns false for a stale or closed panel. `cancelPanel()` closes without
editing and restores focus. Opening another action closes the previous panel.
All form fields, validation and content generation stay in the tool file;
adding another input tool requires no toolbar or main-app changes.

The registry rejects duplicate IDs, conflicting shortcuts, invalid tool
definitions, exposing diagnostics through `editor.tools.errors`
and the application log. Existing app shortcuts have priority over tool
definitions; undo, redo, cut, copy and select-all are also reserved. All
built-in formatting shortcuts use the registry, so a
provider restriction also prevents Qt's native formatting shortcut from
executing. Navigation and clipboard shortcuts remain editor/app behavior.

## Shared editor API

Tools receive `editor`; they must not reach through its implementation
references to the host or TextEdit. Shared primitives belong in `EditorApi.qml`;
an action's content, rules and UI belong in its tool file.

| Operation/state | Use |
| --- | --- |
| `writable`, `inTable`, `inList`, `supports(capability)` | Document and provider availability. |
| `selection()` | Selected `from`, `to`, `text` and inline `html`. Positions use Qt document offsets. |
| `canColorText`, `setTextColor(color)` | Apply a hex foreground or clear it with an empty string; also supports pending typing. |
| `toggleFont(kind, marker)` | Toggle a supported boolean font attribute, including pending formatting while typing and literal markers in code blocks. |
| `acceptsInline()`, `markedInCode(marker)` | Reject selections crossing a code block; type literal paired markers when entirely inside one. |
| `replaceInline(html, keepSelection)` | Replace selected formatting without breaking the containing list/paragraph; one undo step. |
| `insertHtml(html)`, `escapeHtml(text)` | Replace the selection with HTML in one undo step, and escape literal text/attributes. |
| `insertSnippet(markdown)` | Insert after the current block, or on an empty paragraph, with a landing paragraph when needed. |
| `insertTable(markdown)` | Insert table content at the caret inside a cell, or as a normal snippet outside tables. |
| `transformBlocks(transform, options)` | Transform selected Markdown blocks. The callback receives `{ indent, prefix, content, isList }` and returns a line. `options.list` manages paragraph separators when toggling lists; `unchangedMessage` supplies optional feedback. |
| `tableContext()`, `changeTable(operation, index, count)` | Read the innermost table's row/column and dimensions, and insert/remove rows or columns as one undo transaction. Operations are `insertRows`, `removeRows`, `insertColumns`, `removeColumns`. |
| `transformTable(transform)` | Plain-table fallback when the native helper is absent. Callback arguments are `(rows, row, column)`; row 1 is the Markdown separator row. Return `false` to leave the document unchanged. |
| `withMarkdown(callback, asText)` | Read Markdown lines and the line/block map, rejecting stale or failed conversions. `asText` optionally reads a code block as prose. |
| `replaceDocument(markdown, caret, then)` | Render and replace the document in one undo step; optional `then` runs inside that transaction. |
| `cursorPosition()`, `blockAt(position)`, `blockInfoAt(position)`, `caretLine(map)`, `lineAt(map, position)`, `blockEndLine(lines, line)`, `lastBlockThrough(map, line)`, `selectBlock(block)` | Position and block mapping, used by code-block insertion. |
| `capture()`, `current(context)` | Capture and validate the note, document revision and selection around delayed UI work. |
| `selectionInCode()`, `typeInCode(from, to, text)` | Insert literal text using the code block's formatting. |
| `focus()`, `report(message)` | Return focus to the document or report feedback in the status bar. |

The API also exposes the editor's fonts, colors and inline-code chip color.
`withoutChip(html)` lets inline transforms distinguish the code background
from highlighting. `nbsp4` is the dialect's paragraph-indent unit.

Buttons, shortcuts and `editorTool <id>` all use the same capability and
document checks. Panels close when the note changes, becomes unavailable, or
provider capabilities or the layout change. `submitPanel()` validates delayed
submissions against their captured context. Markdown conversion and document
replacement retain the existing stale-note checks and atomic undo behavior.

## Verification

Run `python3 tests/transition_selftest.py --tools` for focused tool checks,
`python3 tests/transition_selftest.py` for all real editor cases, and
`python3 tests/transition_selftest.py --host` for host integration. The runner
copies the tool directory into a temporary workspace and adds an extra QML
tool to verify discovery, toolbar clicks, shortcuts and help without modifying
the application. It also checks formatting round trips, table actions,
provider restrictions, panel context and undo/redo. Layout checks cover group
and dropdown order, omitted tools, moving actions without losing shortcuts,
settings validation, backward-compatible defaults and failed settings saves.
Submenu checks cover nested settings, pointer and keyboard navigation, outside
clicks, empty groups, and dismissal when permissions or the layout change.
Calendar checks cover Sunday, Monday and Saturday week starts, localized
labels, four-to-six-week months, leap-year rules, year boundaries, table
capabilities, menu insertion, saving/reloading and undo/redo.
Nested-table checks cover empty and populated cells, three table levels,
inner and outer row/column changes, double Enter, caret placement and undo.

Lint changes with:

```bash
qmllint -I /usr/share/omarchy/shell ui/editing/*.qml ui/tools/*.qml ui/NoteEditor.qml Notes.qml
```
