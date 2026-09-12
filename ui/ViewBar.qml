import QtQuick
import qs.Commons
import qs.Ui

// Provider badge, breadcrumb, word count, save state and the sidebar toggle.
Item {
  id: root

  property string sourceName: ""
  property url sourceLogo: ""
  property color sourceInk: Color.menu.text
  property color sourceBase: "transparent"
  property string crumb: ""
  property string storage: ""
  // Some providers include their name in the breadcrumb; the badge owns it.
  readonly property string shownCrumb: {
    if (root.crumb === root.sourceName) {
      return ""
    }
    if (root.sourceName && root.crumb.indexOf(root.sourceName + " › ") === 0) {
      return root.crumb.substring(root.sourceName.length + 3)
    }
    return root.crumb
  }
  // The note holds edits not yet confirmed saved: dirty, or a save in flight.
  property bool unsaved: false
  property string statusText: ""
  property string hoveredLink: ""
  readonly property bool previewingLink: hoveredLink.length > 0
  property int wordCount: 0
  property bool countVisible: false
  // The sidebar is folded away: the toggle then points the way back.
  property bool listCollapsed: false
  signal listToggled()
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  // One size for every caption on the bar.
  property int fontSize: Style.font.caption
  // The bar sits flush along the bottom of whatever hosts it. In the overlay
  // that host is a rounded card whose border is painted under the content,
  // so a bottom corner the bar reaches must curve with it or it squares the
  // card off. Each corner is the host's to set: the bar may stop short of
  // one, against the sidebar, and reach the other.
  property real leftRadius: 0
  property real rightRadius: 0
  // Every control and caption occupies the same row, including icon fonts
  // whose line metrics differ from the caption font.
  readonly property real verticalPadding: Style.space(4)
  readonly property real controlHeight: Math.max(Style.space(20),
    Math.ceil(captionMetrics.height) + Style.space(4) + 2)
  readonly property real controlRadius: Math.min(Style.cornerRadius, Style.space(4))
  height: controlHeight + verticalPadding * 2

  FontMetrics {
    id: captionMetrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  // Center the visible icon, independent of its font's baseline and bearings.
  component StatusGlyph: Item {
    id: symbol
    required property string text
    required property color color
    required property real fontSize
    implicitWidth: fontSize

    TextMetrics {
      id: metrics
      font: glyph.font
      text: symbol.text
    }

    Text {
      id: glyph
      x: (parent.width - metrics.tightBoundingRect.width) / 2 - metrics.tightBoundingRect.x
      y: (parent.height - metrics.tightBoundingRect.height) / 2
        - baselineOffset - metrics.tightBoundingRect.y
      text: symbol.text
      textFormat: Text.PlainText
      color: symbol.color
      font.family: Style.fontFamily
      font.pixelSize: symbol.fontSize
      renderType: Text.NativeRendering
    }
  }

  Rectangle {
    anchors.fill: parent
    color: root.background
    bottomLeftRadius: root.leftRadius
    bottomRightRadius: root.rightRadius
  }
  Rectangle {
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(root.foreground, 0.09)
  }
  Button {
    id: toggle
    objectName: "sidebarToggle"
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.md
    y: root.verticalPadding
    height: root.controlHeight
    width: Math.max(Style.space(24), height)
    radius: root.controlRadius
    borderSpec: Border.flat(Util.alpha(root.foreground, hot ? 0.45 : 0.2), 1)
    background: Util.alpha(root.foreground, 0.06)
    foreground: root.foreground
    accent: root.accent
    tooltipText: root.listCollapsed ? "Show sidebar (ctrl+e)" : "Hide sidebar (ctrl+e)"
    Accessible.role: Accessible.Button
    Accessible.name: root.listCollapsed ? "Show sidebar" : "Hide sidebar"
    onClicked: root.listToggled()

    StatusGlyph {
      anchors.fill: parent
      text: root.listCollapsed ? "󰅂" : "󰅁"
      color: root.foreground
      fontSize: Style.font.iconSmall
    }
  }

  Rectangle {
    id: sourceBlock
    objectName: "providerBadge"
    visible: root.sourceName.length > 0
    anchors.left: toggle.right
    anchors.leftMargin: Style.spacing.xs
    y: root.verticalPadding
    height: root.controlHeight
    width: sourceContent.implicitWidth + Style.spacing.lg * 2
    radius: root.controlRadius
    border.width: 1
    border.color: Util.alpha(root.sourceInk, 0.3)
    color: root.sourceBase.a > 0 ? Util.alpha(root.sourceBase, 0.16)
      : Util.alpha(root.foreground, 0.05)

    Row {
      id: sourceContent
      anchors.centerIn: parent
      height: parent.height
      spacing: Style.spacing.xs

      Image {
        visible: status === Image.Ready
        source: root.sourceLogo
        anchors.verticalCenter: parent.verticalCenter
        anchors.alignWhenCentered: false
        width: root.fontSize
        height: root.fontSize
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        fillMode: Image.PreserveAspectFit
        smooth: true
      }

      Text {
        objectName: "providerLabel"
        height: parent.height
        verticalAlignment: Text.AlignVCenter
        width: Math.min(implicitWidth, Style.space(160))
        text: root.sourceName
        textFormat: Text.PlainText
        color: root.sourceInk
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        elide: Text.ElideRight
      }
    }
  }

  Text {
    id: context
    objectName: "statusContext"
    anchors.left: sourceBlock.visible ? sourceBlock.right : toggle.right
    anchors.leftMargin: Style.spacing.lg
    anchors.right: details.left
    anchors.rightMargin: Style.spacing.lg
    y: root.verticalPadding
    height: root.controlHeight
    verticalAlignment: Text.AlignVCenter
    visible: !root.previewingLink
    text: root.statusText
      || [root.shownCrumb, root.storage].filter(function(part) { return !!part }).join(" › ")
    color: root.statusText ? Qt.tint(root.foreground, Util.alpha(root.accent, 0.55))
      : Util.alpha(root.foreground, 0.55)
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    elide: Text.ElideRight
  }

  Text {
    objectName: "linkPreview"
    visible: root.previewingLink
    anchors.fill: context
    verticalAlignment: Text.AlignVCenter
    text: root.hoveredLink
    color: Qt.tint(root.foreground, Util.alpha(root.accent, 0.55))
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    elide: Text.ElideMiddle
  }

  Row {
    id: details
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.lg
    y: root.verticalPadding
    height: root.controlHeight
    spacing: Style.spacing.md
    Text {
      objectName: "wordCount"
      height: parent.height
      verticalAlignment: Text.AlignVCenter
      visible: root.countVisible && !root.previewingLink
      text: root.wordCount + (root.wordCount === 1 ? " word" : " words")
      color: Util.alpha(root.foreground, 0.45)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
    }
    StatusGlyph {
      objectName: "saveIndicator"
      height: parent.height
      visible: root.countVisible && !root.previewingLink && root.storage !== "loading…"
      text: root.unsaved ? "●" : "󰄬"
      color: Qt.tint(root.foreground, Util.alpha(root.accent, 0.6))
      fontSize: root.fontSize
    }
    Text {
      objectName: "saveStatus"
      height: parent.height
      verticalAlignment: Text.AlignVCenter
      visible: root.previewingLink || root.countVisible
      text: root.previewingLink ? "Click to open" : (root.unsaved ? "Unsaved" :
        (root.storage === "loading…" ? "Loading…" : (root.storage === "read-only here" ? "Read-only" : "Saved")))
      color: Util.alpha(root.foreground, 0.5)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
    }
  }
}
