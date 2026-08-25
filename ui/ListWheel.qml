import QtQuick
import qs.Commons

// The one scroll feel, shared by every scrolling surface: a Flickable moves
// touchpad scrolls pixel-for-pixel, which feels slow for a long list, so they
// are scaled; a mouse notch gets a fixed step. Declared inside the Item whose
// wheel it takes, driving `flick`.
//
// contentY is measured from originY, which a ListView does not keep at 0 —
// plain Flickables have it at 0, so the same arithmetic serves both.
WheelHandler {
  required property Flickable flick

  target: null
  acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
  onWheel: function(event) {
    var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 3 : (event.angleDelta.y / 120) * Style.space(72)
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = flick.originY + Math.max(0, Math.min(flick.contentY - flick.originY - dy, max))
  }
}
