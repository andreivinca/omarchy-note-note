.pragma library

// Colours for the notebook rail. A tab starts from the colour its provider
// named — OneNote's purple, the sticky-note yellow — and falls back to a paper
// pastel when no colour was given, which is the local provider's case: it has a
// tab per notebook folder, so each one takes its colour from its own name.

// The tab colours of a binder divider.
var PALETTE = ["#f4b8c8",  // rose
               "#f6c9a0",  // apricot
               "#f2e2a9",  // butter
               "#bdd6a8",  // sage
               "#a9dcc0",  // mint
               "#9fd3d6",  // teal
               "#a8c6ee",  // sky
               "#c8b6e6"]  // lilac

// A notebook keeps its colour when notebooks are reordered or one is added
// above it, because the colour comes from its name and not from where it sits.
function indexFor(name) {
  var h = 0, s = String(name || "")
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return h % PALETTE.length
}

function fromName(name) { return PALETTE[indexFor(name)] }

// A provider's colour is its brand's, and a brand is loud by design: OneNote's
// #7719AA washed at 18 % over a dark background is all but black. Keep the hue,
// take lightness and saturation from the palette above, and the tab reads as
// OneNote without shouting. Colours already in that range come back near
// enough unchanged, so the palette passes through this untouched. A grey stays
// grey — inventing a hue for Notion's black-and-white would be a lie.
//
// Pure, so each colour is converted once and remembered: the host re-derives
// every tab's colour on each rebuild, and the inputs are a handful of
// constants.
var _pastel = {}
function pastelize(hex) {
  var done = _pastel[hex]
  if (done !== undefined) return done
  var c = parseColor(hex)
  var out
  if (!c) out = PALETTE[0]
  else {
    var s = c.hslSaturation < 0.06 ? c.hslSaturation : Math.max(0.25, Math.min(0.45, c.hslSaturation))
    // Qt answers -1 for the hue of a grey; any number works once s is 0.
    out = Qt.hsla(Math.max(0, c.hslHue), s, 0.78, 1).toString()
  }
  _pastel[hex] = out
  return out
}

// Qt.color throws on a malformed name rather than answering invalid.
function parseColor(hex) {
  try { var c = Qt.color(String(hex || "")); return c.valid ? c : null } catch (e) { return null }
}

function baseFor(color, name) { return pastelize(color || fromName(name)) }

// A tab is a shade of its colour over whatever is behind it, not a surface made
// of it: enough to tell the tabs apart and to say which page you are on, little
// enough that the theme's own text still sits on it with room to spare. Every
// tab is washed the same — which one is open is said by its shape, the way it
// is on a binder, and a divider does not light up under the cursor or fade
// because you are not on it.
//
// The panel is painted from this same number, so a tab and the page it belongs
// to are provably the same colour.
function fillAlpha() { return 0.05 }
