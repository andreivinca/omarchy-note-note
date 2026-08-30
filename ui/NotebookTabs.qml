import QtQuick
import qs.Commons
import qs.Ui
import "TabColors.js" as TabColors

// A quiet activity rail: one simple button per source. The icon keeps provider
// identity and the vertical name distinguishes local notebooks, while the
// surrounding control stays neutral and consistent with the desktop chrome.
Item {
  id: root

  property var sections: []
  property var matchCounts: ({})
  property string activeKey: ""
  property bool filtering: false
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  signal activated(string key)

  readonly property color activeBase: {
    for (var i = 0; i < root.sections.length; i++)
      if (root.sections[i].key === root.activeKey)
        return TabColors.baseFor(root.sections[i].color || "", root.sections[i].name || "")
    return Color.menu.background
  }
  readonly property real maxButtonHeight: Style.space(150)
  readonly property real buttonGap: Style.spacing.xxs
  readonly property real buttonRightInset: Style.space(3)
  // Air at each end of a button, between its edge and the icon or label.
  readonly property real buttonPadding: Style.space(12)
  readonly property real iconLabelGap: Style.spacing.xs

  Rectangle {
    anchors.fill: parent
    color: Qt.tint(Color.menu.background, Util.alpha(root.foreground, 0.025))

    Rectangle {
      anchors.right: parent.right
      width: Style.spacing.hairline
      height: parent.height
      color: Util.alpha(root.foreground, 0.1)
    }
  }

  Flickable {
    id: rail
    anchors.fill: parent
    anchors.topMargin: Style.spacing.sm
    anchors.bottomMargin: Style.spacing.sm
    contentHeight: buttons.height
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    clip: true

    ListWheel { flick: rail }

    Column {
      id: buttons
      width: rail.width
      spacing: root.buttonGap

      Repeater {
        model: root.sections

        delegate: Item {
          id: tab
          required property var modelData
          readonly property bool current: modelData.key === root.activeKey
          readonly property int hits: root.matchCounts[modelData.key] || 0
          readonly property bool dimmed: root.filtering && hits === 0
          readonly property int shownCount: root.filtering ? hits : (modelData.count || 0)
          readonly property color base: TabColors.baseFor(modelData.color || "", modelData.name || "")
          readonly property bool localNotebook: modelData.local === true
          readonly property string displayName: modelData.name || "Notes"
          readonly property real iconBlock: localNotebook ? 0 : Style.font.icon + root.iconLabelGap
          width: buttons.width
          height: Math.min(root.maxButtonHeight,
                           labelMetrics.width + iconBlock + root.buttonPadding * 2)

          TextMetrics {
            id: labelMetrics
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: tab.displayName
          }

          HoverHandler { id: tabHover }

          Rectangle {
            anchors.fill: parent
            anchors.rightMargin: root.buttonRightInset
            radius: Math.min(Style.cornerRadius, Style.space(8))
            color: tab.current || tabHover.hovered ? Style.hoverFill : "transparent"
            opacity: tab.dimmed ? 0.38 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
          }

          Image {
            id: logo
            visible: !tab.localNotebook && status === Image.Ready
            source: tab.modelData.logo || ""
            anchors.top: parent.top
            anchors.topMargin: root.buttonPadding
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.font.icon
            height: Style.font.icon
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            smooth: true
            opacity: tab.dimmed ? 0.4 : (tab.current ? 1 : 0.72)
          }

          Text {
            visible: !tab.localNotebook && !logo.visible
            anchors.top: parent.top
            anchors.topMargin: root.buttonPadding
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰉋"
            color: tab.current
              ? Qt.tint(root.foreground, Util.alpha(tab.base, 0.7))
              : Qt.tint(Util.alpha(root.foreground, 0.62), Util.alpha(tab.base, 0.38))
            opacity: tab.dimmed ? 0.4 : 1
            font.family: Style.fontFamily
            font.pixelSize: Style.font.icon
          }

          Text {
            id: label
            anchors.centerIn: parent
            anchors.verticalCenterOffset: tab.iconBlock / 2
            width: Math.max(0, tab.height - tab.iconBlock - root.buttonPadding * 2)
            height: tab.width - root.buttonRightInset
            rotation: -90
            text: tab.displayName
            color: Util.alpha(root.foreground, tab.current ? 0.92 : 0.68)
            opacity: tab.dimmed ? 0.4 : 1
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activated(tab.modelData.key)
          }

          PanelToolTip {
            visible: tabHover.hovered && labelMetrics.width > label.width
            text: tab.displayName + " · " + tab.shownCount
          }
        }
      }
    }
  }
}
