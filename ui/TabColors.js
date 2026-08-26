.pragma library

// Colours for the notebook rail. A tab starts from the colour its provider
// named — OneNote's purple, the sticky-note yellow — and falls back to a
// palette colour when no colour was given, which is the local provider's case:
// it has a tab per notebook folder, so each one takes its colour from its own
// name.

// The tab colours of a binder divider. Full-strength mid-tones on purpose:
// a tab is never painted in this colour directly but in an alpha wash of it
// (see fillAlpha), and a mid-tone is the one lightness that survives the wash
// on any theme — over a light background it settles into a pastel, over a
// dark one into a deep tint. A pastel here would do the first and vanish in
// the second reversed: it is the alpha, not the colour, that adapts.
var PALETTE = ["#d74269",  // rose
               "#d78942",  // apricot
               "#d7b642",  // butter
               "#86d742",  // sage
               "#42d785",  // mint
               "#42cfd7",  // teal
               "#4282d7",  // sky
               "#7a42d7"]  // lilac

// A notebook keeps its colour when notebooks are reordered or one is added
// above it, because the colour comes from its name and not from where it sits.
function indexFor(name) {
  var h = 0, s = String(name || "")
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return h % PALETTE.length
}

function fromName(name) { return PALETTE[indexFor(name)] }

// A provider's colour is its brand's, and a brand names its colour for its own
// background: OneNote's #7719AA is nearly black, the sticky-note yellow nearly
// white, and washed over the wrong theme either one disappears. Keep the hue,
// bring lightness and saturation to the palette's mid-tone, and the tab reads
// as OneNote on any theme without shouting. Colours already in that range come
// back near enough unchanged, so the palette passes through this untouched. A
// grey stays grey — inventing a hue for Notion's black-and-white would be a
// lie — but it too is brought to the middle, where a wash of it shows on
// either background.
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
    var s = c.hslSaturation < 0.14 ? c.hslSaturation : Math.max(0.5, Math.min(0.8, c.hslSaturation))
    // Qt answers -1 for the hue of a grey; any number works once s is 0.
    out = Qt.hsla(Math.max(0, c.hslHue), s, 0.55, 1).toString()
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
// because you are not on it. This one number over a mid-tone base is the whole
// of the theme handling: the background underneath decides whether the wash
// comes out pastel or deep, and nothing ever asks which theme is on.
//
// The panel is painted from this same number, so a tab and the page it belongs
// to are provably the same colour.
function fillAlpha() { return 0.3 }

// A tab's words are written in its own ink: the theme's text colour tinted
// this far toward the tab's colour. Starting from the theme's foreground —
// not from the tab's colour itself — is what keeps it readable on any theme:
// a dark theme's white becomes a pale wash of the hue, a light theme's black
// a deep one, and contrast comes along from the foreground either way.
function inkAlpha() { return 0.55 }
