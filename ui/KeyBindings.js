.pragma library

// The keys for getting around and for the notes themselves, written out for
// the page behind the menu's "Key bindings". Not every key the app answers
// to: the editor's formatting shortcuts are left out deliberately, since
// ctrl+b for bold is a thing you already know and a thing the toolbar above
// the note says for itself.
//
// This is a second telling of part of what handleShortcut() in Notes.qml
// does — the two are edited together, and that function's own comment says
// so — because the alternative is a user who can only learn a shortcut by
// finding it in the source.
//
// Key names are spelled in ASCII on purpose. The page is monospace and its
// columns are aligned by counting characters; an arrow glyph that a font
// gives a wider cell than a letter would pull every line after it out of
// true.
var GROUPS = [
  {
    title: "Getting around",
    rows: [
      ["ctrl+k", "Search your notes"],
      ["up / down", "In the search: walk the list without leaving the field"],
      ["enter", "In the search: leave it for the note"],
      ["ctrl+up", "The note above"],
      ["ctrl+down", "The note below"],
      ["ctrl+tab", "The next notebook"],
      ["ctrl+shift+tab", "The notebook before it"],
      ["ctrl+right", "Open the notebook the cursor rests on"],
      ["ctrl+left", "Fold it, and climb to the one holding it"],
      ["esc", "Clear the search; again to put the window away"]
    ]
  },
  {
    title: "Notes",
    rows: [
      ["ctrl+n", "A new note in the open notebook"],
      ["ctrl+shift+n", "A new notebook"],
      ["ctrl+d", "Delete the note you are reading"]
    ]
  }
];

function pad(s, width) {
  var out = s;
  while (out.length < width) {
    out += " ";
  }
  return out;
}

// The whole listing as one block of monospace text: a group's name on its
// own line, its rows indented under it, and the key column as wide as the
// widest key in the whole page so the descriptions line up across groups
// rather than only within one.
function text() {
  var width = 0;
  for (var g = 0; g < GROUPS.length; g++) {
    for (var r = 0; r < GROUPS[g].rows.length; r++) {
      width = Math.max(width, GROUPS[g].rows[r][0].length);
    }
  }

  var lines = [];
  for (var i = 0; i < GROUPS.length; i++) {
    var group = GROUPS[i];
    if (i > 0) {
      lines.push("");
    }
    lines.push(group.title);
    lines.push("");
    for (var j = 0; j < group.rows.length; j++) {
      lines.push("  " + pad(group.rows[j][0], width) + "   " + group.rows[j][1]);
    }
  }
  return lines.join("\n");
}
