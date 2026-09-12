import QtQuick
import qs.Commons
import qs.Ui
import "statusbar" as Status

// App-owned content: the status bar does not know about providers or badges.
BorderSurface {
  id: root

  property Status.StatusStyle style: Status.StatusStyle {}
  property string text: ""
  property url logo: ""
  property color foreground: style.foreground
  property color base: "transparent"
  implicitWidth: content.implicitWidth
  implicitHeight: content.implicitHeight
  leftPadding: Style.spacing.lg
  rightPadding: leftPadding
  radius: style.radius
  borderSpec: Border.flat(Util.alpha(foreground, 0.3), style.borderWidth)
  color: base.a > 0 ? Util.alpha(base, 0.16) : Util.alpha(style.foreground, 0.05)

  Status.StatusLabel {
    id: content
    objectName: "providerLabel"
    anchors.fill: parent
    style: root.style
    text: root.text
    iconSource: root.logo
    color: root.foreground
    leftPadding: root.leftPadding
    rightPadding: root.rightPadding
    maximumTextWidth: Style.space(160)
  }
}
