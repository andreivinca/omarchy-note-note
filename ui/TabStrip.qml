import QtQuick
import qs.Commons
import qs.Ui

// Scrollable notebook tabs, with provider logos when available.
Item {
  id: root

  // The tabs as the host builds them: { key, name, color, logo, count }.
  property var sections: []
  // Search hits per tab key; kept beside `sections` so a keystroke moves
  // the numbers without touching the tabs (see the host's rebuildRows).
  property var matchCounts: ({})
  property string activeKey: ""
  property bool filtering: false
  // The exact fill behind the strip, for the overflow fades to fade into.
  property color background: Color.menu.background
  property color activeBackground: Qt.tint(background, Util.alpha(foreground, 0.07))
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property int fontSize: Style.font.bodySmall
  // Mockup measurements at a 16 px tab font. Keep these proportions
  // independent of the shell's general-purpose spacing overrides.
  readonly property real designScale: root.fontSize / 16
  readonly property real horizontalPadding: Math.round(18 * root.designScale)
  readonly property real contentGap: Math.round(10 * root.designScale)
  readonly property real iconSize: root.fontSize
  readonly property real verticalInset: Math.round(5 * root.designScale)
  implicitHeight: Math.round(42 * root.designScale)
  signal activated(string key)

  clip: true

  // The open tab stays in sight: however it was switched — a click here,
  // ctrl+tab, a search hopping to the tab that has hits — the strip
  // scrolls to show it.
  onActiveKeyChanged: Qt.callLater(revealActive)
  onWidthChanged: Qt.callLater(revealActive)
  onSectionsChanged: Qt.callLater(revealActive)
  function revealActive() {
    for (var i = 0; i < tabs.count; i++) {
      var it = tabs.itemAt(i)
      if (!it || it.modelData.key !== root.activeKey) {
        continue
      }
      if (strip.contentX > it.x) {
        strip.contentX = it.x
      } else if (strip.contentX + strip.width < it.x + it.width) {
        strip.contentX = Math.max(0, it.x + it.width - strip.width)
      }
      return
    }
  }

  Flickable {
    id: strip
    anchors.fill: parent
    contentWidth: row.width
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentWidth > width

    // Sideways is the only way this strip goes, so every wheel drives it
    // there — a mouse's vertical notches are the only wheel most mice have.
    WheelHandler {
      target: null
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) {
        var d = (event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0)
          ? (event.pixelDelta.x + event.pixelDelta.y) * 3
          : ((event.angleDelta.x + event.angleDelta.y) / 120) * Style.space(56)
        strip.contentX = Math.max(0, Math.min(strip.contentX - d,
                                              Math.max(0, strip.contentWidth - strip.width)))
      }
    }

    Row {
      id: row
      height: strip.height
      // Tabs meet at their dividers; the whitespace belongs inside each tab.
      spacing: 0

      Repeater {
        id: tabs
        model: root.sections

        delegate: Rectangle {
          id: tab
          required property var modelData
          objectName: "notebookTab-" + modelData.key
          readonly property bool current: modelData.key === root.activeKey
          readonly property int hits: root.matchCounts[modelData.key] || 0
          // While a search is on, a tab with nothing to show steps back —
          // the rail's old dimming, kept.
          readonly property bool dimmed: root.filtering && hits === 0
          readonly property bool branded: String(modelData.logo || "").length > 0
          readonly property string displayName: modelData.name || "Notes"

          anchors.verticalCenter: parent.verticalCenter
          width: content.implicitWidth + root.horizontalPadding * 2
          height: root.height
          radius: Math.min(Style.cornerRadius, Style.space(6))
          // The open tab's wash, the hover fill for the rest — the same
          // treatment the sidebar rows get, so the strip reads as chrome
          // of the same app.
          color: current ? root.activeBackground
                         : (tabHover.hovered ? Style.hoverFill : "transparent")
          opacity: dimmed ? 0.38 : 1
          Behavior on color { ColorAnimation { duration: 120 } }

          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.spacing.hairline
            height: Math.round(18 * root.designScale)
            visible: !tab.current && !tabHover.hovered
            color: Util.alpha(root.foreground, 0.12)
          }

          HoverHandler { id: tabHover }

          Row {
            id: content
            anchors.left: parent.left
            anchors.leftMargin: root.horizontalPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.contentGap
            anchors.alignWhenCentered: false

            Image {
              visible: tab.branded
              source: tab.modelData.logo || ""
              anchors.verticalCenter: parent.verticalCenter
              anchors.alignWhenCentered: false
              width: root.iconSize
              height: root.iconSize
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              fillMode: Image.PreserveAspectFit
              smooth: true
              opacity: tab.current ? 1 : 0.72
            }

            Text {
              id: label
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              anchors.alignWhenCentered: false
              // Capped the way a browser caps a tab: a long notebook name
              // elides, and the tooltip below says the whole of it.
              width: Math.min(implicitWidth, Style.space(200))
              text: tab.displayName
              // Keep notebook labels neutral so the selected note remains prominent.
              color: tab.current
                ? root.foreground
                : Util.alpha(root.foreground, 0.68)
              font.family: root.fontFamily
              font.pixelSize: root.fontSize
              elide: Text.ElideRight
            }

            // The tab's search hits, while a search is on — the number the
            // closed tabs answer with.
            Rectangle {
              visible: root.filtering && tab.hits > 0
              anchors.verticalCenter: parent.verticalCenter
              width: hitText.width + Style.spacing.sm * 2
              height: hitText.height + Style.spacing.xxs
              radius: height / 2
              color: Util.alpha(root.foreground, 0.1)

              Text {
                id: hitText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: tab.hits
                color: Util.alpha(root.foreground, 0.75)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activated(tab.modelData.key)
          }

          PanelToolTip {
            visible: tabHover.hovered && (label.implicitWidth > label.width || !root.filtering)
            text: tab.displayName + " · " + (root.filtering ? tab.hits : (tab.modelData.count || 0))
          }
        }
      }
    }
  }

  // ---- there is more: fades at the ends the strip has scrolled past
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(18)
    visible: strip.contentWidth > strip.width + 1 && strip.contentX > 0
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: Util.alpha(root.background, 0.95) }
      GradientStop { position: 1.0; color: "transparent" }
    }
  }

  Rectangle {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(18)
    visible: strip.contentWidth > strip.width + 1
             && strip.contentX < strip.contentWidth - strip.width - 1
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 1.0; color: Util.alpha(root.background, 0.95) }
    }
  }
}
