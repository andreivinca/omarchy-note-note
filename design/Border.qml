pragma Singleton
import QtQuick

QtObject {
  function flat(color, width) {
    return { color: color, width: width }
  }
  function none() {
    return flat("transparent", 0)
  }
  function left(spec) {
    return spec ? spec.width : 0
  }
  function right(spec) {
    return left(spec)
  }
  function top(spec) {
    return left(spec)
  }
  function bottom(spec) {
    return left(spec)
  }
}
