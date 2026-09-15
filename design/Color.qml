pragma Singleton
import QtQuick

QtObject {
  id: colors
  // The plugin supplies shell colors directly. The standalone resolver
  // chooses desktop sources before falling back to application colors.
  property var source: null
  property var systemTheme: null
  readonly property var resolved: systemTheme ? systemTheme.colors : null
  property SystemPalette system: SystemPalette {
    colorGroup: SystemPalette.Active
  }
  readonly property color background: source ? source.menu.background : resolved ? resolved.background : system.window
  readonly property color foreground: source ? source.menu.text : resolved ? resolved.foreground : system.windowText
  readonly property color accent: source ? source.accent : resolved ? resolved.accent : system.highlight
  readonly property color urgent: source ? source.urgent : resolved ? resolved.urgent : "#d34747"
  readonly property QtObject menu: QtObject {
    readonly property color background: colors.background
    readonly property color text: colors.foreground
    readonly property color border: colors.source ? colors.source.menu.border : colors.resolved ? colors.resolved.border : Util.alpha(text, 0.25)
    readonly property color scrim: colors.source ? colors.source.menu.scrim : colors.resolved ? colors.resolved.scrim : "#99000000"
    readonly property color selectedBackground: colors.source ? colors.source.menu.selectedBackground : colors.resolved ? colors.resolved.selectedBackground : Util.alpha(colors.accent, 0.2)
    readonly property color selectedText: colors.source ? colors.source.menu.selectedText : colors.resolved ? colors.resolved.selectedText : colors.accent
  }
  readonly property QtObject popups: QtObject {
    readonly property color text: colors.source ? colors.source.popups.text : colors.resolved ? colors.resolved.popupText : colors.foreground
  }
}
