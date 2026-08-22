import QtQuick
import qs.Commons
import qs.Ui

// The left-hand picker, in the shape of Toolroll's tool list: notes grouped
// under collapsible notebook headings, a "New note…" row at the end of each
// notebook, and a "New notebook…" row at the bottom. Rows can be dragged to
// reorder within their notebook (only while no filter is active).
//
// Model rows carry { kind, notebook, path, title, preview }:
//   kind "note"        a note (fixed: true → not draggable)
//   kind "new"         the "+ New note…" row of a notebook
//   kind "action"      a clickable row: `path` is the action id, `title` its
//                      label, `icon` its glyph
//   kind "tree"        an expandable group inside a notebook (OneNote
//                      notebook / section): `path` is its id, `expanded`
//                      its state; rows are indented by `level`
//   kind "placeholder" a zero-height row that keeps a collapsed heading alive
Item {
  id: root

  property alias model: listView.model
  property string currentPath: ""
  property bool filtering: false
  property var collapsed: []
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
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
  signal sectionToggled(string notebook)
  signal moveRequested(string fromPath, string toPath)
  signal reorderFinished(string notebook)

  readonly property int rowHeight: Style.spacing.controlHeight + Style.spacing.xs

  // Rows start where a heading's label starts: after its chevron.
  TextMetrics { id: chevronMetrics; text: "󰅀"; font.family: Style.fontFamily; font.pixelSize: Style.font.iconSmall }
  readonly property real rowIndent: chevronMetrics.width + Style.spacing.xs

  function isCollapsed(nb) { return root.collapsed.indexOf(nb) >= 0 }
  // Section strings are "key\u001fname\u001fcount" (see Notes.qml groupOf);
  // the root notebook's key is written as "/".
  function keyOf(group) { var k = group.split("\u001f")[0]; return k === "/" ? "" : k }
  function nameOf(group) { return group.split("\u001f")[1] || "" }
  function countOf(group) { return group.split("\u001f")[2] || "0" }

  function positionViewAtIndex(i, mode) { listView.positionViewAtIndex(i, mode) }

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

  function startNewNotebook() {
    newNotebookRow.editing = true
    notebookField.text = ""
    notebookField.forceActiveFocus()
  }

  Column {
    anchors.fill: parent
    spacing: 0

    Item {
      width: parent.width
      height: parent.height - newNotebookRow.height

      ListView {
        id: listView
        anchors.fill: parent
        clip: true
        spacing: 0
        boundsBehavior: Flickable.StopAtBounds
        displaced: Transition { NumberAnimation { properties: "y"; duration: 120; easing.type: Easing.OutQuad } }

        // Flickable moves touchpad scrolls pixel-for-pixel, which feels slow
        // for a long list; scale them, and give a mouse notch a fixed step.
        WheelHandler {
          target: null
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function(event) {
            var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 3 : (event.angleDelta.y / 120) * Style.space(72)
            var max = Math.max(0, listView.contentHeight - listView.height)
            listView.contentY = listView.originY + Math.max(0, Math.min(listView.contentY - listView.originY - dy, max))
          }
        }

        // ---- notebook headings
        section.property: "group"
        section.delegate: Item {
          id: heading
          required property string section
          readonly property string key: root.keyOf(section)
          readonly property bool folded: root.isCollapsed(key)
          width: listView.width
          height: Style.spacing.controlHeight

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.sectionToggled(heading.key)
          }

          Text {
            id: chevron
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xxs
            text: heading.folded ? "󰅂" : "󰅀"
            color: Qt.lighter(root.accent, 1.4)
            font.family: Style.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          PanelSectionHeader {
            id: headingText
            anchors.left: chevron.right
            anchors.leftMargin: Style.spacing.xs
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xxs
            text: root.nameOf(heading.section)
            foreground: Qt.lighter(root.accent, 1.4)
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: headingText.right
            anchors.leftMargin: Style.spacing.xs
            anchors.baseline: headingText.baseline
            text: root.countOf(heading.section)
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- rows
        delegate: Item {
          id: slot
          required property int index
          required property var modelData
          readonly property bool isNote: modelData.kind === "note"
          readonly property bool isNew: modelData.kind === "new"
          readonly property bool isAction: modelData.kind === "action"
          readonly property bool isTree: modelData.kind === "tree"
          readonly property int indent: (modelData.level || 0) * Style.space(14)
          readonly property bool draggable: isNote && !modelData.fixed
          width: listView.width
          height: modelData.kind === "placeholder" ? 0 : root.rowHeight
          visible: modelData.kind !== "placeholder"

          DropArea {
            anchors.fill: parent
            enabled: !root.filtering && slot.draggable
            onEntered: function(drag) {
              if (drag.source.notebook !== slot.modelData.notebook) return
              if (drag.source.path !== slot.modelData.path) root.moveRequested(drag.source.path, slot.modelData.path)
            }
          }

          Rectangle {
            id: row
            width: slot.width
            height: root.rowHeight
            radius: Style.cornerRadius
            readonly property bool current: slot.isNote && slot.modelData.path === root.currentPath
            color: current ? root.selectedBackground
              : (rowHover.hovered ? Style.hoverFill : "transparent")
            opacity: dragArea.drag.active ? 0.85 : 1

            HoverHandler { id: rowHover }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.sm + root.rowIndent + slot.indent
              anchors.rightMargin: Style.spacing.sm
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: Style.font.icon + Style.space(2)
                text: slot.isNew ? "+" : (slot.isAction ? (slot.modelData.icon || "󰊻")
                  : (slot.isTree ? (slot.modelData.expanded ? "󰅀" : "󰅂") : "󰎞"))
                color: slot.isNew || slot.isAction ? root.accent
                  : (slot.isTree ? Qt.lighter(root.accent, 1.4)
                  : (row.current ? root.selectedText : Qt.darker(root.foreground, 1.3)))
                font.family: Style.fontFamily
                font.pixelSize: Style.font.icon
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.font.icon - Style.space(2) - Style.spacing.md
                  - (closeButton.visible ? closeButton.width + Style.spacing.xs : 0)
                text: slot.isNew ? "New note…"
                  : (slot.isAction || slot.isTree ? slot.modelData.title : root.titleFor(slot.modelData.title, slot.modelData.preview))
                color: row.current ? root.selectedText : (slot.isTree ? Qt.lighter(root.accent, 1.4) : root.foreground)
                font.bold: slot.isTree && (slot.modelData.level || 0) === 0
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: dragArea
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              property string path: slot.modelData.path
              property string notebook: slot.modelData.notebook
              drag.target: (root.filtering || !slot.draggable) ? null : row
              drag.axis: Drag.YAxis
              drag.threshold: Style.space(6)
              onClicked: {
                if (slot.isNew) root.newRequested(slot.modelData.path || slot.modelData.notebook)
                else if (slot.isAction) root.actionRequested(slot.modelData.path)
                else if (slot.isTree) root.treeToggled(slot.modelData.path)
                else root.activated(slot.modelData.path)
              }
              onReleased: {
                if (row.Drag.active) { row.Drag.drop(); root.reorderFinished(slot.modelData.notebook) }
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
              opacity: row.current || rowHover.hovered ? 1 : 0.3
              Behavior on opacity { NumberAnimation { duration: 120 } }
              iconText: "󰅖"
              tooltipText: "Delete this note"
              foreground: row.current ? root.selectedText : root.foreground
              accent: root.accent
              iconSize: Style.font.iconSmall
              horizontalPadding: Style.spacing.xs
              verticalPadding: Style.spacing.xxs
              onClicked: root.deleteRequested(slot.modelData.path)
            }

            Drag.active: dragArea.drag.active
            Drag.source: dragArea
            Drag.hotSpot.x: width / 2
            Drag.hotSpot.y: height / 2

            states: State {
              when: dragArea.drag.active
              ParentChange { target: row; parent: listView }
              PropertyChanges { target: row; z: 10 }
            }
          }
        }
      }

      // ---- there is more: fades and a thin track, as in Toolroll
      readonly property bool scrollable: listView.contentHeight > listView.height + 1

      Rectangle {
        anchors.top: parent.top
        width: parent.width
        height: Style.space(18)
        visible: parent.scrollable && !listView.atYBeginning
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(Color.menu.background, 0.95) }
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
          GradientStop { position: 1.0; color: Util.alpha(Color.menu.background, 0.95) }
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
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    // ---- "New notebook…" row; becomes a name field when clicked
    Rectangle {
      id: newNotebookRow
      property bool editing: false
      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius
      color: !editing && newHover.hovered ? Style.hoverFill : "transparent"

      HoverHandler { id: newHover }

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.sm + root.rowIndent
        anchors.rightMargin: Style.spacing.sm
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          width: Style.font.icon + Style.space(2)
          text: newNotebookRow.editing ? "󰉋" : "+"
          color: root.accent
          font.family: Style.fontFamily
          font.pixelSize: Style.font.icon
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: !newNotebookRow.editing
          anchors.verticalCenter: parent.verticalCenter
          text: "New notebook…"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
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
