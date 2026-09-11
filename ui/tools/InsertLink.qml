import QtQuick
import qs.Commons
import qs.Ui
import "../editing"

Tool {
  id: tool
  toolId: "link"
  label: "Insert link"
  icon: "󰌹"
  property string linkText: ""
  property string linkUrl: "https://"

  function execute() {
    if (!editor.acceptsInline()) {
      return
    }
    linkText = editor.selection().text
    linkUrl = "https://"
    openPanel()
  }

  function cancel() {
    cancelPanel()
  }

  function submit() {
    var url = linkUrl.trim()
    var text = linkText.trim() || url
    if (!url) {
      cancelPanel()
      return
    }
    submitPanel(function() {
      var range = tool.editor.selection()
      if (tool.editor.selectionInCode()) {
        tool.editor.typeInCode(range.from, range.to, "[" + text + "](" + url + ")")
      } else {
        tool.editor.insertHtml('<a href="' + tool.editor.escapeHtml(url) + '" style="-qt-foreground:none;">'
                               + tool.editor.escapeHtml(text) + "</a>")
      }
    })
  }

  panel: Component {
    Flow {
      id: panelContent
      spacing: Style.spacing.sm
      function focusInput() {
        if (tool.panelOpen) {
          var field = tool.linkText ? urlField : textField
          field.forceActiveFocus()
          field.cursorPosition = field.text.length
        }
      }
      TextField {
        id: textField
        objectName: "linkText"
        width: Style.space(200)
        text: tool.linkText
        placeholderText: "Text"
        foreground: tool.editor.foreground
        accent: tool.editor.accent
        font.family: tool.editor.fontFamily
        verticalPadding: Style.spacing.xxs
        onTextEdited: tool.linkText = text
        Keys.onReturnPressed: tool.submit()
        Keys.onEscapePressed: tool.cancel()
      }
      TextField {
        id: urlField
        objectName: "linkUrl"
        width: Style.space(340)
        text: tool.linkUrl
        placeholderText: "https://…"
        foreground: tool.editor.foreground
        accent: tool.editor.accent
        font.family: tool.editor.fontFamily
        verticalPadding: Style.spacing.xxs
        onTextEdited: tool.linkUrl = text
        Keys.onReturnPressed: tool.submit()
        Keys.onEscapePressed: tool.cancel()
      }
      Button {
        objectName: "insertLink"
        text: "Insert"
        bordered: true
        foreground: tool.editor.foreground
        accent: tool.editor.accent
        verticalPadding: Style.spacing.xxs
        onClicked: tool.submit()
      }
      Button {
        text: "Cancel"
        bordered: true
        foreground: tool.editor.foreground
        accent: tool.editor.accent
        verticalPadding: Style.spacing.xxs
        onClicked: tool.cancel()
      }
      Component.onCompleted: {
        Qt.callLater(panelContent.focusInput)
      }
      Connections {
        target: tool
        function onPanelOpenChanged() {
          if (tool.panelOpen) {
            Qt.callLater(panelContent.focusInput)
          }
        }
      }
    }
  }
}
