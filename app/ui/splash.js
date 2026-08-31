// THE OPENING SCREEN — the renderer, and the only code in this feature.
//
// It runs at the very top of <body>, synchronously, so the composition is part of the
// window's FIRST paint rather than something that arrives after it. Everything below is
// pure DOM construction against `splash.css`'s structure; the values all come from one
// entry in `splash-library.js`.
//
// THE ONE CONSTRAINT ABOVE ALL OTHERS: this never delays launch by a frame. It cannot,
// structurally, and the structure is the argument -
//
//   * it adds no `await` to `main.js`'s boot path. `main.js` calls exactly one function
//     from this file, `RichSplash.yieldNow()`, and calls it at the point its own comment
//     already calls "the app is usable";
//   * it does no I/O, reads no file, and awaits no command before painting. The setting it
//     needs is read synchronously out of `localStorage` - the same instant-local-cache
//     pattern `main.js` already uses for the assertiveness dial, for the same reason, with
//     the Rust `ConfigStore` as the durable source of truth reconciled afterwards;
//   * the curtain is `pointer-events: none` for its whole life, so the live app underneath
//     is reachable the moment it is live;
//   * and it gets out of the way on the FIRST of three signals - the app reporting ready,
//     the CEO touching a key or the trackpad, or a hard ceiling - so no failure anywhere
//     else in the shell can leave it up.
//
// THE HONEST STATES. If the switch is off, if the library is missing, unparseable or
// empty, if every entry in it is malformed, or if anything at all throws while drawing,
// the result is the same and it is deliberate: NO SPLASH, and a completely normal launch.
// Never a half-drawn frame, never a fallback that looks like a broken app. `removeSelf()`
// below is what makes a partial build leave nothing behind.
//
// WHAT IS NOT HERE, named rather than hidden: tier 2 (a true line about his record) and
// tier 3 (hallmarks) from `richos-splash-micro-game-2026-08-30.md`. Both wait on CEO
// answers to that document's §8. Their seams are marked in `splash.css` - the slot under
// the rule, and the plinth's inner keyline - and neither needs this file redesigned.

"use strict";

