import QtQuick
import qs.Commons

// Center the painted glyph, independent of the icon font's bearings and
// baseline. This is internal control geometry, never registration geometry.
Item {
  id: root

  property StatusStyle style: StatusStyle {}
  property string text: ""
  property color color: style.foreground
  property real fontSize: style.fontSize
  implicitWidth: Math.max(fontSize, Math.ceil(metrics.tightBoundingRect.width))
  implicitHeight: Math.max(fontSize, Math.ceil(metrics.tightBoundingRect.height))

  TextMetrics {
    id: metrics
    font: glyph.font
    text: root.text
  }

  Text {
    id: glyph
    x: (parent.width - metrics.tightBoundingRect.width) / 2 - metrics.tightBoundingRect.x
    y: (parent.height - metrics.tightBoundingRect.height) / 2
      - baselineOffset - metrics.tightBoundingRect.y
    text: root.text
    textFormat: Text.PlainText
    color: root.color
    font.family: Style.fontFamily
    font.pixelSize: root.fontSize
    renderType: Text.NativeRendering
  }
}
