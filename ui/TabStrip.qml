import QtQuick
import qs.Commons
import qs.Ui
import "TabColors.js" as TabColors

// The binder's tabs, laid across the title bar the way a browser lays its
// own: the open one wears its notebook's wash and ink, the rest are quiet
// names, and the strip scrolls sideways when the binder outgrows the bar.
// A provider's logo keeps its identity on every tab it has; a tab without
// one (the local notebooks — a folder is not a brand) is just its name
// (PROVIDERS.md promises exactly that).
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
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  signal activated(string key)

  clip: true

  // The open tab stays in sight: however it was switched — a click here,
  // ctrl+tab, a search hopping to the tab that has hits — the strip
  // scrolls to show it.
  onActiveKeyChanged: Qt.callLater(revealActive)
  function revealActive() {
    for (var i = 0; i < tabs.count; i++) {
      var it = tabs.itemAt(i)
      if (!it || it.modelData.key !== root.activeKey) continue
      if (strip.contentX > it.x) strip.contentX = it.x
      else if (strip.contentX + strip.width < it.x + it.width)
        strip.contentX = Math.max(0, it.x + it.width - strip.width)
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
      spacing: Style.spacing.xs

      Repeater {
        id: tabs
        model: root.sections

        delegate: Rectangle {
          id: tab
          required property var modelData
          readonly property bool current: modelData.key === root.activeKey
          readonly property int hits: root.matchCounts[modelData.key] || 0
          // While a search is on, a tab with nothing to show steps back —
          // the rail's old dimming, kept.
          readonly property bool dimmed: root.filtering && hits === 0
          readonly property color base: TabColors.baseFor(modelData.color || "", modelData.name || "")
          readonly property bool branded: String(modelData.logo || "").length > 0
          readonly property string displayName: modelData.name || "Notes"

          anchors.verticalCenter: parent.verticalCenter
          width: content.width + Style.spacing.md * 2
          height: Style.spacing.controlHeight
          radius: Math.min(Style.cornerRadius, Style.space(6))
          // The open tab's wash, the hover fill for the rest — the same
          // treatment the sidebar rows get, so the strip reads as chrome
          // of the same app.
          color: current ? Util.alpha(base, 0.22)
                         : (tabHover.hovered ? Style.hoverFill : "transparent")
          opacity: dimmed ? 0.38 : 1
          Behavior on color { ColorAnimation { duration: 120 } }

          HoverHandler { id: tabHover }

          Row {
            id: content
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Image {
              id: logo
              visible: tab.branded && status === Image.Ready
              source: tab.modelData.logo || ""
              anchors.verticalCenter: parent.verticalCenter
              width: Style.font.iconSmall
              height: Style.font.iconSmall
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
              // Capped the way a browser caps a tab: a long notebook name
              // elides, and the tooltip below says the whole of it.
              width: Math.min(implicitWidth, Style.space(120))
              text: tab.displayName
              // The open tab's ink is its colour's — the same rule as the
              // view bar's source label (see the host's sourceInk).
              color: tab.current
                ? Qt.tint(root.foreground, Util.alpha(tab.base, TabColors.inkAlpha()))
                : Util.alpha(root.foreground, 0.68)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
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
