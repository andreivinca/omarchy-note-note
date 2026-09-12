# Status bar components

`ui/statusbar/` is a reusable layout host with optional generic controls.
`ui/ViewBar.qml` is the app's composition: it chooses which controls appear,
binds note state and handles actions. The host knows nothing about notes,
providers, labels, buttons or menus.

## Registering controls

Import the directory and put `StatusItem` registrations in `leftItems` or
`rightItems`. Both lists display in declaration order, left to right. The
right list is anchored to the right edge. Unqualified child registrations
go into `leftItems`.

```qml
import QtQuick
import QtQuick.Controls as QQC
import "statusbar" as Status

Status.StatusBar {
  // Only the host needs positioning or a width from its parent.
  width: parent.width

  leftItems: [
    Status.StatusItem {
      Status.StatusButton {
        iconText: "＋"
        tooltipText: "New note"
        onClicked: application.newNote()
      }
    },
    Status.StatusItem {
      fillWidth: true
      Status.StatusLabel {
        text: application.context
      }
    }
  ]

  rightItems: [
    Status.StatusItem {
      visible: application.hasNote
      // Any visual component can be supplied, including external controls.
      QQC.ComboBox {
        model: ["Edit", "Read", "Preview"]
        onActivated: function(index) {
          application.chooseMode(index)
        }
      }
    }
  ]
}
```

Registrations do not set `x`, `y`, anchors, margins, width or height.
`StatusItem` loads its content once and lets the layout allocate its geometry.
Set **the registration's** `visible` property to remove its space; its control
stays alive, so hiding and showing it preserves state. A control is responsible
for closing its own popup if it should close when the registration is hidden.

Runtime additions use the same lists. Create a `StatusItem` from an app-owned
`Component`, then append it to `bar.leftItems` or `bar.rightItems` with `push()`.
For example, `var entry = factory.createObject(bar)` followed by
`bar.rightItems.push(entry)`. Call `entry.destroy()` to remove a dynamically
created registration. Existing controls keep their instances and state.

## Geometry contract

The host owns outer `padding`, inter-item `spacing`, left/right placement and
a shared row height. Its height follows the tallest visible control, with
optional `minimumContentHeight`. The host supplies no background or styling.

Every content component must:

- Report `implicitWidth` and `implicitHeight` from its content, independently
  of the space allocated by the bar. Standard QML controls already do this.
- Accept the width and height allocated by its `StatusItem`. Do not anchor
  or assign fixed dimensions to the content component's root.
- Own its internal layout, padding, styling, focus, events and popups.

Ordinary registrations retain their natural width, rounded up to whole pixels.
`fillWidth: true` lets an item grow into remaining space and shrink down to
zero. It works on either side; multiple flexible items share space through Qt
Quick Layouts. A generic label elides and clips within the allocated width.
Custom flexible controls decide how to present their content when narrowed.

The bar exposes `minimumWidth`: the space needed for fixed controls, gaps and
outer padding after flexible items shrink. The containing app must provide at
least this width, or choose which optional registrations to hide. The host
does not silently hide custom controls or invent overflow menu actions.

Popup contents do not contribute to a control's natural size. A dropdown owns
its trigger and popup; opening it does not increase the bar's height. The host
does not clip its children, so custom controls can use popups normally.

## Optional generic controls

| Component | Purpose |
|---|---|
| `StatusLabel` | Plain text with an optional icon, content sizing, padding, vertical centering and elision |
| `StatusIcon` | An icon-font glyph centered by its painted bounds |
| `StatusButton` | Icon/text action with hover, pressed and checked states and a tooltip |
| `StatusStyle` | Shared font, color, padding and size defaults for those controls |

Pass one shared `StatusStyle` through each generic control's `style` property
to customize them consistently. It does not belong to the host and is not
required for custom controls. Generic controls can also be composed inside
app-owned components; `ui/ProviderBadge.qml` combines a provider logo, a generic
label and its own surface. Adding another control requires no host changes.

For an icon with a caption, use one `StatusLabel` with `iconText` (a glyph) or
`iconSource` (an image). `iconColor` defaults to the text color. Padding wraps
the entire caption; `StatusStyle.iconSpacing` is the single gap between icon
and text, shared with `StatusButton`. This avoids adding a standalone label's
padding to the gap between two registrations. `maximumTextWidth` can cap the
caption's natural text width inside a custom control such as the provider badge.

## Verification

```bash
python3 tests/statusbar_selftest.py
```

The isolated offscreen suite checks left/right order, flexible widths on either
side, narrow layouts, hidden and empty groups, larger fonts, runtime additions
and removals, icon spacing independent of outer padding, a custom control's styling and clicks, a working external
dropdown, and the app's save, loading and link-preview states. It is included
in `tests/selftest.py`. Set `NOTE_NOTE_STATUSBAR_CAPTURE` to a PNG path to capture
the test window after the checks.
