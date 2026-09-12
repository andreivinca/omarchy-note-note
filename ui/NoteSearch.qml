import QtQuick
import qs.Commons
import qs.Ui
import "KeyBindings.js" as KeyBindings

// Search field with keyboard navigation and a shortcut hint.
Item {
  id: root
  property string filterText: ""
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  property var shortcutHandler: null
  readonly property bool searchFocused: searchField.activeFocus
  implicitHeight: controlStyle.height
  signal filterEdited(string text)
  signal clearRequested()
  signal moveRequested(int delta)
  signal acceptRequested()

  ChromeControlStyle {
    id: controlStyle
    background: root.background
    foreground: root.foreground
  }

  function focusSearch() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }
  function setSearchText(text) {
    searchField.text = text
  }

  TextField {
    id: searchField
    anchors.fill: parent
    placeholderText: "Search"
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    placeholderTextColor: Util.alpha(root.foreground, 0.45)
    background: Rectangle {
      objectName: "searchSurface"
      radius: controlStyle.radius
      color: controlStyle.fill
      border.width: controlStyle.borderWidth
      border.color: searchField.activeFocus ? controlStyle.focusBorderColor : controlStyle.borderColor
    }
    verticalPadding: Style.spacing.xs
    onTextEdited: root.filterEdited(text)
    rightPadding: root.filterText.length > 0
      ? clearSearchButton.width + Style.spacing.xs
      : searchKeycap.width + (searchField.height - searchKeycap.height) / 2 + Style.spacing.xs
    leftPadding: searchGlyph.width + Style.spacing.md + Style.spacing.xs

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
      anchors.leftMargin: Style.spacing.md
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
      var action = KeyBindings.match(event, "search")
      if (action === "nextSearch") {
        root.moveRequested(1)
        event.accepted = true
      } else if (action === "previousSearch") {
        root.moveRequested(-1)
        event.accepted = true
      } else if (action === "acceptSearch") {
        root.acceptRequested()
        event.accepted = true
      } else if (root.shortcutHandler && root.shortcutHandler(event)) {
        event.accepted = true
      }
    }
  }

}
