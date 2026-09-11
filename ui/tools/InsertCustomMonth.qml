import QtQuick
import qs.Commons
import qs.Ui
import "../editing"
import "../editing/Calendar.js" as Calendar

Tool {
  id: tool
  toolId: "customMonth"
  label: "Insert custom month"
  icon: "󰃭"
  capability: "table"
  property int selectedMonth: 0
  property string yearText: ""
  property var calendarLocale: Qt.locale()
  readonly property bool valid: /^[0-9]{1,4}$/.test(yearText)
    && Calendar.validMonth(Number(yearText), selectedMonth)
  readonly property var months: {
    var options = []
    for (var month = 0; month < 12; month++) {
      options.push({ value: String(month), label: calendarLocale.standaloneMonthName(month, Locale.LongFormat) })
    }
    return options
  }

  function execute() {
    var today = new Date()
    calendarLocale = Qt.locale()
    selectedMonth = today.getMonth()
    yearText = String(today.getFullYear())
    openPanel()
  }

  function submit() {
    if (!valid) {
      return false
    }
    return submitPanel(function() {
      tool.editor.insertTable(Calendar.markdown(Number(tool.yearText), tool.selectedMonth, tool.calendarLocale))
    })
  }

  panel: Component {
    Column {
      id: panelContent
      objectName: "customMonthPanel"
      spacing: Style.spacing.sm
      Keys.onEscapePressed: tool.cancelPanel()

      function focusInput() {
        if (tool.panelOpen) {
          monthField.value = String(tool.selectedMonth)
          yearField.forceActiveFocus()
          yearField.selectAll()
        }
      }

      Flow {
        width: parent.width
        spacing: Style.spacing.sm
        Row {
          spacing: Style.spacing.sm
          Text {
            id: monthLabel
            text: "Month"
            height: monthField.height
            verticalAlignment: Text.AlignVCenter
            color: tool.editor.foreground
            font.family: tool.editor.fontFamily
            font.pixelSize: Style.font.body
          }
          Dropdown {
            id: monthField
            objectName: "customMonthMonth"
            width: Math.min(Style.space(190), panelContent.width - monthLabel.width - parent.spacing)
            showLabel: false
            label: "Month"
            options: tool.months
            foreground: tool.editor.foreground
            accent: tool.editor.accent
            fontFamily: tool.editor.fontFamily
            onChanged: function(value) {
              tool.selectedMonth = Number(value)
            }
          }
        }
        Row {
          spacing: Style.spacing.sm
          Text {
            text: "Year"
            height: yearField.height
            verticalAlignment: Text.AlignVCenter
            color: tool.editor.foreground
            font.family: tool.editor.fontFamily
            font.pixelSize: Style.font.body
          }
          TextField {
            id: yearField
            objectName: "customMonthYear"
            width: Style.space(90)
            text: tool.yearText
            placeholderText: "Year"
            validator: IntValidator { bottom: 1; top: 9999 }
            maximumLength: 4
            inputMethodHints: Qt.ImhDigitsOnly
            foreground: tool.editor.foreground
            accent: tool.editor.accent
            font.family: tool.editor.fontFamily
            onTextEdited: tool.yearText = text
            Keys.onReturnPressed: tool.submit()
            Keys.onEnterPressed: tool.submit()
          }
        }
        Row {
          spacing: Style.spacing.sm
          Button {
            objectName: "insertCustomMonth"
            text: "Insert"
            enabled: tool.valid
            opacity: enabled ? 1 : 0.45
            bordered: true
            focusable: true
            foreground: tool.editor.foreground
            accent: tool.editor.accent
            onClicked: tool.submit()
          }
          Button {
            objectName: "cancelCustomMonth"
            text: "Cancel"
            bordered: true
            focusable: true
            foreground: tool.editor.foreground
            accent: tool.editor.accent
            onClicked: tool.cancelPanel()
          }
        }
      }

      Text {
        visible: !tool.valid
        text: "Enter a year from 1 to 9999."
        width: parent.width
        wrapMode: Text.Wrap
        color: tool.editor.foreground
        font.family: tool.editor.fontFamily
        font.pixelSize: Style.font.caption
      }

      Component.onCompleted: Qt.callLater(panelContent.focusInput)
      Connections {
        target: tool
        function onPanelOpenChanged() {
          if (tool.panelOpen) {
            Qt.callLater(panelContent.focusInput)
          } else {
            monthField.close()
          }
        }
      }
    }
  }
}
