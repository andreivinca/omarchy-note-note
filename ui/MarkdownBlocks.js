.pragma library

// Each fenced line points to its complete block. A shorter run inside code
// is content, so it cannot split a block made with adaptive delimiters.
function fences(lines) {
  var result = {}, open = null
  for (var i = 0; i < lines.length; i++) {
    var match = /^\s*(`{3,}|~{3,})(.*)$/.exec(lines[i])
    if (!open && match) {
      open = { start: i, end: lines.length - 1, marker: match[1][0], length: match[1].length }
    }
    if (open) {
      result[i] = open
      if (i > open.start && match && match[1][0] === open.marker
          && match[1].length >= open.length && !match[2].trim()) {
        open.end = i
        open = null
      }
    }
  }
  return result
}
