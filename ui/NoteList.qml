import QtQuick
import QtQml.Models
import qs.Commons
import qs.Ui
import "TabColors.js" as TabColors

// The left-hand navigation: the open tab's note tree. The tabs themselves
// live across the title bar now (TabStrip.qml); what remains here keeps the
// provider's colour as a restrained surface tint and selection accent, so
// note titles remain the visual focus.
//
// Model rows carry { kind, notebook, path, title, preview }:
//   kind "note"        a note (fixed: true → not draggable)
//   kind "new"         the "+ New note…" row of a notebook
//   kind "action"      a clickable row: `path` is the action id, `title` its
//                      label, `icon` its glyph
//   kind "tree"        an expandable group inside a notebook (OneNote
//                      notebook / section): `path` is its id, `expanded`
//                      its state; rows are indented by `level`
Item {
  id: root

  // The rows on show. While a filter is on, the search panel renders them and
  // the main list goes empty — not merely invisible, or every match would be
  // built twice, once with drag areas and buttons nobody can see.
  property var model: []
  property string currentPath: ""
  // The keyboard cursor when it rests on a section row instead of the open
  // note: that tree row's path, "" otherwise (see the host's treeCursor).
  property string treeCursor: ""
  property bool filtering: false
  // Providers are still answering the content search; the search panel says
  // so instead of a premature "No match" (see the host's searchBusy).
  property bool searchBusy: false
  // The binder's tabs, as the host builds them: { key, name, color, logo,
  // count }. The strip in the title bar renders them; this panel reads only
  // the open one — its colour for the page wash, its name for the search
  // panel's label.
  property var sections: []
  property string activeKey: ""
  // Only a provider that can make notebooks offers the row that makes them.
  property bool canCreateNotebook: false
  readonly property string activeName: {
    for (var i = 0; i < root.sections.length; i++)
      if (root.sections[i].key === root.activeKey) return root.sections[i].name || ""
    return ""
  }
  // The open tab's colour, resolved the way the strip resolves it, so the
  // page wash below and the tab above cannot disagree.
  readonly property color activeBase: {
    for (var i = 0; i < root.sections.length; i++)
      if (root.sections[i].key === root.activeKey)
        return TabColors.baseFor(root.sections[i].color || "", root.sections[i].name || "")
    return Color.menu.background
  }
  property color foreground: Color.menu.text
  property color accent: Color.accent
  // The accent written as ink: the theme's text pulled toward the accent, the
  // same trick as a tab's label (see TabColors.inkAlpha). The accent itself is
  // the theme's to choose and may sit anywhere; starting from the foreground
  // is what guarantees it reads on that theme's background — a dark theme's
  // white becomes a pale cast of it, a light theme's black a deep one. Never
  // Qt.lighter/Qt.darker, which pick a direction and are wrong on the theme
  // that runs the other way.
  readonly property color accentInk: Qt.tint(foreground, Util.alpha(accent, 0.6))
  property string fontFamily: Style.font.menuFamily
  // (title, preview) -> string shown in the row.
  property var titleFor: function(t, p) { return t || p || "Untitled" }

  signal activated(string path)
  // `target` is the row's path when it has one (e.g. a OneNote section), else
  // the notebook key.
  signal newRequested(string target)
  signal treeToggled(string path)
  signal actionRequested(string id)
  signal newNotebookRequested(string name)
  signal deleteRequested(string path)
  // `paths` is the notebook's notes in the order the drag left them on
  // screen — the model has not heard about the moves yet (see visualModel).
  signal reorderFinished(string notebook, var paths)

  readonly property int rowHeight: Style.spacing.controlHeight
  // The page's own margin. The rows sit inside it, so a title never starts on
  // the panel's edge and the list has air above and below it.
  readonly property real pagePadding: Style.spacing.lg
  readonly property real textInset: Style.spacing.md
  // Rows draw as rounded pills; the search panel's rows measure the same way.
  readonly property real rowRadius: Math.min(Style.cornerRadius, Style.space(6))

  // The panel carries a restrained wash of the open source's colour — a shade
  // over the theme's background rather than a surface, so the theme's own text
  // goes on it unchanged and nothing here has to know whether the theme is
  // dark or light. The selection fill is the same wash said once more, one
  // step deeper.
  readonly property real pageWashAlpha: 0.075
  readonly property real selectionWashAlpha: 0.14
  readonly property color page: Qt.tint(Color.menu.background,
                                        Util.alpha(root.activeBase, pageWashAlpha))
  readonly property color selectionFill: Qt.tint(page, Util.alpha(root.activeBase, selectionWashAlpha))

  // Whichever list is on screen: the search panel replaces the main list
  // while a filter is on, and a keyboard move must scroll the one visible.
  function positionViewAtIndex(i, mode) {
    if (root.filtering) searchPanel.positionViewAtIndex(i, mode)
    else listView.positionViewAtIndex(i, mode)
  }

  // Scroll offset, measured from the top of the content, so a model rebuild
  // (which resets contentY) can put the list back where it was.
  function scrollOffset() { return listView.contentY - listView.originY }
  function setScrollOffset(y) {
    listView.forceLayout()
    var max = Math.max(0, listView.contentHeight - listView.height)
    listView.contentY = listView.originY + Math.max(0, Math.min(y, max))
  }
  function debugInfo() {
    return "contentY=" + listView.contentY + " originY=" + listView.originY + " contentHeight=" + listView.contentHeight + " height=" + listView.height + " count=" + listView.count
  }

  // The notebook's notes in the order now on screen. A drag moves delegates
  // while the model stands still, so until the host writes the order back
  // this walk of the visual items is the only record of it.
  function orderedPaths(notebook) {
    var paths = []
    for (var i = 0; i < visualModel.items.count; i++) {
      var d = visualModel.items.get(i).model.modelData
      if (d.kind === "note" && d.notebook === notebook) {
        paths.push(d.path)
      }
    }
    return paths
  }

  function startNewNotebook() {
    newNotebookRow.editing = true
    notebookField.text = ""
    notebookField.forceActiveFocus()
  }

  Item {
    id: panel
    anchors.fill: parent

      // The open source's panel, in its restrained wash. Opaque rather than a
      // translucent colour, so the scroll fades below have something definite
      // to fade into.
      readonly property color fill: root.page

      Rectangle {
        anchors.fill: parent
        color: panel.fill
      }

    // Searching swaps the whole page for its own panel rather than bending this
    // one into a results list: no headings to keep, no rows to drag, nothing to
    // create. See SearchResults.qml.
    SearchResults {
      id: searchPanel
      anchors.fill: parent
      anchors.margins: root.pagePadding
      visible: root.filtering
      model: root.filtering ? root.model : []
      loading: root.searchBusy
      currentPath: root.currentPath
      notebook: root.activeName
      foreground: root.foreground
      accent: root.accent
      selectionAccent: root.activeBase
      selectedBackground: root.selectionFill
      selectedText: root.foreground
      fontFamily: root.fontFamily
      titleFor: root.titleFor
      rowHeight: root.rowHeight
      rowRadius: root.rowRadius
      textInset: root.textInset
      onActivated: function(path) { root.activated(path) }
    }

    Column {
      anchors.fill: parent
      anchors.margins: root.pagePadding
      visible: !root.filtering
      spacing: 0

      Item {
        width: parent.width
        height: parent.height - newNotebookRow.height

        // The rows live behind a DelegateModel so a drag can reorder them
        // without touching the model: a model write mid-drag rebuilds every
        // delegate and destroys the one under the mouse, ending the drag at
        // the first swap. Instead the drag shuffles the visual order
        // (items.move) as rows are crossed, and the model hears about it
        // once, on release (reorderFinished).
        DelegateModel {
          id: visualModel
          model: root.filtering ? [] : root.model

          // ---- rows
          delegate: Item {
            id: slot
            required property int index
            required property var modelData
            readonly property bool isNote: modelData.kind === "note"
            readonly property bool isNew: modelData.kind === "new"
            readonly property bool isAction: modelData.kind === "action"
            readonly property bool isTree: modelData.kind === "tree"
            // One step of indent is the parent's icon column plus the gap
            // after it, so a child's icon starts under its parent's label —
            // less a nudge for the glyph being centered in a column wider
            // than its ink, which pushes its visible edge right of the sum.
            readonly property int indent: (modelData.level || 0)
              * (Style.font.icon + Style.space(2) + Style.spacing.md - Style.spacing.sm)
            readonly property bool draggable: isNote && !modelData.fixed
            // Where this row sits on screen right now — diverges from `index`
            // while a drag is shuffling the visual order.
            readonly property int visualIndex: slot.DelegateModel.itemsIndex
            width: listView.width
            height: root.rowHeight

            DropArea {
              anchors.fill: parent
              enabled: !root.filtering && slot.draggable
              onEntered: function(drag) {
                if (drag.source.modelData.notebook !== slot.modelData.notebook) {
                  return
                }
                if (drag.source.visualIndex !== slot.visualIndex) {
                  visualModel.items.move(drag.source.visualIndex, slot.visualIndex)
                }
              }
            }

            Rectangle {
              id: row
              x: Style.spacing.xxs
              width: slot.width - Style.spacing.xxs * 2
              height: root.rowHeight - Style.spacing.xxs
              anchors.verticalCenter: parent.verticalCenter
              radius: root.rowRadius
              readonly property bool current: slot.isNote
                ? slot.modelData.path === root.currentPath
                : slot.isTree && slot.modelData.path === root.treeCursor
              color: current || rowHover.hovered ? Style.hoverFill : "transparent"
              // Action rows ("New note…", sign in/out, settings) are dimmed so
              // notes stand out from the things you can do; hover lifts them.
              // Dimmed, not faint: opacity fades toward whichever background
              // the theme has, so this number means the same on all of them.
              opacity: dragArea.drag.active ? 0.85 : ((slot.isNew || slot.isAction) && !rowHover.hovered ? 0.65 : 1)

              HoverHandler { id: rowHover }

              Row {
                anchors.fill: parent
                anchors.leftMargin: root.textInset + slot.indent
                anchors.rightMargin: Style.spacing.sm
                spacing: Style.spacing.md

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.font.icon + Style.space(2)
                  text: slot.isNew ? "+" : (slot.isAction ? (slot.modelData.icon || "󰊻")
                    : (slot.isTree ? (slot.modelData.expanded ? "󰅀" : "󰅂") : "󰎞"))
                  // Every note carries the same glyph, so it says nothing a
                  // title does not — kept for the column it holds, dimmed so
                  // the eye goes to the words.
                  color: slot.isNew || slot.isAction ? root.accentInk
                    : (slot.isTree ? root.accentInk
                    : Util.alpha(root.foreground, 0.4))
                  font.family: Style.fontFamily
                  font.pixelSize: (slot.isNew || slot.isAction) ? Style.font.iconSmall : Style.font.icon
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.font.icon - Style.space(2) - Style.spacing.md
                    - (closeButton.visible ? closeButton.width + Style.spacing.xs : 0)
                  text: slot.isNew ? "New note…"
                    : (slot.isAction || slot.isTree ? slot.modelData.title : root.titleFor(slot.modelData.title, slot.modelData.preview))
                  color: slot.isTree && !row.current ? root.accentInk : root.foreground
                  font.bold: slot.isTree && (slot.modelData.level || 0) === 0
                  font.family: root.fontFamily
                  // Actions ("New note…", sign in/out, settings) read as chrome,
                  // not as notes: dimmed above, and a size smaller here.
                  font.pixelSize: (slot.isNew || slot.isAction) ? Style.font.bodySmall : Style.font.body
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: dragArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                drag.target: (root.filtering || !slot.draggable) ? null : row
                drag.axis: Drag.YAxis
                drag.threshold: Style.space(6)
                onClicked: {
                  if (slot.isNew) {
                    root.newRequested(slot.modelData.path || slot.modelData.notebook)
                  } else if (slot.isAction) {
                    root.actionRequested(slot.modelData.path)
                  } else if (slot.isTree) {
                    root.treeToggled(slot.modelData.path)
                  } else {
                    root.activated(slot.modelData.path)
                  }
                }
                onReleased: {
                  if (!row.Drag.active) {
                    return
                  }
                  row.Drag.drop()
                  root.reorderFinished(slot.modelData.notebook, root.orderedPaths(slot.modelData.notebook))
                }
              }

              // Faint until the row is current or under the cursor, like
              // Toolroll's pin; never hidden, so it stays clickable.
              Button {
                id: closeButton
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.xs
                anchors.verticalCenter: parent.verticalCenter
                visible: slot.isNote
                // Off entirely until you are on the row: 200 of these at a
                // third of an opacity is a texture, not an affordance.
                opacity: row.current || rowHover.hovered ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 120 } }
                iconText: "󰅖"
                tooltipText: "Delete this note"
                foreground: root.foreground
                accent: root.accent
                iconSize: Style.font.iconSmall
                horizontalPadding: Style.spacing.xs
                verticalPadding: Style.spacing.xxs
                onClicked: root.deleteRequested(slot.modelData.path)
              }

              Drag.active: dragArea.drag.active
              // The delegate root, so a DropArea can read the dragged row's
              // modelData and visualIndex without copies of either.
              Drag.source: slot
              Drag.hotSpot.x: width / 2
              Drag.hotSpot.y: height / 2

              states: State {
                when: dragArea.drag.active
                ParentChange { target: row; parent: listView }
                // The pill is centred in its slot by an anchor, and an anchor
                // outranks the drag's writes to y — reparented, it would pin
                // the row to the middle of the list. Released here, restored
                // when the drag ends and the state reverts.
                AnchorChanges { target: row; anchors.verticalCenter: undefined }
                PropertyChanges { target: row; z: 10 }
              }
            }
          }
        }

        ListView {
          id: listView
          anchors.fill: parent
          clip: true
          spacing: 0
          boundsBehavior: Flickable.StopAtBounds
          model: visualModel
          displaced: Transition { NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutQuad } }

          ListWheel { flick: listView }
        }

        // ---- there is more: fades and a thin track, as in Toolroll
        readonly property bool scrollable: listView.contentHeight > listView.height + 1

        Rectangle {
          anchors.top: parent.top
          width: parent.width
          height: Style.space(18)
          visible: parent.scrollable && !listView.atYBeginning
          gradient: Gradient {
            GradientStop { position: 0.0; color: Util.alpha(panel.fill, 0.95) }
            GradientStop { position: 1.0; color: "transparent" }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Style.space(18)
          visible: parent.scrollable && !listView.atYEnd
          gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Util.alpha(panel.fill, 0.95) }
          }
        }

        Rectangle {
          id: scrollTrack
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(3)
          visible: parent.scrollable
          color: "transparent"

          Rectangle {
            width: parent.width
            radius: width / 2
            height: Math.max(Style.space(24),
                             scrollTrack.height * (listView.height / Math.max(1, listView.contentHeight)))
            // contentY is measured from originY, which a ListView with section
            // headers does not keep at 0 — subtract it or the thumb sits low.
            y: (scrollTrack.height - height)
               * Math.max(0, Math.min(1, (listView.contentY - listView.originY) / Math.max(1, listView.contentHeight - listView.height)))
            color: Util.alpha(root.foreground, listView.moving ? 0.45 : 0.2)
            Behavior on color { ColorAnimation { duration: 150 } }
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: listView.count === 0
          text: root.filtering ? "No note matches" : "No notebooks yet"
          color: Util.alpha(root.foreground, 0.65)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      // ---- "New notebook…" row; becomes a name field when clicked
      Rectangle {
        id: newNotebookRow
        property bool editing: false
        visible: root.canCreateNotebook
        width: parent.width
        // A Column skips an invisible child, but the list above sizes itself
        // off this height — leave it at 0 or the panel keeps the empty row.
        height: visible ? root.rowHeight : 0
        color: !editing && newHover.hovered ? Style.hoverFill : "transparent"

        HoverHandler { id: newHover }

        Row {
          anchors.fill: parent
          anchors.leftMargin: root.textInset
          anchors.rightMargin: Style.spacing.sm
          spacing: Style.spacing.md

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: Style.font.icon + Style.space(2)
            text: newNotebookRow.editing ? "󰉋" : "+"
            color: root.accentInk
            font.family: Style.fontFamily
            font.pixelSize: Style.font.iconSmall
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: !newNotebookRow.editing
            anchors.verticalCenter: parent.verticalCenter
            text: "New notebook…"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: notebookField
            visible: newNotebookRow.editing
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.font.icon - Style.space(2) - Style.spacing.md
            placeholderText: "Notebook name"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            verticalPadding: Style.spacing.xxs
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                newNotebookRow.editing = false; event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                var name = text.trim()
                newNotebookRow.editing = false
                if (name) root.newNotebookRequested(name)
                event.accepted = true
              }
            }
            onActiveFocusChanged: if (!activeFocus) newNotebookRow.editing = false
          }
        }

        MouseArea {
          anchors.fill: parent
          visible: !newNotebookRow.editing
          cursorShape: Qt.PointingHandCursor
          onClicked: root.startNewNotebook()
        }
      }
    }
  }
}
