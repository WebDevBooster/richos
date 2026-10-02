// The color actually painted behind a node, from the computed backgrounds of its ancestors.
// Hunt part 2, R50: a transparent `body` was read as black (rgb 0,0,0 at alpha 0), so a
// border was measured against black instead of the `html` ground that shows through.
"use strict";

const { parseCssColor, compositeOver } = require("./contrast");

// `layers` are CSS color strings, innermost first (e.g. pane, body, html). They are
// composited from the outermost inward over an opaque white viewport.
function paneGround(layers) {
  let ground = { r: 255, g: 255, b: 255, a: 1 };
  for (const css of layers.slice().reverse()) {
    const c = parseCssColor(css);
    if (c && c.a > 0) ground = compositeOver(c, ground);
  }
  return ground;
}

module.exports = { paneGround };
