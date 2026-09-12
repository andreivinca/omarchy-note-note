import QtQuick
import QtQml.Models
import qs.Commons
import qs.Ui

// The active notebook: header, note previews or provider tree, and actions.
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
  property var footerActions: []
  property string currentPath: ""
  // The keyboard cursor when it rests on a section row instead of the open
  // note: that tree row's path, "" otherwise (see the host's treeCursor).
  property string treeCursor: ""
  property bool filtering: false
  // Providers are still answering the content search; the search panel says
  // so instead of a premature "No match" (see the host's searchBusy).
  property bool searchBusy: false
  property string searchStatus: ""
  // The binder's tabs, as the host builds them: { key, name, color, logo,
  // count }. The strip in the title bar renders them; this panel reads only
  // the open one — its colour for the page wash, its name for the search
  // panel's label.
  property var sections: []
  property string activeKey: ""
  property real headerHeight: Style.space(45)
  property real headerContentHeight: headerHeight - Style.spacing.hairline
  property color background: Color.menu.background
  readonly property bool hasTree: root.model.some(function(row) { return row.kind === "tree" })
  readonly property int noteCount: {
    for (var i = 0; i < root.sections.length; i++) {
      if (root.sections[i].key === root.activeKey) {
        return root.sections[i].count || 0
      }
    }
    return 0
  }
  readonly property string activeName: {
    for (var i = 0; i < root.sections.length; i++) {
      if (root.sections[i].key === root.activeKey) {
        return root.sections[i].name || ""
      }
    }
    return ""
  }
  readonly property color activeBase: root.accent
  property color foreground: Color.menu.text
  property color accent: Color.accent
  // The accent written as ink: the theme's text pulled toward its accent. It
  // the theme's to choose and may sit anywhere; starting from the foreground
  // is what guarantees it reads on that theme's background — a dark theme's
  // white becomes a pale cast of it, a light theme's black a deep one. Never
  // Qt.lighter/Qt.darker, which pick a direction and are wrong on the theme
  // that runs the other way.
  readonly property color accentInk: Qt.tint(foreground, Util.alpha(accent, 0.6))
  property string fontFamily: Style.font.menuFamily
  property int noteFontSize: Style.font.body
  // (title, preview) -> string shown in the row.
  property var titleFor: function(t, p) { return t || p || "Untitled" }

  signal activated(string path)
  // `target` is the row's path when it has one (e.g. a OneNote section), else
  // the notebook key.
  signal newRequested(string target)
  signal treeToggled(string path)
  signal actionRequested(string id)
  signal footerActionRequested(var action, string value)
  signal deleteRequested(string path)
  // `paths` is the notebook's notes in the order the drag left them on
  // screen — the model has not heard about the moves yet (see visualModel).
  signal reorderFinished(string notebook, var paths)

  // Air between rows. A slot is a control's height plus this, and the card
  // sits inside the slot with this much between it and its neighbours, so
  // the gap reads the same whether or not a row is lit.
  readonly property int rowGap: Style.spacing.xs
  readonly property int rowHeight: Math.max(Style.space(52), root.noteFontSize * 2 + Style.space(20)) + rowGap
  // The page's own margin. The rows sit inside it, so a title never starts on
  // the panel's edge and the list has air above and below it.
  readonly property real pagePadding: Style.spacing.sm
  readonly property real textInset: Style.spacing.lg
  // Rows draw as rounded pills; the search panel's rows measure the same way.
  readonly property real rowRadius: Math.min(Style.cornerRadius, Style.space(6))

  readonly property color page: Qt.tint(root.background, Util.alpha(root.foreground, 0.018))
  readonly property color selectionFill: Qt.tint(page, Util.alpha(root.accent, 0.22))

  // Whichever list is on screen: the search panel replaces the main list
  // while a filter is on, and a keyboard move must scroll the one visible.
  function positionViewAtIndex(i, mode) {
    if (root.filtering) {
      searchPanel.positionViewAtIndex(i, mode)
    } else {
      listView.positionViewAtIndex(i, mode)
    }
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

  function activateFooterAction(provider, path) {
    for (var i = 0; i < footerButtons.count; i++) {
      var button = footerButtons.itemAt(i)
      if (button.modelData.provider === provider && button.modelData.path === path) {
        if (button.editable) {
          button.startEditing()
        } else {
          button.clicked()
        }
        return true
      }
    }
    return false
  }

  // Different font sizes share the toolbar's center by their visible letters,
  // independent of baseline spacing or the header's bottom divider.
  component HeaderLabel: Text {
    id: label
    readonly property rect inkBounds: metrics.tightBoundingRect(
      metrics.elidedText(text, elide, width))
    y: (root.headerContentHeight - inkBounds.height) / 2 - baselineOffset - inkBounds.y
    textFormat: Text.PlainText
    font.family: root.fontFamily

    FontMetrics {
      id: metrics
      font: label.font
    }
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

    Rectangle {
      id: notebookHeader
      width: parent.width
      height: root.headerHeight
      color: Qt.tint(root.background, Util.alpha(root.foreground, 0.07))
      HeaderLabel {
        id: countLabel
        objectName: "notebookHeaderCount"
        anchors.left: parent.left
        anchors.leftMargin: root.pagePadding + root.textInset
        text: root.noteCount + (root.noteCount === 1 ? " note" : " notes")
        color: Util.alpha(root.foreground, 0.45)
        font.pixelSize: Style.font.bodySmall
      }
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: Style.spacing.hairline
        color: Util.alpha(root.foreground, 0.1)
      }
    }

    Item {
      id: contentArea
      anchors.fill: parent
      anchors.margins: root.pagePadding
      anchors.topMargin: root.headerHeight + root.pagePadding

      // Search and the note tree share the area above the fixed footer.
      SearchResults {
        id: searchPanel
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        visible: root.filtering
        model: root.filtering ? root.model : []
        loading: root.searchBusy
        status: root.searchStatus
        currentPath: root.currentPath
        notebook: root.activeName
        foreground: root.foreground
        accent: root.accent
        selectionAccent: root.activeBase
        selectedBackground: root.selectionFill
        selectedText: root.foreground
        fontFamily: root.fontFamily
        noteFontSize: root.noteFontSize
        titleFor: root.titleFor
        rowHeight: root.rowHeight
        rowGap: root.rowGap
        rowRadius: root.rowRadius
        textInset: root.textInset
        onActivated: function(path) { root.activated(path) }
      }

      Item {
        id: listArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        visible: !root.filtering

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
            readonly property real itemHeight: isNote ? root.rowHeight : Style.spacing.controlHeight + root.rowGap
            // Where this row sits on screen while a drag shuffles the order.
            readonly property int visualIndex: slot.DelegateModel.itemsIndex
            width: listView.width
            height: isNew && !root.hasTree ? 0 : itemHeight
            visible: height > 0

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
              objectName: "noteRow-" + slot.modelData.path
              x: Style.spacing.xxs
              width: slot.width - Style.spacing.xxs * 2
              height: slot.itemHeight - root.rowGap
              anchors.verticalCenter: parent.verticalCenter
              radius: root.rowRadius
              readonly property bool current: slot.isNote
                ? slot.modelData.path === root.currentPath
                : slot.isTree && slot.modelData.path === root.treeCursor
              color: current ? root.selectionFill : (rowHover.hovered ? Util.alpha(root.foreground, 0.05) : "transparent")
              // Action rows ("New note…", sign in/out, settings) are dimmed so
              // notes stand out from the things you can do; hover lifts them.
              // Dimmed, not faint: opacity fades toward whichever background
              // the theme has, so this number means the same on all of them.
              opacity: dragArea.drag.active ? 0.85 : ((slot.isNew || slot.isAction) && !rowHover.hovered ? 0.65 : 1)

              HoverHandler { id: rowHover }

              NoteSummary {
                visible: slot.isNote
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: root.textInset + slot.indent
                anchors.rightMargin: Style.spacing.sm + (closeButton.opacity > 0 ? closeButton.width : 0)
                anchors.verticalCenter: parent.verticalCenter
                title: root.titleFor(slot.modelData.title, slot.modelData.preview)
                hasTitle: slot.modelData.hasTitle !== false
                preview: slot.modelData.preview || ""
                modified: slot.modelData.modified || ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: root.noteFontSize
              }

              Row {
                visible: !slot.isNote
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: root.textInset + slot.indent
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md
                Text {
                  text: slot.isNew ? "+" : (slot.isAction ? (slot.modelData.icon || "󰊻")
                    : (slot.modelData.expanded ? "󰅀" : "󰅂"))
                  color: root.accentInk
                  font.family: Style.fontFamily
                  font.pixelSize: Style.font.iconSmall
                }
                Text {
                  width: Math.max(0, parent.width - Style.font.iconSmall - parent.spacing)
                  text: slot.isNew ? "New note…" : slot.modelData.title
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.bold: slot.isTree
                  font.family: root.fontFamily
                  font.pixelSize: slot.isTree ? root.noteFontSize : Style.font.bodySmall
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

              // Available on the current or hovered row, without shifting it.
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

        // ---- there is more: these fades, and the track on the panel's own
        // edge below, as in Toolroll
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

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !root.model.some(function(item) { return item.kind === "note" || item.kind === "tree" || item.kind === "action" })
          text: root.activeName ? "No notes yet" : "No notebooks yet"
          color: Util.alpha(root.foreground, 0.65)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      // Providers supply every footer action; all share one row component.
      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        Item {
          visible: footerButtons.count > 0
          width: parent.width
          height: Style.spacing.hairline + Style.spacing.sm

          Rectangle {
            x: -root.pagePadding
            width: parent.width + root.pagePadding * 2
            height: Style.spacing.hairline
            color: Util.alpha(root.foreground, 0.1)
          }
        }

        Repeater {
          id: footerButtons
          model: root.footerActions
          delegate: SidebarAction {
            required property var modelData
            objectName: "footerAction-" + modelData.provider + "-" + modelData.path
            width: footer.width
            height: Style.space(32)
            text: modelData.title
            iconText: modelData.icon || ""
            editable: !!modelData.inputPlaceholder
            placeholderText: modelData.inputPlaceholder || ""
            foreground: root.foreground
            accent: root.accent
            iconColor: root.accentInk
            fontFamily: root.fontFamily
            textInset: root.textInset
            rowGap: root.rowGap
            rowRadius: root.rowRadius
            onClicked: root.footerActionRequested(modelData, "")
            onSubmitted: function(value) { root.footerActionRequested(modelData, value) }
          }
        }
      }
    }

    // The track rides the panel's own edge, not the page margin: a bar held a
    // margin's width inside the edge reads as a stray line beside the list
    // rather than as the list's end. It keeps a hair of clearance so it does
    // not touch the separator beyond it. It still spans only the rows it
    // scrolls, excluding the shared footer below them.
    Rectangle {
      id: scrollTrack
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xs
      anchors.top: contentArea.top
      anchors.bottom: contentArea.bottom
      anchors.bottomMargin: footer.height
      width: Style.space(3)
      visible: !root.filtering && listArea.scrollable
      color: "transparent"

      Rectangle {
        width: parent.width
        radius: width / 2
        height: Math.max(Style.space(24),
                         scrollTrack.height * (listView.height / Math.max(1, listView.contentHeight)))
        // ListView's origin can shift when rows change above the viewport.
        y: (scrollTrack.height - height)
           * Math.max(0, Math.min(1, (listView.contentY - listView.originY) / Math.max(1, listView.contentHeight - listView.height)))
        color: Util.alpha(root.foreground, listView.moving ? 0.45 : 0.2)
        Behavior on color { ColorAnimation { duration: 150 } }
      }
    }
  }
}
