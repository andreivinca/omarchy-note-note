import QtQuick
import qs.Commons
import qs.Ui

// The view bar — the status strip a desktop app keeps along its bottom edge.
// Left to right it answers: whose notes these are (the open tab's source, a
// full-height segment in the tab's own wash, flush with the bar's corner the
// way an IDE's remote badge is), where the open note lives (the provider's
// crumb, then the storage word), whether everything is put away (the unsaved
// dot), what just happened (the transient status), and how much is written
// (the word count).
//
// Every caption in the bar shares one text line: the source label is placed
// once, on a whole pixel, and everything else either carries the same font
// metrics at the same y or centers on it. Nothing here is nested in a padded
// box of its own — that is what put a label half a pixel off the line.
//
// Presentation only: every value arrives bound from the host, and nothing
// here signals back — a status strip is read, not driven.
Item {
  id: root

  // The open tab's source: the provider's name and logo, in the tab's ink,
  // over a wash of the tab's own colour (see the host's rebuildRows).
  property string sourceName: ""
  property url sourceLogo: ""
  property color sourceInk: Color.menu.text
  property color sourceBase: "transparent"
  // Where the open note lives: the provider's breadcrumb, then the storage
  // word beside it ("note-….md", "synced online", "read-only here").
  property string crumb: ""
  property string storage: ""
  // Providers wrote their crumbs for a line that stood alone, so some open
  // with their own name; beside a segment that already says it, that reads
  // twice. Presentation only, and no provider named: the segment's own text
  // is what gets folded away, whichever provider wrote it.
  readonly property string shownCrumb: {
    if (crumb === sourceName) {
      return ""
    }
    if (crumb.indexOf(sourceName + " › ") === 0) {
      return crumb.substring(sourceName.length + 3)
    }
    return crumb
  }
  // The note holds edits not yet confirmed saved: dirty, or a save in flight.
  property bool unsaved: false
  property string statusText: ""
  property int wordCount: 0
  property bool countVisible: false
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  // The bar sits flush along the bottom of whatever hosts it. In the overlay
  // that host is a rounded card whose border is painted under the content,
  // so the bar's bottom corners must curve with it or they square it off.
  property real cornerRadius: 0

  height: Style.space(26)

  Rectangle {
    anchors.fill: parent
    color: Qt.tint(root.background, Util.alpha(root.foreground, 0.015))
    bottomLeftRadius: root.cornerRadius
    bottomRightRadius: root.cornerRadius
  }

  Rectangle {
    id: topRule
    anchors.top: parent.top
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(root.foreground, 0.1)
  }

  // The source segment: the bar's own height under the hairline, flush with
  // the left edge — a block of the bar, not a pill floating on it. Sized off
  // its label, which is laid out first (below) and is the whole bar's line.
  Rectangle {
    id: sourceBlock
    visible: root.sourceName.length > 0
    anchors.left: parent.left
    anchors.top: topRule.bottom
    anchors.bottom: parent.bottom
    width: sourceLabel.x + sourceLabel.width + Style.spacing.lg
    // The tab's colour said quietly; without a tab yet, the neutral fill
    // every theme has.
    color: root.sourceBase.a > 0 ? Util.alpha(root.sourceBase, 0.16)
                                 : Util.alpha(root.foreground, 0.05)
    bottomLeftRadius: root.cornerRadius
  }

  Image {
    id: sourceLogoMark
    visible: root.sourceName.length > 0 && status === Image.Ready
    source: root.sourceLogo
    x: Style.spacing.lg
    anchors.verticalCenter: sourceLabel.verticalCenter
    width: Style.font.caption
    height: Style.font.caption
    sourceSize.width: Style.font.caption * 2
    sourceSize.height: Style.font.caption * 2
    fillMode: Image.PreserveAspectFit
    smooth: true
  }

  // The bar's reference line. Placed on a whole pixel — every other caption
  // is this label's own metrics at this label's own y, so the bar cannot
  // disagree with itself about where its one line of text sits.
  Text {
    id: sourceLabel
    visible: root.sourceName.length > 0
    textFormat: Text.PlainText
    x: Style.spacing.lg + (sourceLogoMark.visible ? sourceLogoMark.width + Style.spacing.xs : 0)
    y: Math.round((parent.height - height) / 2)
    text: root.sourceName
    color: root.sourceInk
    Behavior on color { ColorAnimation { duration: 150 } }
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    id: contextRow
    anchors.left: sourceBlock.visible ? sourceBlock.right : parent.left
    anchors.leftMargin: Style.spacing.lg
    y: sourceLabel.y
    spacing: Style.spacing.md

    Text {
      textFormat: Text.PlainText
      visible: root.shownCrumb.length > 0
      // Capped, not implicit: a deep OneNote crumb must not push the
      // status and the count off the bar.
      width: Math.min(implicitWidth, Style.space(280))
      text: root.shownCrumb
      color: Util.alpha(root.foreground, 0.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      visible: root.shownCrumb.length > 0 && root.storage.length > 0
      text: "·"
      color: Util.alpha(root.foreground, 0.35)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: root.storage.length > 0
      width: Math.min(implicitWidth, Style.space(220))
      text: root.storage
      color: Util.alpha(root.foreground, 0.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    // The unsaved dot, the way an editor marks a modified tab. It shows
    // for the beat between a keystroke and its save landing, so most of
    // the time it is the quiet proof that autosave has kept up. Centered
    // on the row rather than baselined: the glyph may come from a symbol
    // font whose baseline is its own, and a dot has no baseline to read.
    Text {
      textFormat: Text.PlainText
      visible: root.unsaved
      anchors.verticalCenter: parent.verticalCenter
      text: "●"
      color: Qt.tint(root.foreground, Util.alpha(root.accent, 0.6))
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // The band between the context and the count belongs to status
  // messages — a save's error, "Section created", a rate-limit
  // countdown; it sits empty otherwise.
  Text {
    textFormat: Text.PlainText
    visible: root.statusText.length > 0
    anchors.left: contextRow.right
    anchors.leftMargin: Style.spacing.lg
    anchors.right: counter.visible ? counter.left : parent.right
    anchors.rightMargin: Style.spacing.lg
    y: sourceLabel.y
    text: root.statusText
    color: Qt.tint(root.foreground, Util.alpha(root.accent, 0.6))
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignRight
  }

  Text {
    id: counter
    textFormat: Text.PlainText
    visible: root.countVisible
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.lg
    y: sourceLabel.y
    text: root.wordCount + (root.wordCount === 1 ? " word" : " words")
    color: Util.alpha(root.foreground, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
