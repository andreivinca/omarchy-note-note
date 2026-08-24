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
function pastelize(hex) {
  var rgb = toRgb(hex)
  if (!rgb) return PALETTE[0]
  var hsl = toHsl(rgb)
  var s = hsl.s < 0.06 ? hsl.s : Math.max(0.25, Math.min(0.45, hsl.s))
  return toHex(fromHsl(hsl.h, s, 0.78))
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

// ── hex ↔ hsl ─────────────────────────────────────────────────────────
function toRgb(hex) {
  var s = String(hex || "").replace("#", "")
  if (s.length === 3) s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2]
  if (s.length < 6) return null
  var n = parseInt(s.substring(0, 6), 16)
  if (isNaN(n)) return null
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 }
}

function toHsl(c) {
  var max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b), d = max - min
  var l = (max + min) / 2, h = 0, s = 0
  if (d > 0) {
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    if (max === c.r) h = ((c.g - c.b) / d + (c.g < c.b ? 6 : 0)) / 6
    else if (max === c.g) h = ((c.b - c.r) / d + 2) / 6
    else h = ((c.r - c.g) / d + 4) / 6
  }
  return { h: h, s: s, l: l }
}

function fromHsl(h, s, l) {
  if (s === 0) return { r: l, g: l, b: l }
  var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
  return { r: channel(p, q, h + 1 / 3), g: channel(p, q, h), b: channel(p, q, h - 1 / 3) }
}

function channel(p, q, t) {
  if (t < 0) t += 1
  if (t > 1) t -= 1
  if (t < 1 / 6) return p + (q - p) * 6 * t
  if (t < 1 / 2) return q
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
  return p
}

function toHex(c) {
  return "#" + pair(c.r) + pair(c.g) + pair(c.b)
}

function pair(v) {
  var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
  return s.length < 2 ? "0" + s : s
}
