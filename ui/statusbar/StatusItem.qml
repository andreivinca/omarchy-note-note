import QtQuick
import QtQuick.Layouts

// The loaded component supplies an implicit size and accepts its allocated
// size. Hiding a registration removes its space without destroying its UI.
Loader {
  id: root

  default property alias content: root.sourceComponent
  property bool fillWidth: false

  Layout.fillWidth: fillWidth
  Layout.fillHeight: true
  Layout.minimumWidth: fillWidth ? 0 : Math.ceil(implicitWidth)
  Layout.preferredWidth: Math.ceil(implicitWidth)
  Layout.maximumWidth: fillWidth ? Infinity : Math.ceil(implicitWidth)
  Layout.preferredHeight: Math.ceil(implicitHeight)
}
