import QtQuick
import qs.Commons
import qs.Ui

// The smallest useful provider: one section, notes kept in memory, and a
// setup screen of its own (a name) that it stores in its state. Copy it to
// ~/.config/omarchy/note-note/providers/hello/ to see it in the sidebar.
Item {
  id: root

  readonly property string id: "hello"
  readonly property string name: "Hello"
  // Optional: ship a logo.svg beside this file and it heads your tabs.
  // readonly property url logo: Qt.resolvedUrl("logo.svg")
  readonly property bool markdown: true
  readonly property bool hasTitle: true
  readonly property bool canCreate: true
  readonly property bool canDelete: true
  readonly property bool canReorder: false
  readonly property bool canCreateSection: false
  readonly property var microsoftScopes: []
  readonly property string microsoftClientId: ""

  property var host: null
  property var services: null

  signal updated()
  signal statusRequested(string text)
  signal noticeRequested(string title, string text, string code, var actions)
  signal noticeCleared()
  signal viewRequested(string title, var component, var props)
  signal viewCleared()
  signal persistRequested()

  // ── the provider's own settings and data ────────────────────────────
  property string owner: ""                     // set up by the user
  property var notes: []                        // [{ id, title, body }]
  property int nextId: 1
  readonly property bool configured: owner.length > 0
  property var sections: []

  function restoreState(obj) {
    if (obj) {
      root.owner = obj.owner || ""
      root.notes = obj.notes || []
      root.nextId = obj.nextId || 1
    }
  }
  function saveState() { return { owner: root.owner, notes: root.notes, nextId: root.nextId } }

  function rebuild() {
    var rows = []
    if (!root.configured) {
      rows.push({ kind: "action", path: "setup", title: "Set up…", icon: "󰒓" })
    } else {
      for (var i = 0; i < root.notes.length; i++) {
        rows.push({ kind: "note", path: root.id + ":" + root.notes[i].id, title: root.notes[i].title, preview: root.notes[i].body.split("\n")[0] })
      }
      rows.push({ kind: "new", path: "new" })
      rows.push({ kind: "action", path: "settings", title: "Settings…", icon: "󰒓" })
    }
    // `color` is optional: name one and the tab is yours, leave it out and
    // the tab takes a pastel from the section name.
    root.sections = [{ key: "hello", name: root.configured ? "Hello, " + root.owner : "Hello", color: "#a9dcc0", rows: rows }]
    root.updated()
  }
  function refresh() { rebuild() }

  function noteAt(path) {
    var id = Number(path.substring(root.id.length + 1))
    for (var i = 0; i < root.notes.length; i++) {
      if (root.notes[i].id === id) {
        return root.notes[i]
      }
    }
    return null
  }
  function crumb(path) { return "Hello, " + root.owner }
  function createTargetFor(path) { return root.configured ? "new" : "" }
  function toggleTree(id) {}
  function setOrder(sectionKey, paths) {}

  function load(path, cb) { var n = noteAt(path); cb(n ? { title: n.title, body: n.body, editable: true } : { error: "unknown note" }) }
  function save(path, title, body, cb) {
    var n = noteAt(path)
    if (n) {
      n.title = title
      n.body = body
    }
    rebuild(); root.persistRequested()
    cb({})
  }
  function create(target, cb) {
    var n = { id: root.nextId++, title: "", body: "" }
    root.notes = root.notes.concat([n])
    rebuild(); root.persistRequested()
    cb({ path: root.id + ":" + n.id })
  }
  function remove(path, cb) {
    var n = noteAt(path)
    root.notes = root.notes.filter(function(x) { return x !== n })
    rebuild(); root.persistRequested()
    cb({})
  }

  // ── setup: the provider's own screen ────────────────────────────────
  function action(id) {
    if (id === "setup" || id === "settings") {
      root.viewRequested(root.configured ? "Hello — settings" : "Set up Hello", setupView, { current: root.owner })
    }
  }

  Component {
    id: setupView
    FocusScope {
      property string current: ""
      width: parent ? parent.width : Style.space(600)
      height: column.implicitHeight

      Column {
      id: column
      spacing: Style.spacing.md
      leftPadding: Style.spacing.md
      topPadding: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        text: "This example provider keeps notes in memory and only needs to know your name. Settings never leave the provider."
        color: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        width: Style.space(520)
        wrapMode: Text.Wrap
      }
      TextField {
        id: nameField
        width: Style.space(320)
        text: current
        placeholderText: "Your name"
        foreground: Color.menu.text
        accent: Color.accent
        font.family: Style.font.menuFamily
        focus: true
        Keys.onReturnPressed: saveButton.clicked()
      }
      Row {
        spacing: Style.spacing.sm
        Button {
          id: saveButton
          text: "Save"
          iconText: "󰆓"
          bordered: true
          foreground: Color.menu.text
          accent: Color.accent
          onClicked: {
            var v = nameField.text.trim()
            if (!v) {
              root.statusRequested("Hello: a name is required")
              return
            }
            root.owner = v
            root.persistRequested()
            root.viewCleared()
            root.rebuild()
          }
        }
        Button {
          text: "Cancel"
          bordered: true
          foreground: Color.menu.text
          accent: Color.accent
          onClicked: root.viewCleared()
        }
      }
      }
    }
  }
}
