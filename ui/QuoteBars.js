// Where the editor's block decorations go: runs of quote blocks (the bar),
// runs of code blocks (the slab) and the checkbox items (the drawn box), as
// character ranges the editor turns into rectangles with
// positionToRectangle.
//
// Two ways in, one answer out. `runsFromBlocks` reads real block formats
// from the native inspector (cpp/textblocks.h) when it is built; `runs` is
// the fallback that scans the document's serialised HTML, the only view of
// block formats QML has on its own. cpp/selftest.py asserts the two agree
// on every round-trip case.

// Mirrors dialect (services/markdown/qthtml/dialect.py): a quote is the
// pair of margins at or past QUOTE_PX (an indent sets the left one only),
// and a code line is a block background without a quote's margins.
var QUOTE_PX = 40

function styleMargins(style) {
  var ml = /margin-left\s*:\s*(-?\d+)px/.exec(style)
  var mr = /margin-right\s*:\s*(-?\d+)px/.exec(style)
  return { left: ml ? parseInt(ml[1], 10) : 0, right: mr ? parseInt(mr[1], 10) : 0 }
}

function kindOfStyle(style) {
  var m = styleMargins(style)
  if (m.left >= QUOTE_PX && m.right >= QUOTE_PX) {
    return "quote"
  }
  if (/background-color\s*:/.test(style)) {
    return "code"
  }
  return ""
}

function kindOfBlock(block) {
  if (block.rule) {
    return "rule"
  }
  if (block.marginLeft >= QUOTE_PX && block.marginRight >= QUOTE_PX) {
    return "quote"
  }
  if (block.background) {
    return "code"
  }
  return ""
}

// Every document block's tag and open tag, in Qt's own block order — the
// one walk under kinds() and markers(): every <p>, <li>, heading, <hr />
// and table cell is a block; the <p> inside a cell is the cell's content,
// not a block of its own (docs/engine-notes.md).
function _openTags(html) {
  var body = (html.split("<body>")[1] || "").split("</body>")[0]
  var re = /<(p|li|td|th|hr|h[1-6])[\s>]/g, out = [], cellEnd = -1, m
  while ((m = re.exec(body)) !== null) {
    if (m[1] === "td" || m[1] === "th") {
      cellEnd = body.indexOf("</" + m[1], m.index)
      out.push({ tag: m[1], open: "" })
      continue
    }
    if (m.index < cellEnd) {
      continue
    }
    out.push({ tag: m[1], open: body.substring(m.index, body.indexOf(">", m.index) + 1) })
  }
  return out
}

// The kind of every document block. Headings count even though they are
// never decorated — missing one shifts every entry after it
// (cpp/selftest.py is what caught exactly that). A rule is its own kind:
// not for decoration, but for the caret's sake — the editor treats a rule
// block specially (NoteEditor's escapeForward and returnLeavesBlock).
function kinds(html) {
  var tags = _openTags(html), out = []
  for (var i = 0; i < tags.length; i++) {
    if (tags[i].tag === "hr") {
      out.push("rule")
      continue
    }
    var style = /style="([^"]*)"/.exec(tags[i].open)
    out.push(tags[i].tag === "p" && style ? kindOfStyle(style[1]) : "")
  }
  return out
}

// The checkbox of every document block — 0 none, 1 an unchecked box, 2 a
// checked one. The state rides the list item's class attribute
// (dialect.CHECK_CLASS), and Qt serialises its own markers back the same
// way.
function markers(html) {
  var tags = _openTags(html), out = []
  for (var i = 0; i < tags.length; i++) {
    var cls = tags[i].tag === "li" ? /class="(checked|unchecked)"/.exec(tags[i].open) : null
    out.push(cls ? (cls[1] === "checked" ? 2 : 1) : 0)
  }
  return out
}

// {quote: [{from, to}], code: [{from, to}]} — one entry per run of
// neighbouring blocks of that kind, merged so a multi-line block draws one
// bar or one slab.
function _collect(kindAt, count, fromOf, toOf) {
  var out = { quote: [], code: [] }
  var open = "", from = -1, to = -1
  for (var i = 0; i <= count; i++) {
    var kind = i < count ? kindAt(i) : ""
    // Only these two kinds draw anything; every other kind ("rule") is a
    // run-breaker here, not a run.
    if (kind !== "quote" && kind !== "code") {
      kind = ""
    }
    if (kind === open) {
      if (open) {
        to = toOf(i)
      }
      continue
    }
    if (open) {
      out[open].push({ from: from, to: to })
    }
    open = kind
    if (open) {
      from = fromOf(i)
      to = toOf(i)
    }
  }
  return out
}

// Each block's character span, from the plain text (whose U+2029/U+FDD0
// separators mark the blocks).
function _blockSpans(text) {
  var starts = [], ends = [], start = 0
  for (var i = 0; i <= text.length; i++) {
    var c = i < text.length ? text.charCodeAt(i) : 0x2029  // the text's end closes the last block
    if (c !== 0x2029 && c !== 0xFDD0) {
      continue
    }
    starts.push(start); ends.push(i)
    start = i + 1
  }
  return { starts: starts, ends: ends }
}

// From the document's HTML plus its plain text.
function runs(html, text) {
  var kind = kinds(html), spans = _blockSpans(text)
  var count = Math.min(kind.length, spans.starts.length)
  return _collect(function(i) { return kind[i] }, count,
                  function(i) { return spans.starts[i] }, function(i) { return spans.ends[i] })
}

// The same runs, from the native inspector's block list.
function runsFromBlocks(blocks) {
  return _collect(function(i) { return kindOfBlock(blocks[i]) }, blocks.length,
                  function(i) { return blocks[i].position }, function(i) { return blocks[i].end })
}

// [{position, checked}] — one entry per checkbox item, `position` its
// block's first character, ready for positionToRectangle.
function boxes(html, text) {
  var marker = markers(html), spans = _blockSpans(text), out = []
  var count = Math.min(marker.length, spans.starts.length)
  for (var i = 0; i < count; i++) {
    if (marker[i]) {
      out.push({ position: spans.starts[i], checked: marker[i] === 2 })
    }
  }
  return out
}

// The same boxes, from the native inspector's block list.
function boxesFromBlocks(blocks) {
  var out = []
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].marker) {
      out.push({ position: blocks[i].position, checked: blocks[i].marker === 2 })
    }
  }
  return out
}
