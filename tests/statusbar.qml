import QtQuick
import QtQuick.Controls as QQC
import QtTest
import Quickshell
import "app/ui" as Ui
import "app/ui/statusbar" as Status

ShellRoot {
  id: test
  property var results: []

  Component {
    id: extraFactory
    Status.StatusItem {
      Status.StatusLabel {
        text: "Added later"
      }
    }
  }

  function check(name, condition) {
    if (!condition) {
      throw new Error(name)
    }
  }

  function near(a, b) {
    return Math.abs(a - b) <= 1
  }

  function left(item, host) {
    return item.mapToItem(host || bar, 0, 0).x
  }

  function settle() {
    driver.wait(40)
  }

  function fits(host, items) {
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      var point = item.mapToItem(host, 0, 0)
      check("control stays inside the bar", point.x >= -1 && point.x + item.width <= host.width + 1
        && point.y >= -1 && point.y + item.height <= host.height + 1)
      if (i > 0) {
        check("controls do not overlap", left(items[i - 1], host) + items[i - 1].width <= point.x + 1)
      }
    }
  }

  Window {
    id: window
    visible: true
    width: 960
    height: 360
    color: "#181c23"

    TestCase {
      id: driver
      name: "status bar"
      when: false
    }

    Status.StatusStyle {
      id: controlStyle
      fontFamily: "sans-serif"
      fontSize: 14
      foreground: "#e2e6ec"
      accent: "#86b8ee"
    }

    Status.StatusBar {
      id: bar
      width: 900

      // The default list registers on the left.
      Status.StatusItem {
        id: first
        Status.StatusLabel {
          style: controlStyle
          text: "Workspace"
        }
      }
      Status.StatusItem {
        id: dropdown
        QQC.ComboBox {
          property int selections: 0
          model: ["Edit", "Read", "Preview"]
          onActivated: selections++
          popup.popupType: QQC.Popup.Item
        }
      }
      Status.StatusItem {
        id: flexible
        fillWidth: true
        Status.StatusLabel {
          style: controlStyle
          text: "A long context that should use the remaining space and elide when the window becomes narrow"
        }
      }

      rightItems: [
        Status.StatusItem {
          id: rightLabel
          Status.StatusLabel {
            style: controlStyle
            text: "Saved"
          }
        },
        Status.StatusItem {
          id: custom
          // Deliberately unrelated to the generic controls. Only its natural
          // size and acceptance of allocated geometry matter to the host.
          Rectangle {
            property int clicks: 0
            implicitWidth: 64
            implicitHeight: 38
            color: "#a2ca91"
            radius: 7
            MouseArea {
              anchors.fill: parent
              onClicked: parent.clicks++
            }
          }
        }
      ]
    }

    Ui.ViewBar {
      id: appBar
      y: 110
      width: 900
      sourceName: "Local"
      sourceLogo: Qt.resolvedUrl("app/providers/onenote/logo.svg")
      crumb: "Local › Notebook"
      storage: "Notes.md"
      countVisible: true
      wordCount: 42
      fontFamily: controlStyle.fontFamily
      fontSize: controlStyle.fontSize
      foreground: controlStyle.foreground
      background: "#242932"
      accent: controlStyle.accent
      property int toggles: 0
      onListToggled: toggles++
    }
  }

  function layoutCases() {
    settle()
    fits(bar, [first, dropdown, flexible, rightLabel, custom])
    check("left registration starts at outer padding", near(left(first), bar.padding))
    check("registration order uses one shared gap", near(left(dropdown), left(first) + first.width + bar.spacing))
    check("right registrations read left to right", near(left(custom), left(rightLabel) + rightLabel.width + bar.spacing))
    check("right group ends at outer padding", near(left(custom) + custom.width, bar.width - bar.padding))
    check("flexible content uses the middle space", near(left(rightLabel), left(flexible) + flexible.width + bar.spacing))
    check("custom natural height sets the row height", near(bar.height, custom.implicitHeight + bar.padding * 2))
    check("all controls share the row height", near(first.height, custom.height) && near(dropdown.height, custom.height))
    driver.mouseClick(custom.item)
    check("custom control keeps its own behavior and style", custom.item.clicks === 1 && custom.item.color.toString() === "#a2ca91")

    var natural = first.width
    bar.width = bar.minimumWidth
    settle()
    fits(bar, [first, dropdown, flexible, rightLabel, custom])
    check("flexible content shrinks to zero before fixed controls", flexible.width <= 1 && near(first.width, natural))
    bar.width = 900
    flexible.fillWidth = false
    flexible.visible = false
    settle()
    check("without a flexible item, the groups remain at opposite edges",
      near(left(first), bar.padding) && near(left(custom) + custom.width, bar.width - bar.padding))
    rightLabel.fillWidth = true
    settle()
    check("the right group can own flexible content", near(left(rightLabel), left(dropdown) + dropdown.width + bar.spacing))
    rightLabel.fillWidth = false
    flexible.fillWidth = true
    flexible.visible = true
  }

  function visibilityCases() {
    dropdown.item.currentIndex = 1
    var instance = dropdown.item
    dropdown.visible = false
    settle()
    check("hidden registrations leave no gap", near(left(flexible), left(first) + first.width + bar.spacing))
    dropdown.visible = true
    settle()
    check("showing a registration preserves its component and state", dropdown.item === instance && dropdown.item.currentIndex === 1)

    first.visible = false
    dropdown.visible = false
    flexible.visible = false
    settle()
    check("an empty left group keeps the right group anchored", near(left(custom) + custom.width, bar.width - bar.padding))
    rightLabel.visible = false
    custom.visible = false
    settle()
    check("an empty bar has no phantom gaps: " + bar.implicitWidth, near(bar.implicitWidth, bar.padding * 2))
    first.visible = true
    settle()
    check("a left-only bar starts at its padding", near(left(first), bar.padding))
    bar.visible = false
    dropdown.visible = true
    flexible.visible = true
    rightLabel.visible = true
    custom.visible = true
    settle()
    bar.visible = true
    settle()
    fits(bar, [first, dropdown, flexible, rightLabel, custom])
    check("showing the whole bar restores flexible allocation", near(left(rightLabel), left(flexible) + flexible.width + bar.spacing))
  }

  function dropdownCases() {
    var combo = dropdown.item
    var height = bar.height
    driver.mouseClick(combo)
    settle()
    check("an arbitrary dropdown opens its own popup", combo.popup.opened)
    check("opening a popup does not resize the bar", near(bar.height, height))
    check("popup extends outside the bar", combo.popup.height > bar.height)
    driver.keyClick(Qt.Key_Down)
    driver.keyClick(Qt.Key_Return)
    settle()
    check("dropdown selection reaches its own handler", combo.currentIndex === 2 && combo.selections === 1 && !combo.popup.visible)
    check("selection does not recreate the custom component", dropdown.item === combo)
  }

  function registrationCases() {
    var previous = dropdown.item
    var entry = extraFactory.createObject(bar)
    bar.rightItems.push(entry)
    settle()
    fits(bar, [first, dropdown, flexible, rightLabel, custom, entry])
    check("runtime registrations append to their chosen side", near(left(entry), left(custom) + custom.width + bar.spacing))
    check("runtime registration preserves existing controls", dropdown.item === previous && previous.currentIndex === 2)
    entry.destroy()
    settle()
    check("destroying a registration releases its space", near(left(custom) + custom.width, bar.width - bar.padding))
    check("unregistering does not recreate other controls", dropdown.item === previous)
  }

  function fontCases() {
    for (var i = 0; i < 3; i++) {
      controlStyle.fontSize = [11, 18, 30][i]
      settle()
      fits(bar, [first, dropdown, flexible, rightLabel, custom])
      check("row grows to fit larger captions", first.height >= first.item.implicitHeight)
      check("font changes preserve a common control height", near(first.height, rightLabel.height) && near(first.height, custom.height))
    }
    controlStyle.fontSize = 14
  }

  function captionSpacingCases() {
    var provider = driver.findChild(appBar, "providerLabel")
    var status = driver.findChild(appBar, "saveStatus")
    var captions = [
      { control: provider, icon: driver.findChild(provider, "statusLabelImage") },
      { control: status, icon: driver.findChild(status, "statusLabelIcon") }
    ]
    settle()
    for (var i = 0; i < captions.length; i++) {
      var caption = captions[i].control
      var icon = captions[i].icon
      var text = driver.findChild(caption, "statusLabelText")
      check("the compound caption displays its icon", icon.visible)
      var gap = left(text, caption) - left(icon, caption) - icon.width
      check("icon and text have one shared gap", near(gap, caption.style.iconSpacing))
      var padding = caption.leftPadding
      caption.leftPadding = padding + 20
      settle()
      check("outer padding does not add space between icon and text",
        near(left(text, caption) - left(icon, caption) - icon.width, gap))
      caption.leftPadding = padding
    }
    appBar.loading = true
    settle()
    var loadingText = driver.findChild(status, "statusLabelText")
    check("a caption without an icon has no leftover icon gap", near(left(loadingText, status), status.leftPadding))
    appBar.loading = false
  }

  function appCases() {
    var toggle = driver.findChild(appBar, "sidebarToggle")
    var badge = driver.findChild(appBar, "providerBadge")
    var provider = driver.findChild(appBar, "providerLabel")
    var context = driver.findChild(appBar, "statusContext")
    var preview = driver.findChild(appBar, "linkPreview")
    var count = driver.findChild(appBar, "wordCount")
    var status = driver.findChild(appBar, "saveStatus")
    var icon = driver.findChild(status, "statusLabelIcon")
    settle()
    fits(appBar, [toggle, badge, context, count, status])
    check("provider prefix appears only in the badge", context.text === "Notebook › Notes.md")
    check("word count and initial save state are retained", count.text === "42 words" && status.text === "Saved")
    driver.mouseClick(toggle)
    check("generic button forwards the sidebar action", appBar.toggles === 1)
    appBar.listCollapsed = true
    check("sidebar state updates its accessible label", toggle.Accessible.name === "Show sidebar")

    appBar.unsaved = true
    check("unsaved state is retained", status.text === "Unsaved")
    appBar.unsaved = false
    appBar.readOnly = true
    check("read-only state is retained", status.text === "Read-only")
    appBar.loading = true
    settle()
    check("loading hides the count and save glyph", status.text === "Loading…" && !count.visible && !icon.visible)
    appBar.loading = false
    appBar.hoveredLink = "https://example.com/a/long/link"
    settle()
    check("link preview replaces context and right-side details", preview.visible && preview.text === appBar.hoveredLink
      && !context.visible && !count.visible && !icon.visible && status.text === "Click to open")
    fits(appBar, [toggle, badge, preview, status])
    appBar.hoveredLink = ""
    appBar.sourceName = ""
    settle()
    check("hiding the provider closes its slot", !badge.visible && near(left(context, appBar), left(toggle, appBar) + toggle.width + 2))
    appBar.sourceName = "An extremely long provider name that should stay bounded on a narrow status bar"
    appBar.width = 420
    settle()
    check("the app-owned badge caps its natural label width", provider.width < 200)
    fits(appBar, [toggle, badge, context, count, status])
    appBar.countVisible = false
    settle()
    check("no active note removes every right-side slot", !count.visible && !icon.visible && !status.visible)
    appBar.sourceName = "Local"
    appBar.readOnly = false
    appBar.countVisible = true
    appBar.width = 900
  }

  function report() {
    console.error("<<<RESULT>>>" + JSON.stringify(results) + "<<<END>>>")
    Qt.quit()
  }

  Timer {
    interval: 100
    running: true
    onTriggered: {
      var cases = [
        { name: "status bar lays out arbitrary controls and flexible content", run: test.layoutCases },
        { name: "visibility preserves state and removes gaps", run: test.visibilityCases },
        { name: "custom dropdown owns its popup and selection", run: test.dropdownCases },
        { name: "runtime registration preserves existing controls", run: test.registrationCases },
        { name: "font changes resize the row automatically", run: test.fontCases },
        { name: "compound captions keep icon spacing independent of outer padding", run: test.captionSpacingCases },
        { name: "app registrations preserve status behavior and narrow layouts", run: test.appCases }
      ]
      for (var i = 0; i < cases.length; i++) {
        try {
          cases[i].run()
          test.results.push({ name: cases[i].name, ok: true })
        } catch (error) {
          test.results.push({ name: cases[i].name, ok: false, detail: error.message })
        }
      }
      var capture = Quickshell.env("NOTE_NOTE_STATUSBAR_CAPTURE")
      if (capture) {
        window.contentItem.grabToImage(function(result) {
          result.saveToFile(capture)
          Qt.callLater(test.report)
        })
      } else {
        Qt.callLater(test.report)
      }
    }
  }
}
