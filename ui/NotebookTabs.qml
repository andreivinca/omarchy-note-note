import QtQuick
import qs.Commons
import qs.Ui
import "TabColors.js" as TabColors

// The binder edge: one tab per top-level section — every local notebook, then
// each provider — stacked from the top, rounded like a paper divider and cut
// straight where the open one meets the list. The label is turned a quarter
// turn; the number under it is the section's note count.
//
// Sections are { key, name, color, logo, count, matches }. `color` is the
// provider's own, given raw: pastelising and washing it is this file's
// business, so a provider states its identity and never has to think about the
// theme. `logo` is optional — a provider that has a mark shows it at the head
// of its tabs, and one that does not (the local notebooks) simply does not.
Item {
  id: root

  property var sections: []
  property string activeKey: ""
  property bool filtering: false
  property color foreground: Color.menu.text
  signal activated(string key)

  // The open tab's colour, for the panel it is joined to.
  readonly property color activeBase: {
    for (var i = 0; i < root.sections.length; i++)
      if (root.sections[i].key === root.activeKey)
        return TabColors.baseFor(root.sections[i].color || "", root.sections[i].name || "")
    return Color.menu.background
  }

  readonly property real minHeight: Style.space(46)
  readonly property real maxHeight: Style.space(150)
  readonly property real gap: Style.spacing.xxs
  // Every tab is the same tab: same wash, same square inner edge. The open one
  // is simply the one that reaches the panel — the others stop a hair short, so
  // only the open one is joined to the page it divides.
  readonly property real backset: 2
  readonly property real endPadding: Style.spacing.lg * 2
  readonly property real logoSize: Style.font.icon
  readonly property real logoTop: Style.spacing.lg

  // A tab is as long as its label needs. When the whole stack would not fit,
  // every tab is squeezed by the same factor first — paper dividers are all the
  // same size — and only when that hits the floor does the rail scroll.
  property real squeeze: 1

  TextMetrics {
    id: probe
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  function naturalHeight(section) {
    probe.text = (section && section.name) || ""
    var extra = (section && section.logo) ? root.logoTop + root.logoSize + Style.spacing.xs : 0
    return Util.clamp(probe.width + root.endPadding + Style.space(12) + extra, root.minHeight, root.maxHeight)
  }

  // A function, not a binding: a binding that assigns probe.text and then reads
  // probe.width declares a dependency on the very thing it mutates.
  function relayout() {
    var total = 0
    for (var i = 0; i < root.sections.length; i++) total += naturalHeight(root.sections[i]) + root.gap
    root.squeeze = (total > root.height && total > 0) ? Math.max(0.45, root.height / total) : 1
  }

  onSectionsChanged: relayout()
  onHeightChanged: relayout()
  Component.onCompleted: relayout()

  Flickable {
    id: rail
    anchors.fill: parent
    contentHeight: stack.height
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    clip: true

    // Same wheel treatment as the note list: touchpad pixels scaled, a mouse
    // notch a fixed step.
    WheelHandler {
      target: null
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) {
        var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 3 : (event.angleDelta.y / 120) * Style.space(72)
        rail.contentY = Math.max(0, Math.min(rail.contentY - dy, Math.max(0, rail.contentHeight - rail.height)))
      }
    }

    Column {
      id: stack
      width: rail.width
      spacing: root.gap

      Repeater {
        model: root.sections

        delegate: Item {
          id: tab
          required property var modelData
          // Not `active`: the house rule after the `opened` collision is to
          // stay clear of Qt's own property names.
          readonly property bool current: modelData.key === root.activeKey
          readonly property bool dimmed: root.filtering && (modelData.matches || 0) === 0
          readonly property color base: TabColors.baseFor(modelData.color || "", modelData.name || "")

          // A closed tab stops a hair short of the panel; the open one runs into
          // it. That is the whole of what says which tab you are on.
          width: stack.width - (current ? 0 : root.backset)
          // …and it is all it says: the mark, the label and the count are
          // centred on the rail rather than on the tab, so opening a tab does
          // not slide its own text sideways by the width of that hair.
          readonly property real centred: (stack.width - width) / 2
          readonly property real logoRoom: logo.status === Image.Ready ? root.logoTop + logo.height + Style.spacing.xs : 0
          height: Math.round(Util.clamp(metrics.width + root.endPadding + countText.height + logoRoom,
                                        root.minHeight, root.maxHeight) * root.squeeze)
          clip: true

          TextMetrics { id: metrics; font: label.font; text: tab.modelData.name || "" }
          HoverHandler { id: tabHover }

          Rectangle {
            anchors.left: parent.left
            height: parent.height
            width: parent.width
            color: Util.alpha(tab.base, TabColors.fillAlpha())
            opacity: tab.dimmed ? 0.35 : 1
            Behavior on color { ColorAnimation { duration: 150 } }
            Behavior on opacity { NumberAnimation { duration: 150 } }
          }

          // The provider's own mark, at the head of its tab. Shown exactly as it
          // was given: a provider that ships a logo has already decided what it
          // looks like. SVG or raster both load; sourceSize keeps an SVG sharp.
          Image {
            id: logo
            visible: status === Image.Ready
            source: tab.modelData.logo || ""
            anchors.top: parent.top
            anchors.topMargin: root.logoTop
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: tab.centred
            width: root.logoSize
            height: root.logoSize
            sourceSize.width: root.logoSize * 2
            sourceSize.height: root.logoSize * 2
            fillMode: Image.PreserveAspectFit
            smooth: true
            opacity: tab.dimmed ? 0.5 : 1
          }

          // Laid out along the tab's length, then turned about its own centre —
          // so `width` here is the run of the text and `height` its thickness.
          Text {
            id: label
            textFormat: Text.PlainText
            anchors.centerIn: parent
            anchors.verticalCenterOffset: (tab.logoRoom - countText.height) / 2
            anchors.horizontalCenterOffset: tab.centred
            width: tab.height - root.endPadding - countText.height - tab.logoRoom
            height: tab.width
            rotation: -90
            text: tab.modelData.name || ""
            color: root.foreground
            opacity: tab.dimmed ? 0.5 : 1
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          // Left upright: one to three digits read fine across a 30 px rail,
          // and a second rotated Text would need its own offset gymnastics.
          Text {
            id: countText
            textFormat: Text.PlainText
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.xs
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: tab.centred
            text: root.filtering ? String(tab.modelData.matches || 0) : String(tab.modelData.count || 0)
            color: Util.alpha(root.foreground, 0.55)
            opacity: tab.dimmed ? 0.5 : 1
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activated(tab.modelData.key)
          }

          // A long name does not fit in 46 px of tab.
          PanelToolTip {
            visible: tabHover.hovered && metrics.width > label.width
            text: tab.modelData.name || ""
          }
        }
      }
    }
  }
}
