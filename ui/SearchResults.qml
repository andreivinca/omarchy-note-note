import QtQuick
import qs.Commons

// What the sidebar becomes while a search is running. It is its own panel on
// purpose: a result is a place you are going, not a row you keep — so there is
// nothing here to drag, no tree to open, no "New note…" and no "New notebook…",
// only what matched. The notebook is named once at the top rather than on every
// row, because only one notebook's matches are ever listed at a time.
//
// Rows are the host's filtered notes: { path, title, preview }.
Item {
  id: root

  property var model: []
  // Content answers are still on their way somewhere: the count line trails
  // "searching…" so what is on show reads as so-far, not as the verdict.
  property bool loading: false
  property string currentPath: ""
  property string notebook: ""
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  property var titleFor: function(t, p) { return t || p || "Untitled" }

  signal activated(string path)

  // Row geometry, handed down by NoteList: these results stand where its rows
  // stood, so they must measure exactly as its rows do.
  property real rowHeight: Style.spacing.controlHeight + Style.spacing.xs
  property real markWidth: Style.space(2)
  property real textInset: markWidth + Style.spacing.md
  readonly property int count: root.model ? root.model.length : 0

  function positionViewAtIndex(i, mode) { results.positionViewAtIndex(i, mode) }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.xs

    // How many, and where you are looking. The tabs say how the rest of the
    // binder answered the same question.
    Text {
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: root.textInset
      text: root.count === 0
        ? (root.loading ? "Searching…" : "No match in " + root.notebook)
        : root.count + (root.count === 1 ? " match in " : " matches in ") + root.notebook
          + (root.loading ? " — searching…" : "")
      color: Util.alpha(root.foreground, 0.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    ListView {
      id: results
      width: parent.width
      height: parent.height - y
      clip: true
      spacing: 0
      boundsBehavior: Flickable.StopAtBounds
      model: root.model

      ListWheel { flick: results }

      delegate: Rectangle {
        id: hit
        required property var modelData
        readonly property bool current: modelData.path === root.currentPath
        width: results.width
        height: root.rowHeight
        color: current ? root.selectedBackground : (hitHover.hovered ? Style.hoverFill : "transparent")

        HoverHandler { id: hitHover }

        Rectangle {
          width: root.markWidth
          height: parent.height
          visible: hit.current
          color: root.accent
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: root.textInset
          anchors.rightMargin: Style.spacing.sm
          text: root.titleFor(hit.modelData.title, hit.modelData.preview)
          color: hit.current ? root.selectedText : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.activated(hit.modelData.path)
        }
      }
    }
  }
}
