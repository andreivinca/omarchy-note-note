import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Presentation only. Python supplies conflicts and validates all choices
// against a fresh remote read before writing any resolved content.
FocusScope {
  id: root
  objectName: "mergeConflict"
  property var conflict: ({ parts: [] })
  property string remoteName: "Elsewhere"
  property var resolve: null
  property var retry: null
  property var continueEditing: null
  property var choices: ({})
  readonly property bool complete: conflict.parts.length > 0 && conflict.parts.every(function(part) {
    return ["local", "remote", "both"].indexOf(root.choices[part.id]) >= 0
  })
  onConflictChanged: root.choices = ({})

  function choose(id, choice) {
    var next = Object.assign({}, root.choices)
    next[id] = choice
    root.choices = next
  }

  Column {
    id: heading
    anchors.top: parent.top
    width: parent.width
    spacing: Style.spacing.sm
    Text {
      text: "This note has conflicting edits"
      color: Color.menu.text
      font.pixelSize: Style.font.title
      font.bold: true
      width: parent.width
      wrapMode: Text.Wrap
    }
    Text {
      text: "Choose what to keep for each conflict. Your draft is saved on this device."
      color: Color.menu.text
      font.pixelSize: Style.font.body
      width: parent.width
      wrapMode: Text.Wrap
    }
  }

  QQC.ScrollView {
    anchors.top: heading.bottom
    anchors.bottom: actions.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.spacing.md
    anchors.bottomMargin: Style.spacing.md
    clip: true
    contentWidth: availableWidth
    Column {
      width: parent.width
      spacing: Style.spacing.lg
      Repeater {
        model: root.conflict.parts
        delegate: Column {
          id: part
          required property var modelData
          width: parent.width
          spacing: Style.spacing.sm
          Text {
            text: part.modelData.field === "title" ? "Title" : "Passage"
            color: Color.menu.text
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Repeater {
            model: [
              { key: "base", label: "Original" },
              { key: "local", label: "Note Note" },
              { key: "remote", label: root.remoteName }
            ]
            delegate: Column {
              required property var modelData
              width: parent.width
              spacing: Style.spacing.xxs
              Text {
                text: modelData.label
                color: Color.menu.text
                font.pixelSize: Style.font.caption
              }
              QQC.TextArea {
                objectName: "conflict-" + part.modelData.id + "-" + parent.modelData.key
                width: parent.width
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.PlainText
                text: part.modelData[parent.modelData.key] || "(empty)"
                wrapMode: TextEdit.Wrap
                color: Color.menu.text
                font.pixelSize: Style.font.body
                background: Rectangle {
                  color: Qt.rgba(0, 0, 0, 0.12)
                  radius: Style.cornerRadius
                }
              }
            }
          }
          Flow {
            width: parent.width
            spacing: Style.spacing.sm
            Repeater {
              model: [
                { key: "local", label: "Keep Note Note" },
                { key: "remote", label: "Keep " + root.remoteName },
                { key: "both", label: "Keep both" }
              ]
              delegate: Button {
                required property var modelData
                objectName: "choose-" + part.modelData.id + "-" + modelData.key
                text: (root.choices[part.modelData.id] === modelData.key ? "✓ " : "") + modelData.label
                foreground: Color.menu.text
                accent: Color.accent
                bordered: true
                focusable: true
                onClicked: root.choose(part.modelData.id, modelData.key)
              }
            }
          }
        }
      }
    }
  }

  Flow {
    id: actions
    anchors.bottom: parent.bottom
    width: parent.width
    spacing: Style.spacing.sm
    Button {
      objectName: "resolveConflict"
      text: "Save resolved note"
      enabled: root.complete && typeof root.resolve === "function"
      opacity: enabled ? 1 : 0.45
      foreground: Color.menu.text
      accent: Color.accent
      bordered: true
      focusable: true
      onClicked: root.resolve(root.choices)
    }
    Button {
      objectName: "retryMerge"
      text: "Retry merge"
      enabled: typeof root.retry === "function"
      foreground: Color.menu.text
      accent: Color.accent
      bordered: true
      focusable: true
      onClicked: root.retry()
    }
    Button {
      objectName: "continueEditing"
      text: "Continue editing"
      enabled: typeof root.continueEditing === "function"
      foreground: Color.menu.text
      accent: Color.accent
      bordered: true
      focusable: true
      onClicked: root.continueEditing()
    }
  }
}
