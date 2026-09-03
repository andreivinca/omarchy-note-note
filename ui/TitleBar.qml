import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// The title bar, in a browser's shape: the binder's tabs from the left edge
// (TabStrip.qml), then the search and the window actions at the right. No
// masthead — the app needs no nameplate over its own work; whose notes are
// open is the tabs' and the view bar's answer.
//
// Presentation only: the field's text is the host's filter, edits and tab
// switches go out as signals, and the two functions are how the host hands
// focus back in.
Item {
  id: root

  // The host's filter, live: the clear button and the keycap trade places
  // on it, and it survives the host rebuilding its rows under the field.
  property string filterText: ""
  // The binder's tabs, passed straight through to the strip.
  property var sections: []
  property var matchCounts: ({})
  property string activeKey: ""
  property bool detached: false
  property bool settingsOpen: false
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  // (KeyEvent) -> bool, the host's shortcuts — run before the field's own
  // key handling, so ctrl+n in the search still makes a note.
  property var shortcutHandler: null
  // The bar sits flush against the top of whatever hosts it. In the overlay
  // that host is a rounded card whose border is painted under the content,
  // so the bar's top corners must curve with it or they square it off.
  property real cornerRadius: 0

  signal filterEdited(string text)
  signal clearRequested()
  // Up/down in the field walk the note list without leaving it.
  signal moveRequested(int delta)
  // Return or Tab: the search has done its job, the editor takes over.
  signal acceptRequested()
  signal sectionActivated(string key)
  signal settingsRequested()
  signal detachToggled()

  readonly property bool searchFocused: searchField.activeFocus
  function focusSearch() { searchField.forceActiveFocus(); searchField.selectAll() }
  function setSearchText(text) { searchField.text = text }

  height: Style.space(44)

  // The bar's own fill, named once: the background paints it and the tab
  // strip's overflow fades fade into it.
  readonly property color fill: Qt.tint(root.background, Util.alpha(root.foreground, 0.015))

  Rectangle {
    anchors.fill: parent
    color: root.fill
    topLeftRadius: root.cornerRadius
    topRightRadius: root.cornerRadius
  }

  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(root.foreground, 0.1)
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.lg
    anchors.rightMargin: Style.spacing.lg

    // The search, just before the window actions — the tabs own the left of
    // the bar. It names its own shortcut: a keycap in the field where the
    // clear button will stand once there is something to clear, so the right
    // edge always says the one thing you can do.
    //
    // Gone while the settings page is up: it filters the notes, and the
    // notes are not what is on screen then. A field that took typing and
    // showed nothing for it would be worse than an absent one.
    TextField {
      id: searchField
      visible: !root.settingsOpen
      anchors.right: menuButton.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      // On a narrow window the field gives way first — down to where typing
      // is still comfortable — and the strip keeps room enough to scroll,
      // so nothing ever runs under anything.
      width: Math.max(Style.space(140),
                      Math.min(Style.space(300),
                               menuButton.x - Style.spacing.lg * 2 - Style.space(160)))
      placeholderText: "Search notes…"
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      verticalPadding: Style.spacing.sm
      onTextEdited: root.filterEdited(text)
      rightPadding: root.filterText.length > 0
        ? clearSearchButton.width + Style.spacing.xs
        : searchKeycap.width + (searchField.height - searchKeycap.height) / 2 + Style.spacing.xs
      leftPadding: searchGlyph.width + Style.spacing.xxl + Style.spacing.xs

      Rectangle {
        id: searchKeycap
        visible: root.filterText.length === 0
        anchors.right: parent.right
        // The same air to the right edge as above and below it, so the
        // keycap sits centered in the field's corner.
        anchors.rightMargin: (searchField.height - height) / 2
        anchors.verticalCenter: parent.verticalCenter
        width: searchKeycapText.width + Style.spacing.sm * 2
        height: searchKeycapText.height + Style.spacing.xxs * 2
        // A square theme keeps its corners; a round one is capped where
        // a keycap stops looking like a key.
        radius: Math.min(Style.cornerRadius, height / 3)
        color: Util.alpha(root.foreground, 0.06)
        border.width: 1
        border.color: Util.alpha(root.foreground, 0.22)

        Text {
          id: searchKeycapText
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "ctrl+k"
          color: Util.alpha(root.foreground, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // The magnifier says what the field is for, and stays while you
      // type — dimmed the standard way, a fade toward any background.
      Text {
        id: searchGlyph
        textFormat: Text.PlainText
        anchors.left: parent.left
        // In step with the taller field: the magnifier keeps its
        // distance from the rounded edge (leftPadding above follows).
        anchors.leftMargin: Style.spacing.xxl
        anchors.verticalCenter: parent.verticalCenter
        text: "󰍉"
        color: Util.alpha(root.foreground, 0.55)
        font.family: Style.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Button {
        id: clearSearchButton
        visible: root.filterText.length > 0
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.xxs
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: "Clear the search (esc)"
        foreground: root.foreground
        accent: root.accent
        iconSize: Style.font.iconSmall
        horizontalPadding: Style.spacing.xs
        verticalPadding: Style.spacing.xxs
        onClicked: root.clearRequested()
      }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Down) { root.moveRequested(1); event.accepted = true }
        else if (event.key === Qt.Key_Up) { root.moveRequested(-1); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                 || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ControlModifier))) { root.acceptRequested(); event.accepted = true }
        else if (root.shortcutHandler && root.shortcutHandler(event)) event.accepted = true
      }
    }

    // The strip takes whatever the search leaves it, and all of it once the
    // search steps aside — the tabs are the way back out of the settings
    // page, so they must not shrink to make room for a field that is gone.
    TabStrip {
      anchors.left: parent.left
      anchors.right: searchField.visible ? searchField.left : menuButton.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      height: Style.spacing.controlHeight
      sections: root.sections
      matchCounts: root.matchCounts
      activeKey: root.activeKey
      filtering: root.filterText.length > 0
      background: root.fill
      foreground: root.foreground
      fontFamily: root.fontFamily
      onActivated: function(key) { root.sectionActivated(key) }
    }

    // Everything you do to note-note rather than to the note in front of you
    // lives behind this one button: detaching the window, and the settings
    // page. A row of pills along the bar would have to grow with each new
    // one, and each would spend the bar's width saying its own name; the
    // menu spends none until it is asked.
    Button {
      id: menuButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      // A tooltip under an open menu is one label too many, and it would
      // stand over the very rows it describes.
      tooltipText: menu.opened ? "" : "Detach the window, or open settings"
      // No outline at rest: the bar's right end is quiet until you reach
      // for it, and the kit lends the button its hover ring then. Held open
      // still reads as held down, and the settings page keeps the button
      // marked for as long as it is the thing on screen — as a fill now,
      // which is what a borderless button has to say it with.
      selected: root.settingsOpen || menu.opened
      foreground: root.foreground
      accent: root.accent
      // A square, as tall as the tab strip beside it. The radius is capped
      // the way the search keycap above caps its own: a square theme keeps
      // its corners, and a round one is held back short of the point where
      // a box this small stops being a box and becomes a circle.
      //
      // The bars are drawn as a plain Text rather than the button's own
      // icon: an icon glyph's ink is not centered in its advance width, and
      // in a box this tight that reads as off-center.
      width: Style.spacing.controlHeight
      height: Style.spacing.controlHeight
      radius: Math.min(Style.cornerRadius, height / 4)
      onClicked: menu.opened ? menu.close() : menu.open()
      // Detaching re-parents the whole content under a different window;
      // the menu that asked for it must not outlive the bar it hangs from.
      onVisibleChanged: if (!visible) { menu.close() }

      // Centered on the glyph's painted ink, both axes. The kit's
      // OpticalGlyph corrects only horizontally — it keeps a shared
      // baseline for rows of glyphs — but a lone glyph in a circle
      // has no neighbours, and its line box's own centering reads as
      // vertical drift.
      TextMetrics {
        id: menuMetrics
        font.family: Style.fontFamily
        // The kit's large icon rather than its small one: three stacked bars
        // are mostly the gaps between them, and at the size a lone glyph
        // takes they close up into a smudge. Still short of the button's own
        // height, so the hover ring has a margin to sit in.
        font.pixelSize: Math.max(1, Math.round(Style.font.iconLarge))
        text: menuGlyph.text
      }
      Text {
        id: menuGlyph
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: implicitWidth / 2
          - (menuMetrics.tightBoundingRect.x + menuMetrics.tightBoundingRect.width / 2)
        anchors.verticalCenterOffset: implicitHeight / 2
          - (baselineOffset + menuMetrics.tightBoundingRect.y + menuMetrics.tightBoundingRect.height / 2)
        text: "󰍜"
        font.family: Style.fontFamily
        font.pixelSize: menuMetrics.font.pixelSize
        renderType: Text.NativeRendering
        color: menuButton.selected ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
      }

      // The widest label the menu is about to show, measured at the size it
      // will be drawn: every row then takes the same width and the hover fill
      // is not ragged. Measured against what is on screen rather than every
      // label that could ever be, so an overlay's short menu is not held open
      // to the width of the detached one's longest word.
      TextMetrics {
        id: widestLabel
        text: root.detached ? "Back to overlay" : "Settings"
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      QQC.Popup {
        id: menu
        // Hung from the button's right edge: the bar's own edge is a few
        // pixels further right, and a menu growing that way would run off it.
        x: menuButton.width - width
        y: menuButton.height + Style.spacing.xs
        readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

        // Three radii that have to agree, or the menu reads as a lozenge with
        // pills inside it. The card is held back from the theme's full
        // rounding, and a row's corner is the card's own less the padding
        // between them — the standard nesting — then capped short of the
        // point where a row this short would round into a pill.
        readonly property real inset: Style.spacing.xs
        readonly property real cardRadius: Math.min(Style.cornerRadius, Style.space(10))
        readonly property real rowHeight: Style.spacing.popupRowHeight
        readonly property real rowRadius: Math.max(0, Math.min(cardRadius - inset, rowHeight / 4))

        readonly property real iconWidth: Math.ceil(Style.font.icon * 1.2)
        readonly property real rowWidth: Style.spacing.controlPaddingX * 2 + iconWidth
          + Style.spacing.md + Math.ceil(widestLabel.width)
        // Detaching first, as the one reached for often; the settings page
        // after it.
        readonly property var rows: [
          { id: "detach",
            icon: root.detached ? "󰨟" : "󰏌",
            label: root.detached ? "Back to overlay" : "Detach" },
          { id: "settings",
            icon: "󰒓",
            label: "Settings" }
        ]

        padding: menu.inset
        leftPadding: Border.left(borderSpec) + menu.inset
        rightPadding: Border.right(borderSpec) + menu.inset
        topPadding: Border.top(borderSpec) + menu.inset
        bottomPadding: Border.bottom(borderSpec) + menu.inset
        background: BorderSurface {
          color: Color.popups.background
          borderSpec: menu.borderSpec
          radius: menu.cardRadius
        }
        contentItem: Column {
          // Flush, not spaced: a gap between rows makes each read as its own
          // button floating on the card. The hover fill is the only divider
          // a two-row menu needs.
          spacing: 0
          Repeater {
            model: menu.rows
            delegate: Rectangle {
              id: menuRow
              required property var modelData
              width: menu.rowWidth
              height: menu.rowHeight
              radius: menu.rowRadius
              color: rowMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, root.accent) : "transparent"

              // The row's ink, named once: the glyph and the label are one
              // thing lighting up, not two that agree by accident. The glyph
              // carries it a shade lighter — it labels the row, the word is
              // the row.
              readonly property color ink: rowMouse.containsMouse
                ? Style.hoverStateColor(Color.popups.text, root.accent) : Color.popups.text

              Text {
                id: rowIcon
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: menu.iconWidth
                horizontalAlignment: Text.AlignHCenter
                text: menuRow.modelData.icon
                color: Util.alpha(menuRow.ink, 0.75)
                font.family: Style.fontFamily
                font.pixelSize: Style.font.icon
              }

              Text {
                id: rowLabel
                textFormat: Text.PlainText
                anchors.left: rowIcon.right
                anchors.leftMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: menuRow.modelData.label
                color: menuRow.ink
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  menu.close()
                  if (menuRow.modelData.id === "detach") {
                    root.detachToggled()
                  } else {
                    root.settingsRequested()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
