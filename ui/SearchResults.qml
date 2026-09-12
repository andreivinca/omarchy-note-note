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
  property string status: ""
  property string currentPath: ""
  property string notebook: ""
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color selectionAccent: accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  property int noteFontSize: Style.font.body
  property var titleFor: function(t, p) { return t || p || "Untitled" }

  signal activated(string path)

  // Row geometry, handed down by NoteList: these results stand where its rows
  // stood, so they must measure exactly as its rows do.
  property real rowHeight: Style.spacing.controlHeight
  property real rowGap: Style.spacing.xxs
  property real rowRadius: Math.min(Style.cornerRadius, Style.space(6))
  property real textInset: Style.spacing.md
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
        ? (root.loading ? "Searching…" : (root.status ? "No matches yet in " : "No match in ") + root.notebook)
        : root.count + (root.count === 1 ? " match in " : " matches in ") + root.notebook
          + (root.loading ? " — searching…" : "")
      color: Util.alpha(root.foreground, 0.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      visible: root.status.length > 0
      textFormat: Text.PlainText
      width: parent.width
      leftPadding: root.textInset
      rightPadding: root.textInset
      text: root.status
      color: Util.alpha(root.foreground, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
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

      delegate: Item {
        id: hit
        required property var modelData
        readonly property bool current: modelData.path === root.currentPath
        width: results.width
        height: root.rowHeight

        Rectangle {
          x: Style.spacing.xxs
          width: parent.width - Style.spacing.xxs * 2
          height: root.rowHeight - root.rowGap
          anchors.verticalCenter: parent.verticalCenter
          radius: root.rowRadius
          color: hit.current ? root.selectedBackground : (hitHover.hovered ? Style.hoverFill : "transparent")
          border.width: 0
          border.color: Util.alpha(root.selectionAccent, 0.62)

          HoverHandler { id: hitHover }

          NoteSummary {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: root.textInset
            anchors.rightMargin: Style.spacing.sm
            title: root.titleFor(hit.modelData.title, hit.modelData.preview)
            hasTitle: hit.modelData.hasTitle !== false
            preview: hit.modelData.preview || ""
            modified: hit.modelData.modified || ""
            foreground: hit.current ? root.selectedText : root.foreground
            fontFamily: root.fontFamily
            fontSize: root.noteFontSize
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
}