(function () {
  // The three keys this surface owns in the webview's local store. `enabled` is a mirror
  // of the Rust `ConfigStore` (durable, authoritative, reconciled by `main.js` after boot);
  // `last` is the no-immediate-repeat guard, which has to survive a relaunch because the
  // draw happens once per LAUNCH, so the previous draw is always in a previous process.
  var KEY_ENABLED = "richos.splash.enabled";
  var KEY_LAST = "richos.splash.last";

  // How long the curtain takes to clear once the app is ready. The app underneath is
  // already live, focused and reachable throughout it - this is the fade of an inert
  // layer, not a wait.
  var FADE_MS = 180;

  // The ceiling. If nothing ever reports the app ready - a boot that hangs, a script error
  // in main.js, a command that never returns - the splash still leaves. A doorway that can
  // become a wall is worse than no doorway.
  var CEILING_MS = 4000;

  // Every token an entry must carry, and what it has to be. An entry missing one is not
  // drawn half-dressed; it is dropped from the pool.
  var STRING_TOKENS = [
    "ground", "atmosphere", "vignette", "grainOpacity",
    "lamp", "lampRadius", "lampStop",
    "surface", "surfaceImage", "plinthRadius", "plinthShadow", "plinthOutline",
    "keylineInset", "keylineRadius", "keylineColor",
    "keylineWidth", "keylineStyle", "keylineImage", "keylineShadow",
    "ink", "signal", "rule", "ruleWidth", "tagline",
    "riseDuration", "riseShift",
    "strike", "strikeDelay", "strikeDuration"
  ];
  var STRIKES = ["none", "fill", "bloom"];
  var GILD_ID = "richos-splash-gild";
  var RELIEF_ID = "richos-splash-relief";

  // A MATERIAL LAYER'S VOCABULARY. Every key an entry may put on one layer of the stack,
  // and the CSS property it lands on. The list is the whole contract: a layer is a flat
  // rectangle over the mat with these paint properties and nothing else, so `materials` can
  // describe suede, bookcloth, slate or moire without the renderer knowing that any of
  // those exist. An unknown key is refused rather than ignored — a typo has to fail loudly,
  // not silently drop the layer that was the point of the entry.
  var LAYER_PROPS = {
    background: "background",
    imageBlend: "background-blend-mode",
    blend: "mix-blend-mode",
    opacity: "opacity",
    inset: "inset",
    height: "height",
    radius: "border-radius",
    border: "border",
    borderImage: "border-image",
    shadow: "box-shadow",
    filter: "filter",
    z: "z-index"
  };
  // `mask` sets two properties, and `relief` sets none directly - it points the layer at
  // the filter this entry described. Both are checked, so they belong in the key list.
  var LAYER_KEYS = ["mask", "relief"];
  var PLACEMENTS = ["inner", "outer"];

  // The mark. Verbatim geometry from the approved compositions, and NOT in the library
  // because it is not a variation: it is identical in every version of every round, and a
  // copy per entry is a copy that can drift.
  var LOGO = {
    viewBox: "0 0 744 744",
    paths: [
    { role: "ink", d: "M517,744h227l-85.2-120.4c-41.7-58.7-83.3-117.5-124.9-176.2c-0.7-0.9-1.3-1.9-2.3-3.4c2.6-1.3,5.1-2.5,7.6-3.7c26.2-12.9,50.3-28.8,70.8-49.7c29.9-30.6,47-67.6,53.7-109.4c8.3-52.1,2.1-102.4-22.8-149.2C601.2,57.3,539.1,13.7,455.2,1.8c-4.1-0.6-8.1-1.2-12.2-1.8C295.3,0,147.7,0,0,0c0,133.5,0,266.7,0,400c12.8-17,24.9-34.6,38.5-51c45.4-55.2,99.8-100.2,159.9-138.6c1.1-0.7,2.2-1.5,3.3-2.2c0.3-0.2,0.4-0.5,1-1.1c-3.1-4.3-6.3-8.8-9.5-13.2c-7.2-10-14.4-20-21.6-30c-3.1-4.3-4.6-9-2.1-14c2.5-4.9,7.1-6,12.2-6c93.8,0,187.6,0,281.5,0c3.5,0,7.2-0.2,9.1,3.6c2,3.8,0.2,7-1.9,10.2c-43.9,66.2-87.8,132.5-131.6,198.7c-0.6,1-1.3,1.9-2,2.9c-7.2,9.8-17.5,10.1-24.9,0.3c-12.3-16.4-24.5-32.8-36.7-49.3c-1.2-1.6-2.4-3.1-3.9-5c-6.3,4.3-12.4,8.3-18.3,12.5c-46.1,32.6-89.8,68-128.1,109.6C62.9,494.7,23.5,573.1,8,663.2c-3.6,20.6-4.9,41.6-7.2,62.5c-0.2,1.8-0.5,3.6-0.8,5.4c0,3.7,0,9.3,0,13c1-1.6,2.3-5.2,2.9-6.9c19.5-54,47.4-103.2,86.8-145.2c59.3-63.2,132.4-100.6,217.6-115.2c6.4-1.1,9.7,0.4,13.6,5.5" },
    { role: "signal", d: "M0,400c12.8-17,24.9-34.6,38.5-51c45.4-55.2,99.8-100.2,159.9-138.6c1.1-0.7,2.2-1.5,3.3-2.2c0.3-0.2,0.4-0.5,1-1.1c-3.1-4.3-6.3-8.8-9.5-13.2c-7.2-10-14.4-20-21.6-30c-3.1-4.3-4.6-9-2.1-14c2.5-4.9,7.1-6,12.2-6c93.8,0,187.6,0,281.5,0c3.5,0,7.2-0.2,9.1,3.6c2,3.8,0.2,7-1.9,10.2c-43.9,66.2-87.8,132.5-131.6,198.7c-0.6,1-1.3,1.9-2,2.9c-7.2,9.8-17.5,10.1-24.9,0.3c-12.3-16.4-24.5-32.8-36.7-49.3c-1.2-1.6-2.4-3.1-3.9-5c-6.3,4.3-12.4,8.3-18.3,12.5c-46.1,32.6-89.8,68-128.1,109.6C62.9,494.7,23.5,573.1,8,663.2c-3.6,20.6-4.9,41.6-7.2,62.5c-0.2,1.8-0.5,3.6-0.8,5.4C0,620.7,0,510.3,0,400z" },
    ],
  };
  var WORDMARK = {
    viewBox: "0 0 3299.1 754.5",
    paths: [
    { role: "ink", d: "M517,744h227l-85.2-120.4c-41.7-58.7-83.3-117.5-124.9-176.2c-0.7-0.9-1.3-1.9-2.3-3.4c2.6-1.3,5.1-2.5,7.6-3.7c26.2-12.9,50.3-28.8,70.8-49.7c29.9-30.6,47-67.6,53.7-109.4c8.3-52.1,2.1-102.4-22.8-149.2C601.2,57.3,539.1,13.7,455.2,1.8c-4.1-0.6-8.1-1.2-12.2-1.8C295.3,0,147.7,0,0,0c0,133.5,0,266.7,0,400c12.8-17,24.9-34.6,38.5-51c45.4-55.2,99.8-100.2,159.9-138.6c1.1-0.7,2.2-1.5,3.3-2.2c0.3-0.2,0.4-0.5,1-1.1c-3.1-4.3-6.3-8.8-9.5-13.2c-7.2-10-14.4-20-21.6-30c-3.1-4.3-4.6-9-2.1-14c2.5-4.9,7.1-6,12.2-6c93.8,0,187.6,0,281.5,0c3.5,0,7.2-0.2,9.1,3.6c2,3.8,0.2,7-1.9,10.2c-43.9,66.2-87.8,132.5-131.6,198.7c-0.6,1-1.3,1.9-2,2.9c-7.2,9.8-17.5,10.1-24.9,0.3c-12.3-16.4-24.5-32.8-36.7-49.3c-1.2-1.6-2.4-3.1-3.9-5c-6.3,4.3-12.4,8.3-18.3,12.5c-46.1,32.6-89.8,68-128.1,109.6C62.9,494.7,23.5,573.1,8,663.2c-3.6,20.6-4.9,41.6-7.2,62.5c-0.2,1.8-0.5,3.6-0.8,5.4c0,3.7,0,9.3,0,13c1-1.6,2.3-5.2,2.9-6.9c19.5-54,47.4-103.2,86.8-145.2c59.3-63.2,132.4-100.6,217.6-115.2c6.4-1.1,9.7,0.4,13.6,5.5" },
    { role: "signal", d: "M0,400c12.8-17,24.9-34.6,38.5-51c45.4-55.2,99.8-100.2,159.9-138.6c1.1-0.7,2.2-1.5,3.3-2.2c0.3-0.2,0.4-0.5,1-1.1c-3.1-4.3-6.3-8.8-9.5-13.2c-7.2-10-14.4-20-21.6-30c-3.1-4.3-4.6-9-2.1-14c2.5-4.9,7.1-6,12.2-6c93.8,0,187.6,0,281.5,0c3.5,0,7.2-0.2,9.1,3.6c2,3.8,0.2,7-1.9,10.2c-43.9,66.2-87.8,132.5-131.6,198.7c-0.6,1-1.3,1.9-2,2.9c-7.2,9.8-17.5,10.1-24.9,0.3c-12.3-16.4-24.5-32.8-36.7-49.3c-1.2-1.6-2.4-3.1-3.9-5c-6.3,4.3-12.4,8.3-18.3,12.5c-46.1,32.6-89.8,68-128.1,109.6C62.9,494.7,23.5,573.1,8,663.2c-3.6,20.6-4.9,41.6-7.2,62.5c-0.2,1.8-0.5,3.6-0.8,5.4C0,620.7,0,510.3,0,400z" },
    { role: "ink", d: "M809.5,58.3H946v124.2H809.5V58.3z M945.1,744H811.4V241.7h133.7V744z" },
    { role: "ink", d: "M1275.5,641.8c55.4,0,88.8-38.2,101.2-89.8l115.6,51.6c-22.9,82.1-101.2,150.9-217.7,150.9c-146.1,0-249.3-106-249.3-261.7c0-154.7,103.1-260.7,249.3-260.7c115.6,0,192,66.8,215.8,148l-113.6,53.5c-12.4-51.6-45.8-89.8-101.2-89.8c-70.7,0-117.5,55.4-117.5,149C1158,587.4,1204.8,641.8,1275.5,641.8z" },
    { role: "ink", d: "M1556.3,58.3H1690v234.9c27.7-32.5,73.5-61.1,137.5-61.1c105.1,0,169,71.6,169,180.5V744h-133.7V450.8c0-56.3-22.9-96.5-80.2-96.5c-46.8,0-92.6,33.4-92.6,99.3V744h-133.7V58.3z" },
    { role: "ink", d: "M2398.6,47.8c188.1,0,323.7,146.1,323.7,353.4s-135.6,353.4-323.7,353.4c-189.1,0-324.7-146.1-324.7-353.4S2209.5,47.8,2398.6,47.8z M2398.6,171c-107.9,0-183.4,89.8-183.4,230.2c0,140.4,75.4,230.2,183.4,230.2c107,0,182.4-89.8,182.4-230.2C2581,260.8,2505.5,171,2398.6,171z" },
    { role: "ink", d: "M2836,525.3c50.6,71.6,124.2,111.7,199.6,111.7c71.6,0,124.2-31.5,124.2-89.8c0-63-64.9-71.6-168.1-94.5c-102.2-23.9-213-56.3-213-192c0-130.8,112.7-213,255-213c118.4,0,211.1,52.5,258.8,121.3l-92.6,90.7c-40.1-56.3-93.6-94.5-170-94.5c-66.9,0-112.7,32.5-112.7,82.1c0,53.5,49.7,64,139.4,84c108.9,23.9,242.6,51.6,242.6,201.5c0,138.5-122.2,221.6-268.4,221.6c-115.6,0-235.9-52.5-291.3-135.6L2836,525.3z" },
    ],
  };

  // The line the approved compositions carry under the rule.
  var LINE = "The AI Operating System for CEOs";

  // -------------------------------------------------------------------------------------
  // Storage, which is allowed to be unavailable
  // -------------------------------------------------------------------------------------

  function read(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (_e) {
      return null;
    }
  }

  function write(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch (_e) {
      /* A webview with storage denied still gets a splash; it just gets no repeat guard. */
    }
  }

  /// ABSENT MEANS ON. An absent key is an absent opinion, not a decision to switch the
  /// surface off - the same rule `config.rs` states on the Rust side, and the two have to
  /// agree or a first launch would disagree with itself.
  function enabled() {
    return read(KEY_ENABLED) !== "false";
  }

  // -------------------------------------------------------------------------------------
  // The library
  // -------------------------------------------------------------------------------------

  /// The material stack, checked key by key. A layer that carries a key this renderer does
  /// not know is a layer whose author expected something to happen that will not — so the
  /// ENTRY is dropped, not the key. Silently ignoring it is how a suede mat ships as a
  /// plain one.
  function validMaterials(layers) {
    if (!Array.isArray(layers)) return false;
    for (var i = 0; i < layers.length; i++) {
      var l = layers[i];
      if (!l || typeof l !== "object" || Array.isArray(l)) return false;
      if (typeof l.background !== "string" || !l.background) return false;
      for (var k in l) {
        if (!l.hasOwnProperty(k)) continue;
        if (k === "relief") {
          if (typeof l.relief !== "boolean") return false;
          continue;
        }
        if (!LAYER_PROPS.hasOwnProperty(k) && LAYER_KEYS.indexOf(k) < 0) return false;
        if (typeof l[k] !== "string" || !l[k]) return false;
      }
    }
    return true;
  }

  /// The relief spec, which is an SVG filter written as values rather than as markup. The
  /// SHAPE of the filter is fixed below in `relief()` — a noise field clipped inside the
  /// mark, and any number of shadow or light bands laid inside or outside it. What each
  /// band is made of is the entry's to say. This is the same division the gilding gradient
  /// already lives under: the structure is the renderer's, the values are the library's.
  function validRelief(spec) {
    if (spec === null) return true;
    if (typeof spec !== "object" || Array.isArray(spec)) return false;
    if (spec.target !== "mark" && spec.target !== "signal") return false;
    if (typeof spec.region !== "string" || spec.region.trim().split(/\s+/).length !== 4) return false;
    if (spec.noise !== null) {
      var n = spec.noise;
      if (!n || typeof n !== "object") return false;
      var keys = ["type", "baseFrequency", "octaves", "seed"];
      for (var i = 0; i < keys.length; i++) {
        if (typeof n[keys[i]] !== "string" || !n[keys[i]]) return false;
      }
      if (typeof spec.matrix !== "string" || !spec.matrix) return false;
    }
    if (!Array.isArray(spec.bands)) return false;
    for (var j = 0; j < spec.bands.length; j++) {
      var b = spec.bands[j];
      if (!b || typeof b !== "object") return false;
      if (PLACEMENTS.indexOf(b.placement) < 0) return false;
      var bk = ["color", "opacity", "dx", "dy", "blur"];
      for (var m = 0; m < bk.length; m++) {
        if (typeof b[bk[m]] !== "string" || !b[bk[m]]) return false;
      }
    }
    return true;
  }

  function valid(entry) {
    if (!entry || typeof entry !== "object") return false;
    if (typeof entry.id !== "string" || !entry.id) return false;
    var t = entry.tokens;
    if (!t || typeof t !== "object") return false;
    for (var i = 0; i < STRING_TOKENS.length; i++) {
      if (typeof t[STRING_TOKENS[i]] !== "string" || !t[STRING_TOKENS[i]]) return false;
    }
    if (STRIKES.indexOf(t.strike) < 0) return false;
    if (!Array.isArray(t.riseDelays) || t.riseDelays.length !== 4) return false;
    for (var j = 0; j < 4; j++) {
      if (typeof t.riseDelays[j] !== "string" || !t.riseDelays[j]) return false;
    }
    if (t.gild !== null && !(Array.isArray(t.gild) && t.gild.length === 3)) return false;
    if (t.sheen !== null && typeof t.sheen !== "string") return false;
    if (t.markFilter !== null && typeof t.markFilter !== "string") return false;
    if (t.signalFilter !== null && typeof t.signalFilter !== "string") return false;
    if (!validMaterials(t.materials)) return false;
    if (!validRelief(t.relief)) return false;
    if (t.strike === "fill") {
      // A colour strike on a gradient fill has no colour to animate: the gold would simply
      // never arrive. Refuse the entry rather than draw a mark that stays unlit.
      if (t.gild !== null) return false;
      if (typeof t.strikeFrom !== "string" || typeof t.strikePeak !== "string") return false;
    }
    return true;
  }

  function pool() {
    var lib = window.RichSplashLibrary;
    if (!lib || !Array.isArray(lib.variations)) return [];
    var out = [];
    for (var i = 0; i < lib.variations.length; i++) {
      if (valid(lib.variations[i])) out.push(lib.variations[i]);
    }
    return out;
  }

  /// Uniform over the library, with a no-immediate-repeat guard - the mechanism Deeply
  /// already shipped for its randomised animation libraries, and the one the CEO's own
  /// framing asks for: the thing he meets at every start is never quite the same one.
  function pick(candidates) {
    var last = read(KEY_LAST);
    var eligible = candidates;
    if (candidates.length > 1 && last) {
      var filtered = [];
      for (var i = 0; i < candidates.length; i++) {
        if (candidates[i].id !== last) filtered.push(candidates[i]);
      }
      if (filtered.length) eligible = filtered;
    }
    return eligible[Math.floor(Math.random() * eligible.length)];
  }

  // -------------------------------------------------------------------------------------
  // Drawing
  // -------------------------------------------------------------------------------------

  var SVG_NS = "http://www.w3.org/2000/svg";

  function svgMark(mark, className, gilded, reliefSpec) {
    var svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", mark.viewBox);
    svg.setAttribute("class", className);
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    if (gilded || reliefSpec) {
      var defs = document.createElementNS(SVG_NS, "defs");
      if (gilded) defs.appendChild(gilding(gilded));
      if (reliefSpec) defs.appendChild(relief(reliefSpec));
      svg.appendChild(defs);
    }
    for (var i = 0; i < mark.paths.length; i++) {
      var p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", mark.paths[i].d);
      p.setAttribute("class", mark.paths[i].role === "signal" ? "splash-signal" : "splash-ink");
      svg.appendChild(p);
    }
    return svg;
  }

  /// The gradient v2 and v6 give the gold, built from the entry's own three stops. Defined
  /// once, inside the first mark; `url(#id)` resolves document-wide, which is exactly how
  /// the studies do it.
  function gilding(stops) {
    var grad = document.createElementNS(SVG_NS, "linearGradient");
    grad.setAttribute("id", GILD_ID);
    grad.setAttribute("x1", "0");
    grad.setAttribute("y1", "0");
    grad.setAttribute("x2", "0.18");
    grad.setAttribute("y2", "1");
    var offsets = ["0", "0.42", "1"];
    for (var i = 0; i < stops.length; i++) {
      var stop = document.createElementNS(SVG_NS, "stop");
      stop.setAttribute("offset", offsets[i]);
      stop.setAttribute("stop-color", stops[i]);
      grad.appendChild(stop);
    }
    return grad;
  }

  /// THE RELIEF FILTER — the mark's material, built from the entry's own numbers.
  ///
  /// Its SHAPE is fixed here and its VALUES all arrive in `spec`, which is the same
  /// division `gilding()` above already lives under. Two ingredients, either of which may
  /// be absent:
  ///
  ///   * a NOISE FIELD, coloured through a matrix and clipped to the mark's own alpha —
  ///     what makes maki-e gold dust sit in the lacquered arrow and bullion thread run
  ///     across the mark in strands;
  ///   * any number of BANDS, each a flood of one colour clipped against a blurred, offset
  ///     copy of the mark. `inner` leaves the band inside the glyph, which is a letter
  ///     pressed INTO the material; `outer` leaves it outside, which is one sitting proud
  ///     of it. There is no CSS filter function for the inner case, which is why this is
  ///     an SVG filter and not a `drop-shadow()` list.
  ///
  /// The merge order is the one thing that is not negotiable and so is not data: outer
  /// bands under the mark, the mark, then the noise and the inner bands over it. Any other
  /// order draws a shadow on top of the thing casting it.
  function relief(spec) {
    var f = document.createElementNS(SVG_NS, "filter");
    f.setAttribute("id", RELIEF_ID);
    var region = spec.region.trim().split(/\s+/);
    f.setAttribute("x", region[0]);
    f.setAttribute("y", region[1]);
    f.setAttribute("width", region[2]);
    f.setAttribute("height", region[3]);

    function prim(tag, attrs) {
      var n = document.createElementNS(SVG_NS, tag);
      for (var k in attrs) {
        if (attrs.hasOwnProperty(k)) n.setAttribute(k, attrs[k]);
      }
      f.appendChild(n);
      return n;
    }

    var under = [];
    var over = [];

    if (spec.noise) {
      prim("feTurbulence", {
        type: spec.noise.type,
        baseFrequency: spec.noise.baseFrequency,
        numOctaves: spec.noise.octaves,
        seed: spec.noise.seed,
        result: "n"
      });
      prim("feColorMatrix", { in: "n", type: "matrix", values: spec.matrix, result: "nc" });
      prim("feComposite", { in: "nc", in2: "SourceAlpha", operator: "in", result: "grain" });
      over.push("grain");
    }

    for (var i = 0; i < spec.bands.length; i++) {
      var b = spec.bands[i];
      var id = "band" + i;
      prim("feFlood", { "flood-color": b.color, "flood-opacity": b.opacity, result: id + "f" });
      prim("feOffset", { in: "SourceAlpha", dx: b.dx, dy: b.dy, result: id + "o" });
      prim("feGaussianBlur", { in: id + "o", stdDeviation: b.blur, result: id + "g" });
      if (b.placement === "outer") {
        prim("feComposite", { in: id + "f", in2: id + "g", operator: "in", result: id + "m" });
        prim("feComposite", { in: id + "m", in2: "SourceAlpha", operator: "out", result: id });
        under.push(id);
      } else {
        prim("feComposite", { in: id + "f", in2: "SourceAlpha", operator: "in", result: id + "m" });
        prim("feComposite", { in: id + "m", in2: id + "g", operator: "out", result: id });
        over.push(id);
      }
    }

    var merge = prim("feMerge", {});
    var order = under.concat(["SourceGraphic"], over);
    for (var j = 0; j < order.length; j++) {
      var node = document.createElementNS(SVG_NS, "feMergeNode");
      node.setAttribute("in", order[j]);
      merge.appendChild(node);
    }
    return f;
  }

  /// One layer of the material stack. Every property it paints with comes off the entry;
  /// this function knows only where a layer sits and which CSS property each key drives.
  function materialLayer(spec) {
    var el = div("splash-material");
    for (var k in spec) {
      if (!spec.hasOwnProperty(k)) continue;
      if (k === "relief") {
        if (spec.relief) el.style.setProperty("filter", "url(#" + RELIEF_ID + ")");
        continue;
      }
      if (k === "mask") {
        // WebKit still wants the prefixed property; setting both is what makes the same
        // entry look the same under the engine Tauri ships and under the one it does not.
        el.style.setProperty("-webkit-mask-image", spec.mask);
        el.style.setProperty("mask-image", spec.mask);
        continue;
      }
      el.style.setProperty(LAYER_PROPS[k], spec[k]);
    }
    return el;
  }

  function div(className) {
    var d = document.createElement("div");
    d.className = className;
    return d;
  }

  function build(entry) {
    var t = entry.tokens;
    var root = div("splash");
    root.id = "splash";
    root.setAttribute("aria-hidden", "true");
    root.dataset.variation = entry.id;

    var s = root.style;
    s.setProperty("--splash-ground", t.ground);
    s.setProperty("--splash-atmosphere", t.atmosphere);
    s.setProperty("--splash-vignette", t.vignette);
    s.setProperty("--splash-grain-opacity", t.grainOpacity);
    s.setProperty("--splash-lamp", t.lamp);
    s.setProperty("--splash-lamp-radius", t.lampRadius);
    s.setProperty("--splash-lamp-stop", t.lampStop);
    s.setProperty("--splash-surface", t.surface);
    s.setProperty("--splash-surface-image", t.surfaceImage);
    s.setProperty("--splash-plinth-radius", t.plinthRadius);
    s.setProperty("--splash-plinth-shadow", t.plinthShadow);
    s.setProperty("--splash-plinth-outline", t.plinthOutline);
    s.setProperty("--splash-keyline-inset", t.keylineInset);
    s.setProperty("--splash-keyline-radius", t.keylineRadius);
    s.setProperty("--splash-keyline-color", t.keylineColor);
    s.setProperty("--splash-keyline-width", t.keylineWidth);
    s.setProperty("--splash-keyline-style", t.keylineStyle);
    s.setProperty("--splash-keyline-image", t.keylineImage);
    s.setProperty("--splash-keyline-shadow", t.keylineShadow);
    s.setProperty("--splash-ink", t.ink);
    // Gilded gold is a paint server with the flat colour as its fallback, exactly as the
    // studies write it (`fill: url(#gild) <the flat gold>` — the hex itself deliberately
    // not repeated here, because `tests/splash.js` check 2 greps this whole file for one
    // and a value quoted in a comment is the first step toward a value used in code). One
    // property, so the settled state and the bloom strike need no second rule to know
    // which kind of gold they are pinning.
    s.setProperty("--splash-signal", t.gild ? "url(#" + GILD_ID + ") " + t.signal : t.signal);
    s.setProperty("--splash-rule", t.rule);
    s.setProperty("--splash-rule-width", t.ruleWidth);
    s.setProperty("--splash-tagline", t.tagline);
    s.setProperty("--splash-sheen", t.sheen || "none");
    s.setProperty("--splash-rise-duration", t.riseDuration);
    s.setProperty("--splash-rise-shift", t.riseShift);
    s.setProperty("--splash-rise-d1", t.riseDelays[0]);
    s.setProperty("--splash-rise-d2", t.riseDelays[1]);
    s.setProperty("--splash-rise-d3", t.riseDelays[2]);
    s.setProperty("--splash-rise-d4", t.riseDelays[3]);
    s.setProperty("--splash-strike-delay", t.strikeDelay);
    s.setProperty("--splash-strike-duration", t.strikeDuration);
    s.setProperty("--splash-strike-from", t.strikeFrom || t.signal);
    s.setProperty("--splash-strike-peak", t.strikePeak || t.signal);
    s.setProperty("--splash-fade", FADE_MS + "ms");
    // The mark's relief, resolved once. A `relief` spec aimed at the whole mark reaches the
    // gold too — the studies write it as `.logo path, .wordmark path`, which is every path
    // there is — while one aimed at `signal` leaves the ink flat. A plain CSS filter the
    // entry wrote out wins over both, because an entry that says exactly what it wants is
    // not asking to be interpreted.
    var reliefUrl = t.relief ? "url(#" + RELIEF_ID + ")" : "none";
    var onMark = t.relief && t.relief.target === "mark";
    s.setProperty("--splash-mark-filter", t.markFilter || (onMark ? reliefUrl : "none"));
    s.setProperty("--splash-signal-filter", t.signalFilter || (t.relief ? reliefUrl : "none"));
    if (t.strike !== "none") root.classList.add("splash--strike-" + t.strike);

    root.appendChild(div("splash-lamp"));
    root.appendChild(div("splash-vignette"));
    root.appendChild(div("splash-grain"));

    var stage = div("splash-stage");
    var frame = div("splash-rise splash-rise--1");
    var plinth = div("splash-plinth");
    // The material first, in the entry's own order, then the sheen — the one layer the
    // approved seven use — then the composition on top of both.
    for (var m = 0; m < t.materials.length; m++) plinth.appendChild(materialLayer(t.materials[m]));
    if (t.sheen) plinth.appendChild(div("splash-sheen"));

    var logoWrap = div("splash-rise splash-rise--2");
    logoWrap.appendChild(svgMark(LOGO, "splash-logo", t.gild, t.relief));
    plinth.appendChild(logoWrap);

    var wordWrap = div("splash-rise splash-rise--3");
    wordWrap.appendChild(svgMark(WORDMARK, "splash-wordmark", null, null));
    plinth.appendChild(wordWrap);

    var footWrap = div("splash-rise splash-rise--4");
    var foot = div("splash-foot");
    foot.appendChild(div("splash-rule"));
    var line = div("splash-line");
    line.textContent = LINE;
    foot.appendChild(line);
    footWrap.appendChild(foot);
    plinth.appendChild(footWrap);

    frame.appendChild(plinth);
    stage.appendChild(frame);
    root.appendChild(stage);
    return root;
  }

  // -------------------------------------------------------------------------------------
  // The surface's life
  // -------------------------------------------------------------------------------------

  var node = null;
  var yielded = false;
  var ceiling = null;
  var state = {
    shown: false,
    variationId: null,
    reason: null,
    /// Why nothing was drawn, when nothing was. A surface that declines to appear should
    /// be able to say why without anyone attaching a debugger.
    declined: null
  };

  function removeSelf() {
    if (node && node.parentNode) node.parentNode.removeChild(node);
    node = null;
  }

  function onInput() {
    yieldNow("first-input");
  }

  /// Get out of the way. Called by `main.js` when the app is usable, by the CEO's first
  /// keystroke or touch, and by the ceiling - whichever happens first, and only once.
  function yieldNow(reason) {
    if (yielded) return;
    yielded = true;
    state.reason = reason;
    if (ceiling !== null) {
      clearTimeout(ceiling);
      ceiling = null;
    }
    window.removeEventListener("keydown", onInput, true);
    window.removeEventListener("pointerdown", onInput, true);
    if (!node) return;
    // Pin the composition where it was going BEFORE fading it, so a launch that finishes
    // mid-ceremony shows a finished mark on its way out rather than unlit metal.
    node.classList.add("splash--settled");
    node.classList.add("splash--yielding");
    setTimeout(removeSelf, FADE_MS + 40);
    // Drop the always-dark clamp as the curtain goes, not after it has gone: the fade is
    // the app arriving, and the control crossing over with it is the same "one system, two
    // lightings" move every other element makes.
    if (window.RichTheme) window.RichTheme.forceDark(false);
  }

  function start() {
    if (!enabled()) {
      state.declined = "switched off";
      return;
    }
    var candidates = pool();
    if (!candidates.length) {
      // No library, an unparseable one, or every entry malformed. All three are the same
      // answer: a normal launch, with nothing drawn.
      state.declined = "no usable variation in the library";
      return;
    }
    var entry = pick(candidates);
    try {
      node = build(entry);
      document.body.insertBefore(node, document.body.firstChild);
    } catch (e) {
      removeSelf();
      state.declined = "the chosen variation would not render: " + ((e && e.message) || e);
      return;
    }
    state.shown = true;
    state.variationId = entry.id;
    // §15's ONE PERMANENT EXCEPTION: "because of its nature the start screen will always
    // need to be in dark mode", and no switch reaches it. The curtain's own composition was
    // always dark — it draws from `--splash-*` properties this file sets, never from the
    // app's theme tokens — but the SETTINGS BUTTON sits above the curtain (it has to; its
    // floor is "Bust a bug" from every screen) and it does read those tokens. Without this
    // clamp a CEO on light mode gets an ivory control floating on a midnight composition.
    //
    // `RichTheme` and not `RichSettings`: theme-boot.js is loaded in `<head>`, so it is
    // certain to exist here, whereas settings-button.js loads after this file. The clamp is
    // a FORCE flag and never writes the preference, so light mode is exactly where he left
    // it the moment the curtain lifts.
    if (window.RichTheme) window.RichTheme.forceDark(true);
    write(KEY_LAST, entry.id);
    window.addEventListener("keydown", onInput, true);
    window.addEventListener("pointerdown", onInput, true);
    ceiling = setTimeout(function () {
      yieldNow("ceiling");
    }, CEILING_MS);
  }

  window.RichSplash = {
    yieldNow: yieldNow,
    state: state,
    /// The two keys, exported so `main.js` mirrors the durable Rust setting into the same
    /// place this file reads it from, rather than knowing the strings twice.
    KEY_ENABLED: KEY_ENABLED,
    KEY_LAST: KEY_LAST,
    /// Every entry the library offers that this renderer would actually draw. `main.js`
    /// does not use it; the acceptance suite does, to prove the pool it draws from is the
    /// pool that is shipped.
    pool: pool
  };

  start();
})();
