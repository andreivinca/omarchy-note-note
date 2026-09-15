pragma Singleton
import QtQuick

QtObject {
  id: style
  property var source: null
  readonly property int cornerRadius: source ? source.cornerRadius : 6
  readonly property int gapsOut: source ? source.gapsOut : 12
  readonly property string fontFamily: source ? source.fontFamily : Qt.application.font.family
  readonly property var font: source ? source.font : desktopFont
  readonly property var spacing: source ? source.spacing : desktopSpacing
  readonly property color hoverFill: hoverFillFor(Color.foreground, Color.accent)
  readonly property color selectionFill: Util.alpha(Color.accent, 0.35)
  // Keep the standalone baseline aligned with the shell's default type
  // scale and spacing so packaging does not change the workspace density.
  property QtObject desktopFont: QtObject {
    readonly property string family: style.fontFamily
    readonly property string menuFamily: style.fontFamily
    readonly property int baseSize: 12
    readonly property int caption: 10
    readonly property int bodySmall: 11
    readonly property int body: 12
    readonly property int subtitle: 13
    readonly property int title: 14
    readonly property int displayLarge: 28
    readonly property int iconSmall: 11
    readonly property int icon: 14
    readonly property int iconLarge: 18
  }
  property QtObject desktopSpacing: QtObject {
    readonly property int xxs: 2
    readonly property int xs: 3
    readonly property int sm: 4
    readonly property int md: 6
    readonly property int lg: 8
    readonly property int xxxl: 14
    readonly property int hairline: 1
    readonly property int controlGap: 8
    readonly property int controlHeight: 28
    readonly property int controlPaddingX: 10
    readonly property int panelPadding: 18
    readonly property int popupRowHeight: 28
  }
  function space(value) {
    return source ? source.space(value) : value
  }
  function hoverFillFor(foreground, accent) {
    return source ? source.hoverFillFor(foreground, accent) : Util.alpha(foreground, 0.08)
  }
  function pressedFillFor(foreground, accent) {
    return source ? source.pressedFillFor(foreground, accent) : Util.alpha(accent, 0.22)
  }
  function selectedFillFor(foreground, accent) {
    return source ? source.selectedFillFor(foreground, accent) : Util.alpha(accent, 0.18)
  }
  function hoverStateColor(foreground, accent) {
    return source ? source.hoverStateColor(foreground, accent) : foreground
  }
  function selectedStateColor(foreground, accent) {
    return source ? source.selectedStateColor(foreground, accent) : Qt.tint(foreground, Util.alpha(accent, 0.6))
  }
}
