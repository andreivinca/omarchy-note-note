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

// The converter writes each table with a pipe-delimited header and a
// canonical separator. Ignore lookalikes inside fenced code. Table order
// survives Qt's HTML export even when empty cell paragraphs do not.
function tables(lines) {
  var code = fences(lines), result = []
  for (var i = 0; i + 1 < lines.length; i++) {
    if (code[i] || !/^\s*\|/.test(lines[i]) || !/^\s*\|(?:---\|)+\s*$/.test(lines[i + 1])) {
      continue
    }
    var start = i
    i++
    while (i + 1 < lines.length && !code[i + 1] && /^\s*\|/.test(lines[i + 1])) {
      i++
    }
    result.push({ start: start, end: i })
  }
  return result
}
