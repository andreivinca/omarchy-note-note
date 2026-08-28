// Where the editor's block decorations go: runs of quote blocks (the bar)
// and runs of code blocks (the slab), as character ranges the editor turns
// into rectangles with positionToRectangle.
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
  if (m.left >= QUOTE_PX && m.right >= QUOTE_PX) return "quote"
  if (/background-color\s*:/.test(style)) return "code"
  return ""
}

function kindOfBlock(block) {
  if (block.marginLeft >= QUOTE_PX && block.marginRight >= QUOTE_PX) return "quote"
  if (block.background) return "code"
  return ""
}

// The kind of every document block, in Qt's own block order: every <p>,
// <li>, heading, <hr /> and table cell is one; the <p> inside a cell is the
// cell's content, not a block of its own (docs/engine-notes.md). Headings
// count even though they are never decorated — missing one shifts every
// entry after it (cpp/selftest.py is what caught exactly that).
function kinds(html) {
  var body = (html.split("<body>")[1] || "").split("</body>")[0]
  var re = /<(p|li|td|th|hr|h[1-6])[\s>]/g, out = [], cellEnd = -1, m
  while ((m = re.exec(body)) !== null) {
    if (m[1] === "td" || m[1] === "th") { cellEnd = body.indexOf("</" + m[1], m.index); out.push(""); continue }
    if (m.index < cellEnd) continue
    var open = body.substring(m.index, body.indexOf(">", m.index) + 1)
    var style = /style="([^"]*)"/.exec(open)
    out.push(m[1] === "p" && style ? kindOfStyle(style[1]) : "")
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
    if (kind === open) {
      if (open) to = toOf(i)
      continue
    }
    if (open) out[open].push({ from: from, to: to })
    open = kind
    if (open) { from = fromOf(i); to = toOf(i) }
  }
  return out
}

// From the document's HTML plus its plain text (whose U+2029/U+FDD0
// separators mark the blocks).
function runs(html, text) {
  var kind = kinds(html)
  var starts = [], ends = [], start = 0
  for (var i = 0; i <= text.length; i++) {
    var c = i < text.length ? text.charCodeAt(i) : 0x2029  // the text's end closes the last block
    if (c !== 0x2029 && c !== 0xFDD0) continue
    starts.push(start); ends.push(i)
    start = i + 1
  }
  var count = Math.min(kind.length, starts.length)
  return _collect(function(i) { return kind[i] }, count,
                  function(i) { return starts[i] }, function(i) { return ends[i] })
}

// The same runs, from the native inspector's block list.
function runsFromBlocks(blocks) {
  return _collect(function(i) { return kindOfBlock(blocks[i]) }, blocks.length,
                  function(i) { return blocks[i].position }, function(i) { return blocks[i].end })
}
