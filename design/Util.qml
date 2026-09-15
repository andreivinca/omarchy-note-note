pragma Singleton
import QtQuick

QtObject {
  function alpha(color, opacity) {
    return Qt.rgba(color.r, color.g, color.b, Math.max(0, Math.min(1, opacity)))
  }
}
