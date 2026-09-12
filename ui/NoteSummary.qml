import QtQuick
import qs.Commons
import "../services/notes/sidebar.js" as Sidebar

// Shared two-line note summary for the notebook and search results.
Column {
  id: root
  property string title: ""
  property bool hasTitle: true
  property string preview: ""
  property var modified: ""
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property int fontSize: Style.font.body
  spacing: Style.space(1)

  Text {
    width: parent.width
    text: root.title
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: root.hasTitle
    elide: Text.ElideRight
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm
    Text {
      id: dateLabel
      visible: text.length > 0
      text: {
        var time = Sidebar.timestamp(root.modified)
        if (!time) {
          return ""
        }
        var date = new Date(time)
        return date.toDateString() === new Date().toDateString()
          ? Qt.formatTime(date, "HH:mm") : Qt.formatDate(date, "d MMM")
      }
      textFormat: Text.PlainText
      color: Util.alpha(root.foreground, 0.65)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize - 1
    }
    Text {
      width: Math.max(0, parent.width - (dateLabel.visible ? dateLabel.width + parent.spacing : 0))
      text: root.preview.replace(/\s+/g, " ").trim()
      textFormat: Text.PlainText
      color: Util.alpha(root.foreground, 0.48)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize - 1
      elide: Text.ElideRight
    }
  }
}
