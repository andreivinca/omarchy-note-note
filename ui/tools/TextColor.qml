import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import "../editing"

Tool {
  id: colorTool
  toolId: "textColor"
  label: "Text color"
  icon: "󰏘"
  panelPopup: true
  available: editor.canColorText && !editor.inCode
  readonly property var colors: [
    { name: "Coral", color: "#ff6364" },
    { name: "Red", color: "#ff0000" },
    { name: "Brown", color: "#8a3a07" },
    { name: "Gold", color: "#8a6701" },
    { name: "Olive green", color: "#466d1e" },
    { name: "Green", color: "#00853c" },
    { name: "Teal", color: "#008687" },
    { name: "Blue", color: "#3dadff" },
    { name: "Light blue", color: "#75c6fe" },
    { name: "Purple", color: "#a76fd4" },
    { name: "Black", color: "#1c1c1c" },
    { name: "White", color: "#ecebe9" }
  ]

  function execute() {
    if (editor.acceptsInline() && !editor.selectionInCode()) {
      openPanel()
    }
  }

  function choose(color) {
    return submitPanel(function() {
      colorTool.editor.setTextColor(color)
    })
  }

  panel: Component {
    Column {
      spacing: Style.spacing.sm
      Grid {
        columns: 6
        spacing: Style.spacing.xs
        Repeater {
          id: swatches
          model: colorTool.colors
          delegate: QQC.AbstractButton {
            id: swatch
            required property var modelData
            required property int index
            objectName: "textColor-" + index
            width: Style.space(28)
            height: width
            focusPolicy: Qt.StrongFocus
            Accessible.name: modelData.name
            QQC.ToolTip.visible: hovered
            QQC.ToolTip.text: modelData.name
            QQC.ToolTip.delay: 500
            onClicked: colorTool.choose(modelData.color)
            background: Rectangle {
              radius: width / 2
              color: "transparent"
              border.width: swatch.hovered || swatch.activeFocus ? 2 : 0
              border.color: colorTool.editor.accent
              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                radius: width / 2
                color: swatch.modelData.color
                border.width: 1
                border.color: Util.alpha(Color.popups.text, 0.35)
              }
            }
            Keys.onPressed: function(event) {
              var step = 0
              if (event.key === Qt.Key_Right) {
                step = 1
              } else if (event.key === Qt.Key_Left) {
                step = -1
              } else if (event.key === Qt.Key_Down) {
                step = 6
              } else if (event.key === Qt.Key_Up) {
                step = -6
              } else {
                return
              }
              var next = index + step
              if (next >= swatches.count) {
                reset.forceActiveFocus()
              } else if (next >= 0) {
                swatches.itemAt(next).forceActiveFocus()
              }
              event.accepted = true
            }
          }
        }
      }
      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Color.popups.text, 0.15)
      }
      QQC.ItemDelegate {
        id: reset
        objectName: "textColor-reset"
        width: parent.width
        text: "Reset color"
        implicitHeight: resetLabel.implicitHeight + Style.spacing.sm
        hoverEnabled: true
        font.family: colorTool.editor.noteFontFamily
        font.pixelSize: colorTool.editor.bodyFontSize
        contentItem: Text {
          id: resetLabel
          text: reset.text
          font: reset.font
          color: Color.popups.text
          verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
          radius: Style.cornerRadius
          color: reset.hovered || reset.activeFocus
            ? Style.hoverFillFor(Color.popups.text, colorTool.editor.accent) : "transparent"
        }
        onClicked: colorTool.choose("")
        Keys.onUpPressed: swatches.itemAt(swatches.count - 1).forceActiveFocus()
      }
    }
  }
}
