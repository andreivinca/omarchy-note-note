import QtQuick
import QtQuick.Layouts

// Register StatusItems in either list. The host only manages geometry;
// backgrounds, controls and their behavior belong to the caller.
Item {
  id: root

  default property alias leftItems: leading.data
  property alias rightItems: trailing.data
  property real padding: 2
  property real spacing: 2
  property real minimumContentHeight: 0
  readonly property real minimumWidth: row.Layout.minimumWidth + padding * 2
  implicitWidth: row.implicitWidth + padding * 2
  implicitHeight: Math.max(minimumContentHeight, row.implicitHeight) + padding * 2

  component Group: RowLayout {
    readonly property bool expands: {
      for (var i = 0; i < children.length; i++) {
        if (children[i].visible && children[i].Layout.fillWidth) {
          return true
        }
      }
      return false
    }
    spacing: root.spacing
    Layout.preferredWidth: implicitWidth
    Layout.preferredHeight: implicitHeight
    Layout.fillWidth: expands
    Layout.fillHeight: true
  }

  data: RowLayout {
    id: row
    anchors.fill: parent
    anchors.margins: root.padding
    spacing: 0

    Group {
      id: leading
    }

    Item {
      Layout.fillWidth: !leading.expands && !trailing.expands
      Layout.minimumWidth: leading.implicitWidth > 0 && trailing.implicitWidth > 0 ? root.spacing : 0
      Layout.preferredWidth: Layout.minimumWidth
      Layout.maximumWidth: Layout.fillWidth ? Infinity : Layout.minimumWidth
    }

    Group {
      id: trailing
    }
  }
}
