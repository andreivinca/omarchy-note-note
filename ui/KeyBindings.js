.pragma library

// Help and dispatch share these definitions. Aliases have no separate label.
var CTRL = Qt.ControlModifier
var SHIFT = Qt.ShiftModifier
var ACTIONS = [
  { id: "search", key: Qt.Key_K, modifiers: CTRL, group: "Getting around", label: "ctrl+k", description: "Search your notes" },
  { id: "search", key: Qt.Key_L, modifiers: CTRL },
  { id: "nextSearch", key: Qt.Key_Down, context: "search", group: "Getting around", label: "up / down", description: "In the search: walk the list without leaving the field" },
  { id: "previousSearch", key: Qt.Key_Up, context: "search" },
  { id: "acceptSearch", key: Qt.Key_Return, context: "search", group: "Getting around", label: "enter", description: "In the search: leave it for the note" },
  { id: "acceptSearch", key: Qt.Key_Enter, context: "search" },
  { id: "acceptSearch", key: Qt.Key_Tab, context: "search" },
  { id: "previousNote", key: Qt.Key_Up, modifiers: CTRL, group: "Getting around", label: "ctrl+up", description: "The note above" },
  { id: "nextNote", key: Qt.Key_Down, modifiers: CTRL, group: "Getting around", label: "ctrl+down", description: "The note below" },
  { id: "nextNote", key: Qt.Key_J, modifiers: CTRL },
  { id: "nextTab", key: Qt.Key_Tab, modifiers: CTRL, group: "Getting around", label: "ctrl+tab", description: "The next notebook" },
  { id: "previousTab", key: Qt.Key_Tab, modifiers: CTRL | SHIFT, group: "Getting around", label: "ctrl+shift+tab", description: "The notebook before it" },
  { id: "previousTab", key: Qt.Key_Backtab, modifiers: CTRL | SHIFT },
  { id: "previousTab", key: Qt.Key_Backtab, modifiers: CTRL },
  { id: "openTree", key: Qt.Key_Right, modifiers: CTRL, group: "Getting around", label: "ctrl+right", description: "Open the notebook the cursor rests on" },
  { id: "closeTree", key: Qt.Key_Left, modifiers: CTRL, group: "Getting around", label: "ctrl+left", description: "Fold it, and climb to the one holding it" },
  { id: "toggleList", key: Qt.Key_E, modifiers: CTRL, group: "Getting around", label: "ctrl+e", description: "Hide the sidebar, or bring it back" },
  { id: "back", key: Qt.Key_Escape, group: "Getting around", label: "esc", description: "Clear the search; again to put the window away" },
  { id: "newNote", key: Qt.Key_N, modifiers: CTRL, group: "Notes", label: "ctrl+n", description: "A new note in the open notebook" },
  { id: "newNotebook", key: Qt.Key_N, modifiers: CTRL | SHIFT, group: "Notes", label: "ctrl+shift+n", description: "A new notebook" },
  { id: "deleteNote", key: Qt.Key_D, modifiers: CTRL, group: "Notes", label: "ctrl+d", description: "Delete the note you are reading" },
  { id: "bold", key: Qt.Key_B, modifiers: CTRL, context: "editor" },
  { id: "italic", key: Qt.Key_I, modifiers: CTRL, context: "editor" },
  { id: "underline", key: Qt.Key_U, modifiers: CTRL, context: "editor" },
  { id: "strikeout", key: Qt.Key_S, modifiers: CTRL, context: "editor" },
  { id: "highlight", key: Qt.Key_H, modifiers: CTRL | SHIFT, context: "editor" },
  { id: "paste", key: Qt.Key_V, modifiers: CTRL, context: "editor" },
  { id: "pastePlain", key: Qt.Key_V, modifiers: CTRL | SHIFT, context: "editor" }
]

function match(event, context) {
  var modifiers = event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)
  for (var i = 0; i < ACTIONS.length; i++) {
    var action = ACTIONS[i]
    if (action.key === event.key && (action.modifiers || 0) === modifiers
        && (!action.context || action.context === context)) {
      return action.id
    }
  }
  return ""
}

function text() {
  var visible = ACTIONS.filter(function(action) { return !!action.label })
  var width = visible.reduce(function(value, action) { return Math.max(value, action.label.length) }, 0)
  var lines = [], previous = ""
  visible.forEach(function(action) {
    if (action.group !== previous) {
      if (lines.length) {
        lines.push("")
      }
      lines.push(action.group, "")
      previous = action.group
    }
    var label = action.label
    while (label.length < width) {
      label += " "
    }
    lines.push("  " + label + "   " + action.description)
  })
  return lines.join("\n")
}
