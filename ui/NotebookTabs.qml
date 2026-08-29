import QtQuick
import qs.Commons
import qs.Ui
import "TabColors.js" as TabColors

// Source tabs keep the useful vertical labels of the original binder, but
// use restrained desktop styling: a faint provider wash, a fine outline and
// one crisp edge where the active source meets the navigation pane.
Item {
  id: root

  property var sections: []
  property var matchCounts: ({})
  property string activeKey: ""
  property bool filtering: false
  property color foreground: Color.menu.text
  property string fontFamily: "sans-serif"
  signal activated(string key)

  readonly property color activeBase: {
    for (var i = 0; i < root.sections.length; i++)
      if (root.sections[i].key === root.activeKey)
        return TabColors.baseFor(root.sections[i].color || "", root.sections[i].name || "")
    return Color.menu.background
  }
  readonly property real minTabHeight: Style.space(72)
  readonly property real maxTabHeight: Style.space(136)
  readonly property real tabGap: Style.spacing.xxs
  readonly property real logoSize: Style.font.iconSmall
  readonly property real logoRoom: logoSize + Style.spacing.md
  readonly property real countRoom: Style.font.caption + Style.spacing.sm

  Rectangle {
    anchors.fill: parent
    color: Qt.tint(Color.menu.background, Util.alpha(root.foreground, 0.025))

    Rectangle {
      anchors.right: parent.right
      width: Math.max(1, Style.spacing.hairline)
      height: parent.height
      color: Util.alpha(root.foreground, 0.1)
    }
  }

  Flickable {
    id: rail
    anchors.fill: parent
    anchors.topMargin: Style.spacing.sm
    anchors.bottomMargin: Style.spacing.sm
    contentHeight: stack.height
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    clip: true

    ListWheel { flick: rail }

    Column {
      id: stack
      width: rail.width
      spacing: root.tabGap

      Repeater {
        model: root.sections

        delegate: Item {
          id: tab
          required property var modelData
          readonly property bool current: modelData.key === root.activeKey
          readonly property int hits: root.matchCounts[modelData.key] || 0
          readonly property bool dimmed: root.filtering && hits === 0
          readonly property color base: TabColors.baseFor(modelData.color || "", modelData.name || "")
          readonly property int shownCount: root.filtering ? hits : (modelData.count || 0)
          readonly property bool hasLogo: String(modelData.logo || "").length > 0
          readonly property real topRoom: hasLogo ? root.logoRoom : Style.spacing.md
          width: stack.width
          height: Math.max(root.minTabHeight,
                           Math.min(root.maxTabHeight,
                                    labelMetrics.width + topRoom + root.countRoom + Style.spacing.lg))

          TextMetrics {
            id: labelMetrics
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: tab.modelData.name || "Notes"
          }

          HoverHandler { id: tabHover }

          Rectangle {
            id: card
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.xs
            anchors.rightMargin: Style.spacing.xs
            radius: Math.min(Style.cornerRadius, Style.space(8))
            color: tab.current
              ? Qt.tint(Color.menu.background, Util.alpha(tab.base, 0.16))
              : (tabHover.hovered
                  ? Qt.tint(Color.menu.background, Util.alpha(tab.base, 0.09))
                  : Qt.tint(Color.menu.background, Util.alpha(tab.base, 0.045)))
            border.width: Math.max(1, Style.spacing.hairline)
            border.color: Util.alpha(tab.base, tab.current ? 0.72 : (tabHover.hovered ? 0.42 : 0.2))
            opacity: tab.dimmed ? 0.38 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }

            // The active edge points into the pane it controls; unlike the
            // old full-colour divider, it does not need to become the pane.
            Rectangle {
              anchors.right: parent.right
              anchors.rightMargin: -1
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(2)
              height: parent.height - Style.spacing.md * 2
              radius: width / 2
              color: tab.base
              opacity: tab.current ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 120 } }
            }
          }

          Image {
            id: logo
            visible: status === Image.Ready
            source: tab.modelData.logo || ""
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.md
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.logoSize
            height: root.logoSize
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            smooth: true
            opacity: tab.dimmed ? 0.45 : 0.9
          }

          Text {
            id: label
            anchors.centerIn: parent
            anchors.verticalCenterOffset: (tab.topRoom - root.countRoom) / 2
            width: Math.max(0, tab.height - tab.topRoom - root.countRoom - Style.spacing.lg)
            height: card.width
            rotation: -90
            text: tab.modelData.name || "Notes"
            color: Qt.tint(root.foreground, Util.alpha(tab.base, TabColors.inkAlpha()))
            opacity: tab.dimmed ? 0.45 : 1
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.sm
            anchors.horizontalCenter: parent.horizontalCenter
            text: tab.shownCount > 999 ? "999+" : String(tab.shownCount)
            color: Util.alpha(Qt.tint(root.foreground,
                                      Util.alpha(tab.base, TabColors.inkAlpha())), 0.72)
            opacity: tab.dimmed ? 0.45 : 1
            font.family: root.fontFamily
            font.pixelSize: Math.max(8, Style.font.caption - 1)
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activated(tab.modelData.key)
          }

          PanelToolTip {
            visible: tabHover.hovered && labelMetrics.width > label.width
            text: (tab.modelData.name || "Notes") + " · " + tab.shownCount
          }
        }
      }
    }
  }
}
