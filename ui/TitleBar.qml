import QtQuick
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
    TextField {
      id: searchField
      anchors.right: settingsButton.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      // On a narrow window the field gives way first — down to where typing
      // is still comfortable — and the strip keeps room enough to scroll,
      // so nothing ever runs under anything.
      width: Math.max(Style.space(140),
                      Math.min(Style.space(300),
                               settingsButton.x - Style.spacing.lg * 2 - Style.space(160)))
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

    TabStrip {
      anchors.left: parent.left
      anchors.right: searchField.left
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

    Button {
      id: shapeButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.detached ? "Overlay" : "Detach"
      iconText: root.detached ? "󰨟" : "󰏌"
      tooltipText: root.detached ? "Back to the overlay: summoned over your work, gone on Escape"
                                 : "Detach into an ordinary window you can keep open beside your work"
      bordered: true
      selected: root.detached
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      iconSize: Style.font.iconSmall
      // Wider than the default control padding: a labelled pill wants
      // air around its word.
      horizontalPadding: Style.spacing.lg
      verticalPadding: Style.spacing.xxs
      onClicked: root.detachToggled()
    }

    Button {
      id: settingsButton
      anchors.right: shapeButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      tooltipText: "Settings — edit note-note's config as JSON (for now: which providers show up)"
      bordered: true
      selected: root.settingsOpen
      foreground: root.foreground
      accent: root.accent
      // A circle, as tall as the pill beside it. The gear is drawn as
      // an OpticalGlyph rather than the button's own icon: an icon
      // glyph's ink is not centered in its advance width, and inside a
      // tight circle that reads as off-center.
      width: shapeButton.height
      height: shapeButton.height
      radius: height / 2
      onClicked: root.settingsRequested()

      // Centered on the glyph's painted ink, both axes. The kit's
      // OpticalGlyph corrects only horizontally — it keeps a shared
      // baseline for rows of glyphs — but a lone glyph in a circle
      // has no neighbours, and its line box's own centering reads as
      // vertical drift.
      TextMetrics {
        id: gearMetrics
        font.family: Style.fontFamily
        font.pixelSize: Math.max(1, Math.round(Style.font.iconSmall))
        text: gearGlyph.text
      }
      Text {
        id: gearGlyph
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: implicitWidth / 2
          - (gearMetrics.tightBoundingRect.x + gearMetrics.tightBoundingRect.width / 2)
        anchors.verticalCenterOffset: implicitHeight / 2
          - (baselineOffset + gearMetrics.tightBoundingRect.y + gearMetrics.tightBoundingRect.height / 2)
        text: "󰒓"
        font.family: Style.fontFamily
        font.pixelSize: gearMetrics.font.pixelSize
        renderType: Text.NativeRendering
        color: settingsButton.selected ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
      }
    }
  }
}
